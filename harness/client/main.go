// pg-ha-lab workload client.
//
// Modes:
//   clean  - writer that never cancels an in-flight COMMIT: a hung commit is
//            recorded as "info" (indeterminate) and left hanging on its own
//            connection; if it eventually completes, a "late_ok"/"late_err"
//            record is emitted. Only "ok" results count as clean acks.
//   cancel - writer that mimics driver query-timeout behavior: after
//            -cancel-after it sends a PostgreSQL cancel request and keeps
//            waiting for the result. A COMMIT that succeeds carrying the
//            "committed locally" warning is recorded as "ok_warning"
//            (pseudo-ack): the PostgreSQL-inherent loss channel, bucketed
//            separately from operator behavior.
//   read   - reader logging which server it reaches, whether it is in
//            recovery, and the per-writer high-water marks it observes
//            (used by the checker to detect doomed reads).
//
// History is emitted as JSONL on stdout; pod logs are the collection channel.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type record struct {
	T          string           `json:"t"`
	Client     string           `json:"client"`
	Mode       string           `json:"mode"`
	Op         string           `json:"op"`
	Seq        *int64           `json:"seq,omitempty"`
	Result     string           `json:"result"`
	Server     string           `json:"server,omitempty"`
	InRecovery *bool            `json:"in_recovery,omitempty"`
	Observed   map[string]int64 `json:"observed,omitempty"`
	Err        string           `json:"err,omitempty"`
	Warning    string           `json:"warning,omitempty"`
	Ms         float64          `json:"ms"`
}

var (
	mode        = flag.String("mode", "clean", "clean | cancel | disconnect | read")
	host        = flag.String("host", "", "server host (service DNS or pod IP)")
	port        = flag.Int("port", 5432, "server port")
	clientID    = flag.String("client", "c1", "client id (unique per pod)")
	interval    = flag.Duration("interval", 500*time.Millisecond, "pause between ops")
	opTimeout   = flag.Duration("op-timeout", 20*time.Second, "clean mode: wall time before an op is declared indeterminate")
	cancelAfter = flag.Duration("cancel-after", 5*time.Second, "cancel mode: time before sending a cancel request")
	dropAfter   = flag.Duration("disconnect-after", 300*time.Millisecond, "disconnect mode: time before hard-closing the TCP connection")
)

var outMu sync.Mutex

func emit(r record) {
	r.T = time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	b, _ := json.Marshal(r)
	outMu.Lock()
	fmt.Println(string(b))
	outMu.Unlock()
}

// noticeBox captures the last notice/warning seen on a connection.
type noticeBox struct {
	mu   sync.Mutex
	last string
}

func (n *noticeBox) take() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	s := n.last
	n.last = ""
	return s
}

