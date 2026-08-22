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

    # ack segments per server (>10s silence starts a new segment) — a plain
    # min/max span hides service gaps (e.g. fenced then resumed post-heal)
    def segments(ts, gap=10.0):
        ts = sorted(ts)
        segs = [[ts[0], ts[0]]]
        for t in ts[1:]:
            if (t - segs[-1][1]).total_seconds() > gap:
                segs.append([t, t])
            else:
                segs[-1][1] = t
        return segs

    segs_by_server = {s: segments(ts) for s, ts in acks_by_server.items()}
    spans = {s: (min(ts), max(ts)) for s, ts in acks_by_server.items()}
    servers = sorted(spans, key=lambda s: spans[s][0])
    overlaps = []
    for i, a in enumerate(servers):
        for b in servers[i + 1:]:
            for sa in segs_by_server[a]:
                for sb in segs_by_server[b]:
                    start = max(sa[0], sb[0])
                    end = min(sa[1], sb[1])
                    if end > start:
                        overlaps.append((a, b, (end - start).total_seconds()))
    for a, b, secs in overlaps:
        violations.append(f"I2 SINGLE-ACKER: {a} and {b} clean-ack segments overlap by {secs:.1f}s")

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
            # a read observed a row that does not exist in the final state —
            # mid-sequence holes count too (the writer may have continued on
            # the new primary, pushing the final high-water mark past the
            # doomed id), so do NOT gate this on hwm > final_hwm
            if final_ids and f"{client}-{hwm}" not in final_ids:
                doomed_reads.append((r["t"], r["client"], r.get("server", "?"), client, hwm))

    # write-availability gaps: periods with no clean ack from ANY server —
    # the cluster-wide write outage windows, annotated against the fault
    # timeline (partition_apply / partition_heal events)
    anchors = {}
    for e in events:
        if e.get("event") in ("partition_apply", "partition_heal") and e.get("t"):
            anchors.setdefault(e["event"], parse_t(e["t"]))

    def rel(t, anchor_name, label):
        at = anchors.get(anchor_name)
        if at is None:
            return ""
        delta = (t - at).total_seconds()
        sign = "+" if delta >= 0 else "-"
        return f"{label}{sign}{abs(delta):.0f}s"

    availability_gaps = []
    all_ack_ts = sorted(t for ts in acks_by_server.values() for t in ts)
    if all_ack_ts:
        merged = segments(all_ack_ts)
        for prev, nxt in zip(merged, merged[1:]):
            availability_gaps.append((prev[1], nxt[0], (nxt[0] - prev[1]).total_seconds()))

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
    print("-- clean-ack segments per server (I2 evidence; >10s silence splits)")
    for s in servers:
        print(f"   {s}: {len(acks_by_server[s])} acks in {len(segs_by_server[s])} segment(s)")
        for a, b in segs_by_server[s]:
            print(f"      {a.time()} .. {b.time()}  ({(b - a).total_seconds():.0f}s)")
    print()
    print("-- measurements (reported, not judged)")
    print(f"   cancelled-sync commits (acked with warning, local-only durability; "
          f"PG-inherent): kept {len(kept_warn)}, erased {len(lost_warn)}")
    print(f"   indeterminate writes: kept {len(kept_info)}, erased {len(lost_info)}")
    if availability_gaps:
        fault_len = None
        if "partition_apply" in anchors and "partition_heal" in anchors:
            fault_len = (anchors["partition_heal"] - anchors["partition_apply"]).total_seconds()
        print("   write-availability gaps (no clean acks from any server, >10s):")
        for a, b, secs in availability_gaps:
            marks = " ".join(x for x in (rel(a, "partition_apply", "cut"),
                                         rel(b, "partition_heal", "heal")) if x)
            pct = f" = {100 * secs / fault_len:.0f}% of fault duration" if fault_len else ""
            print(f"      {a.time()} .. {b.time()}  ({secs:.0f}s)  [{marks}]{pct}")
    else:
        print("   write-availability gaps: none (some server acked throughout)")
    if zombie:
        for old, new, secs in zombie:
            print(f"   old primary serving after takeover: {old} answered for "
                  f"{secs:.1f}s after {new} began acking")
    else:
        print("   old primary serving after takeover: n/a (no takeover observed)")
    if doomed_reads:
        first, last = doomed_reads[0], doomed_reads[-1]
        print(f"   reads of erased writes (G1a-like): {len(doomed_reads)} observations "
              f"(first {first[0]} by {first[1]}, last {last[0]})")
    else:
        print("   reads of erased writes: none observed")
    print()
    if lost_clean:
        lost_file = run_dir / "lost_clean_acks.txt"
        with lost_file.open("w") as fh:
            for w in sorted(lost_clean, key=lambda w: w["t"]):
                fh.write(f"{w['t']} {wid(w)} server={w.get('server','?')} client={w['client']}\n")
    if violations:
        print("!! INVARIANT VIOLATIONS")
        for v in violations:
            print(f"   {v}")
        for w in lost_clean[:10]:
            print(f"     lost clean ack: {wid(w)} acked by {w.get('server','?')} at {w['t']}")
        if len(lost_clean) > 10:
            print(f"     ... and {len(lost_clean) - 10} more (full list: {lost_file})")
        return 1
    print("ok: no invariant violations")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check.py <run-dir>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
