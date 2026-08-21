#!/usr/bin/env python3
"""pg-ha-lab checker: invariants + neutral measurements over a collected run.

Invariants (violations -> exit 1):
  I1 durability: every clean-acked write (result ok, and late_ok) must be
     present in the final state.
  I2 single acker: no two servers may have overlapping clean-ack intervals.

Measured and reported, never judged:
  - pseudo-acks (ok_warning) and how many survived vs. were lost
  - indeterminate ops (info) survived vs. lost
  - per-server ack/read windows, promotion gap, zombie window
  - doomed reads (reader observed a write that did not survive)
  - availability timeline anchors from events.jsonl
"""
import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path


def parse_t(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def load_history(run_dir):
    ops = []
    for f in sorted((run_dir / "history").glob("*.jsonl")):
        for line in f.read_text().splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                op = json.loads(line)
            except json.JSONDecodeError:
                continue
            op["_file"] = f.name
            ops.append(op)
    return ops


def load_events(run_dir):
    f = run_dir / "events.jsonl"
    if not f.exists():
        return []
    out = []
    for line in f.read_text().splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def main(run_dir):
    run_dir = Path(run_dir)
    ops = load_history(run_dir)
    events = load_events(run_dir)
    final_ids = set()
    fi = run_dir / "final_ids.txt"
    if fi.exists():
        final_ids = {l.strip() for l in fi.read_text().splitlines() if l.strip()}

    if not ops:
        print("no history found — nothing to check")
        return 1
    if not final_ids:
        print("WARNING: final_ids.txt missing or empty; durability checks are void")

    writes = [o for o in ops if o.get("op") == "write"]
    reads = [o for o in ops if o.get("op") == "read"]

    def wid(o):
        return f"{o['client']}-{o['seq']}"

    buckets = defaultdict(list)
    for w in writes:
        buckets[w.get("result", "?")].append(w)

    # ---- I1: durability of clean acks -------------------------------------
    violations = []
    lost_clean = [w for w in buckets["ok"] + buckets["late_ok"]
                  if final_ids and wid(w) not in final_ids]
    if lost_clean:
        violations.append(
            f"I1 DURABILITY: {len(lost_clean)} clean-acked writes missing from final state")

    # ---- I2: single acker --------------------------------------------------
    acks_by_server = defaultdict(list)
    for w in buckets["ok"]:
        if w.get("server"):
            acks_by_server[w["server"]].append(parse_t(w["t"]))
    spans = {s: (min(ts), max(ts)) for s, ts in acks_by_server.items()}
    servers = sorted(spans, key=lambda s: spans[s][0])
    overlaps = []
    for i, a in enumerate(servers):
        for b in servers[i + 1:]:
            start = max(spans[a][0], spans[b][0])
            end = min(spans[a][1], spans[b][1])
            if end > start:
                overlaps.append((a, b, (end - start).total_seconds()))
    for a, b, secs in overlaps:
        violations.append(f"I2 SINGLE-ACKER: {a} and {b} clean-ack intervals overlap by {secs:.1f}s")

    # ---- measurements ------------------------------------------------------
    lost_warn = [w for w in buckets["ok_warning"] if final_ids and wid(w) not in final_ids]
    kept_warn = [w for w in buckets["ok_warning"] if wid(w) in final_ids]
    lost_info = [w for w in buckets["info"] if final_ids and wid(w) not in final_ids]
    kept_info = [w for w in buckets["info"] if wid(w) in final_ids]

    # final high-water mark per writer, for doomed-read detection
    final_hwm = defaultdict(lambda: -1)
    for fid in final_ids:
        client, _, seq = fid.rpartition("-")
        try:
            final_hwm[client] = max(final_hwm[client], int(seq))
        except ValueError:
            pass
    doomed_reads = []
    for r in reads:
        for client, hwm in (r.get("observed") or {}).items():
            if final_ids and f"{client}-{hwm}" not in final_ids and hwm > final_hwm[client]:
                doomed_reads.append((r["t"], r["client"], r.get("server", "?"), client, hwm))

    # zombie window: for each later-acking server, how long the earlier
    # server kept answering (acks or reads) after the later one's first ack
    reads_by_server = defaultdict(list)
    for r in reads:
        if r.get("result") == "ok" and r.get("server"):
            reads_by_server[r["server"]].append(parse_t(r["t"]))
    zombie = []
    if len(servers) >= 2:
        old = servers[0]
        for new in servers[1:]:
            promo = spans[new][0]
            last_seen = max(
                [t for t in acks_by_server[old] if t > promo] +
                [t for t in reads_by_server.get(old, []) if t > promo],
                default=None)
            if last_seen:
                zombie.append((old, new, (last_seen - promo).total_seconds()))

    # ---- report ------------------------------------------------------------
    print(f"== pg-ha-lab report: {run_dir.name}")
    for e in events:
        if e.get("event") in ("partition_apply", "partition_heal", "observation",
                              "node_pause", "node_resume"):
            print(f"   event {e.get('t','?')}  {e['event']}  "
                  f"{ {k: v for k, v in e.items() if k not in ('event', 't')} }")
    print(f"   final state: {len(final_ids)} rows")
    print(f"   writes: ok={len(buckets['ok'])} ok_warning={len(buckets['ok_warning'])} "
          f"late_ok={len(buckets['late_ok'])} info={len(buckets['info'])} "
          f"fail={len(buckets['fail'])} late_err={len(buckets['late_err'])}")
    print(f"   reads:  ok={sum(1 for r in reads if r.get('result') == 'ok')} "
          f"fail={sum(1 for r in reads if r.get('result') == 'fail')}")
    print()
    print("-- clean-ack spans per server (I2 evidence)")
    for s in servers:
        f_, l_ = spans[s]
        print(f"   {s}: {f_.time()} .. {l_.time()}  ({len(acks_by_server[s])} acks)")
    print()
    print("-- measurements (reported, not judged)")
    print(f"   pseudo-acks (cancelled sync wait, PG-inherent): "
          f"{len(kept_warn)} survived, {len(lost_warn)} lost")
    print(f"   indeterminate writes: {len(kept_info)} survived, {len(lost_info)} lost")
    if zombie:
        for old, new, secs in zombie:
            print(f"   zombie window: {old} still answering {secs:.1f}s after {new} began acking")
    else:
        print("   zombie window: n/a (no second acking server observed)")
    if doomed_reads:
        first, last = doomed_reads[0], doomed_reads[-1]
        print(f"   doomed reads: {len(doomed_reads)} observations "
              f"(first {first[0]} by {first[1]}, last {last[0]})")
    else:
        print("   doomed reads: none observed")
    print()
    if violations:
        print("!! INVARIANT VIOLATIONS")
        for v in violations:
            print(f"   {v}")
        for w in lost_clean[:10]:
            print(f"     lost clean ack: {wid(w)} acked by {w.get('server','?')} at {w['t']}")
        if len(lost_clean) > 10:
            print(f"     ... and {len(lost_clean) - 10} more")
        return 1
    print("ok: no invariant violations")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check.py <run-dir>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