func connect(ctx context.Context, box *noticeBox) (*pgx.Conn, error) {
	dsn := fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=prefer connect_timeout=5",
		*host, *port, os.Getenv("PGUSER"), os.Getenv("PGPASSWORD"), envOr("PGDATABASE", "app"))
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.OnNotice = func(_ *pgconn.PgConn, n *pgconn.Notice) {
		box.mu.Lock()
		box.last = n.Severity + ": " + n.Message
		if n.Detail != "" {
			box.last += " DETAIL: " + n.Detail
		}
		box.mu.Unlock()
	}
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return pgx.ConnectConfig(cctx, cfg)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func ensureTable(ctx context.Context, box *noticeBox) {
	for {
		conn, err := connect(ctx, box)
		if err == nil {
			_, err = conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS lab_writes (
				id text PRIMARY KEY, client text NOT NULL, seq bigint NOT NULL,
				ts timestamptz NOT NULL DEFAULT now())`)
			_ = conn.Close(ctx)
			if err == nil {
				return
			}
		}
		emit(record{Client: *clientID, Mode: *mode, Op: "setup", Result: "fail", Err: fmt.Sprint(err)})
		time.Sleep(2 * time.Second)
	}
}

const insertSQL = `INSERT INTO lab_writes (id, client, seq) VALUES ($1, $2, $3) RETURNING inet_server_addr()::text`

type opResult struct {
	server string
	err    error
}

// runWriter drives one of the writer modes:
//
//	clean      - never interferes with an in-flight commit
//	cancel     - driver-style cancel request after -cancel-after
//	disconnect - the client "crashes": hard TCP close (no cancel, no
//	             Terminate message) after -disconnect-after. This is the
//	             trigger from Bin Wang's Patroni Jepsen analysis: the commit
//	             keeps waiting server-side with nobody left to answer, and
//	             may become visible (and later be erased) without ever being
//	             acknowledged to anyone.
func runWriter(writerMode string) {
	ctx := context.Background()
	box := &noticeBox{}
	ensureTable(ctx, box)

	var conn *pgx.Conn
	var seq int64
	for {
		if conn == nil {
			c, err := connect(ctx, box)
			if err != nil {
				emit(record{Client: *clientID, Mode: *mode, Op: "connect", Result: "fail", Err: err.Error()})
				time.Sleep(1 * time.Second)
				continue
			}
			conn = c
		}

		seq++
		s := seq
		id := fmt.Sprintf("%s-%d", *clientID, s)
		start := time.Now()
		box.take() // clear stale notices

		done := make(chan opResult, 1)
		go func(c *pgx.Conn) {
			var server *string
			err := c.QueryRow(ctx, insertSQL, id, *clientID, s).Scan(&server)
			sv := ""
			if server != nil {
				sv = *server
			}
			done <- opResult{server: sv, err: err}
		}(conn)

		switch writerMode {
		case "disconnect":
			select {
			case r := <-done:
				logWrite(s, r, box, start, false)
			case <-time.After(*dropAfter):
				// client vanishes mid-commit: abrupt TCP close, nothing sent
				_ = conn.PgConn().Conn().Close()
				emit(record{Client: *clientID, Mode: *mode, Op: "write", Seq: &s,
					Result: "info", Err: "connection hard-closed by client during commit",
					Ms: ms(start)})
				go waitLate(s, done, box, start)
				conn = nil
			}
		case "cancel":
			select {
			case r := <-done:
				logWrite(s, r, box, start, false)
			case <-time.After(*cancelAfter):
				// driver-style timeout: send a cancel request, keep waiting
				_ = conn.PgConn().CancelRequest(ctx)
				select {
				case r := <-done:
					logWrite(s, r, box, start, true)
				case <-time.After(*opTimeout):
					emit(record{Client: *clientID, Mode: *mode, Op: "write", Seq: &s,
						Result: "info", Err: "hung after cancel; abandoning connection",
						Ms: ms(start)})
					go waitLate(s, done, box, start)
					conn = nil
				}
			}
		default: // clean
			select {
			case r := <-done:
				logWrite(s, r, box, start, false)
			case <-time.After(*opTimeout):
				// Indeterminate. Do NOT cancel: leave the commit hanging on
				// its own connection and move on with a fresh one.
				emit(record{Client: *clientID, Mode: *mode, Op: "write", Seq: &s,
					Result: "info", Err: "op timeout; abandoning connection (no cancel sent)",
					Ms: ms(start)})
				go waitLate(s, done, box, start)
				conn = nil
			}
		}

		if conn == nil {
			continue // reconnect immediately, no pacing
		}
		time.Sleep(*interval)
	}
}

func waitLate(seq int64, done chan opResult, box *noticeBox, start time.Time) {
	r := <-done
	res := "late_ok"
	errs := ""
	if r.err != nil {
		res = "late_err"
		errs = r.err.Error()
	}
	emit(record{Client: *clientID, Mode: *mode, Op: "write", Seq: &seq,
		Result: res, Server: r.server, Err: errs, Warning: box.take(), Ms: ms(start)})
}

func logWrite(seq int64, r opResult, box *noticeBox, start time.Time, afterCancel bool) {
	warn := box.take()
	rec := record{Client: *clientID, Mode: *mode, Op: "write", Seq: &seq,
		Server: r.server, Warning: warn, Ms: ms(start)}
	switch {
	case r.err == nil && warn != "" && strings.Contains(warn, "synchronous replication"):
		// success carrying the sync-replication cancellation warning
		// ("canceling wait for synchronous replication ..."): a pseudo-ack
		// (PostgreSQL-inherent channel). The "committed locally" phrase is
		// in the DETAIL, which not every path includes — match the message.
		rec.Result = "ok_warning"
	case r.err == nil:
		rec.Result = "ok"
	default:
		rec.Err = r.err.Error()
		if afterCancel && strings.Contains(r.err.Error(), "57014") {
			// cancelled before the commit point: a definite failure
			rec.Result = "fail"
		} else if isDefiniteFailure(r.err) {
			rec.Result = "fail"
		} else {
			// connection broke mid-op: outcome unknown
			rec.Result = "info"
		}
	}
	emit(rec)
}

// isDefiniteFailure: the server answered with an error, so the write did not
// commit. Connection-level breakage is NOT definite.
func isDefiniteFailure(err error) bool {
	var pgErr *pgconn.PgError
	if ok := asPgError(err, &pgErr); ok {
		return true
	}
	return false
}

func asPgError(err error, target **pgconn.PgError) bool {
	for err != nil {
		if pe, ok := err.(*pgconn.PgError); ok {
			*target = pe
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

func runReader() {
	ctx := context.Background()
	box := &noticeBox{}
	var conn *pgx.Conn
	for {
		if conn == nil {
			c, err := connect(ctx, box)
			if err != nil {
				emit(record{Client: *clientID, Mode: *mode, Op: "connect", Result: "fail", Err: err.Error()})
				time.Sleep(1 * time.Second)
				continue
			}
			conn = c
		}
		start := time.Now()
		qctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		var server *string
		var inRec bool
		err := conn.QueryRow(qctx, `SELECT inet_server_addr()::text, pg_is_in_recovery()`).Scan(&server, &inRec)
		observed := map[string]int64{}
		if err == nil {
			var rows pgx.Rows
			rows, err = conn.Query(qctx, `SELECT client, max(seq) FROM lab_writes GROUP BY client`)
			if err == nil {
				for rows.Next() {
					var cl string
					var mx int64
					if scanErr := rows.Scan(&cl, &mx); scanErr == nil {
						observed[cl] = mx
					}
				}
				err = rows.Err()
			}
		}
		cancel()
		sv := ""
		if server != nil {
			sv = *server
		}
		rec := record{Client: *clientID, Mode: *mode, Op: "read", Server: sv,
			InRecovery: &inRec, Ms: ms(start)}
		if err != nil {
			rec.Result = "fail"
			rec.Err = err.Error()
			_ = conn.PgConn().Conn().Close() // hard close; reconnect fresh
			conn = nil
		} else {
			rec.Result = "ok"
			rec.Observed = observed
		}
		emit(rec)
		time.Sleep(*interval)
	}
}

func ms(start time.Time) float64 {
	return float64(time.Since(start).Microseconds()) / 1000.0
}

func main() {
	flag.Parse()
	if *host == "" {
		fmt.Fprintln(os.Stderr, "-host is required")
		os.Exit(2)
	}
	emit(record{Client: *clientID, Mode: *mode, Op: "start", Result: "ok",
		Server: fmt.Sprintf("%s:%d", *host, *port)})
	switch *mode {
	case "clean", "cancel", "disconnect":
		runWriter(*mode)
	case "read":
		runReader()
	default:
		fmt.Fprintln(os.Stderr, "unknown -mode:", *mode)
		os.Exit(2)
	}
}
