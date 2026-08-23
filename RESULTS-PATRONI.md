# Results: Patroni & cross-stack comparison

Patroni counterpart runs of the [CNPG scenarios](RESULTS.md), executed by the
*same* scenario scripts, fault injector, clients and checker via
`LAB_STACK=patroni make run SCENARIO=…`. Raw evidence per run in
`results/<run-id>/` (includes `patronictl list`/`history` and the DCS
configmaps).

## Stack under test

Raw **Spilo 4.1** (Patroni 4, PostgreSQL 18) StatefulSet — no Zalando
operator, so nothing mediates Patroni's own behavior. DCS = **Kubernetes
configmaps** (`DCS_ENABLE_KUBERNETES_API=true`), so "partitioned from the
API server" is the identical fault for both stacks. Routing = label-selector
`pglab-rw` service on `spilo-role=master`, the same mechanism as CNPG's
`-rw` service. Patroni timing defaults: `ttl 30 / loop_wait 10 /
retry_timeout 10` (mirroring the CNPG-at-defaults philosophy).

Config mapping:

| Cell | CNPG | Patroni |
|---|---|---|
| async-3 | defaults, no sync | `synchronous_mode: false`, `failsafe_mode: false` |
| sync-q-3 | `any/1` + `required` + `failoverQuorum` | `synchronous_mode: quorum`, `synchronous_node_count: 1`, `synchronous_mode_strict: true`, `failsafe_mode: true` |
| sync-q-5 | `any/2` + `required` + `failoverQuorum` | as sync-q-3 with `synchronous_node_count: 2`, 5 replicas |
| sync-q-2 | `any/1` + `required` + `failoverQuorum`, 2 nodes | as sync-q-3 with 2 replicas |

## Summary (Patroni runs)

| Scenario | Lost clean acks | Dual-ack | Write outage (% of fault) | Notes |
|---|---|---|---|---|
| async01 | **74** | 0 | 5% `[cut+18 → cut+32]` | offline demotion +18s, election +32s |
| sync01 | 0 | 0 | **93%** `[cut+22 → heal+2]` | failsafe demotes the safely-serving pair; lone replica can't promote |
| sync02 | 0 | 0 | **9%** `[cut+0 → cut+28]` | demote +22s, election +28s, no zombie |
| sync03 | 0 | 0 | 101% `[cut-0 → heal+3]` | structural, mirrors CNPG |

## async01 @ Patroni — async, primary's node isolated

**Measured (n=1):** on losing the DCS, the trapped leader logged *"demoting
self because DCS is not accessible and I was a leader"* at **cut+18s** and
performed an **offline demotion — PostgreSQL fully stopped**: no writes, no
reads, no doomed-read window beyond those 18s. The majority elected a new
leader at **cut+32s** (ttl expiry). Net: **74 lost clean acks** (the 18s
tail), **zero dual-ack overlap**, 72 reads of erased writes (all inside the
18s), a 14s total write gap between demotion and election, clean rewind and
convergence at heal.

## Head-to-head: async, identical fault

| Metric | CNPG 1.30 (n=3) | Patroni/Spilo 4.1 (n=1) |
|---|---|---|
| Old primary stops acking | cut+207s | **cut+18s** |
| New primary first ack | cut+70s | **cut+32s** |
| Dual-ack overlap | ~130s | **0s** |
| Lost clean acks | ~850 | **74** |
| Reads of erased writes | ~850 obs over ~3.5 min | **72 obs over 18s** |
| Write outage | none (split-brain covers it) | 14s (5% of fault) |
| Heal | rewind, converged | rewind, converged |

Patroni dominates every anomaly column of the async cell, at the price of a
14-second write gap. Qualifiers:

- n=1 so far on the Patroni side;
- CNPG's column is dominated by the `smartShutdownTimeout` finding
  ([RESULTS.md](RESULTS.md), finding 1): a fast fence would shrink it to
  roughly 30s/70s/zero-overlap/~120-lost — much closer, still behind;
- Patroni's demote-on-DCS-loss also fences on plain API-server blips — an
  availability cost this scenario does not exercise; the sync/failsafe
  cells below are where that bill arrives.

## sync01 @ Patroni — sync, {leader + sync standby} trapped: the inversion cell

**Measured (n=1):** the trapped leader kept acking cleanly (via its sync
standby) for only **22s** — then the failsafe, which requires reaching
**all** members, failed on the unreachable majority replica and demoted the
leader offline (full stop). The lone majority replica never promoted (in
quorum mode it cannot prove it holds the acked frontier without the other
sync member). Result: zero loss, **93% write outage** `[cut+22 → heal+2]`;
at heal the old leader re-acquired its lock and resumed in ~2s. Contrast
CNPG: 37% outage (served safely until its fence at +213s), and 0% under
CNPG's documented fencing semantics. **CNPG's quorum-legitimized minority
wins this geometry decisively.**

## sync02 @ Patroni — sync 5-node, {leader + replica} trapped

**Measured (n=1):** clean acks froze at the cut instant (needs 2 acks, one
reachable); the leader demoted offline at ~+22s — **no zombie at all** (vs
CNPG's 120s), only 88 reads-of-erased-writes in an 11s window (vs 1644 over
200s) and 4 erased cancelled-sync commits. The majority (3 of 4 quorum
members) elected a new leader at **cut+28s** (vs CNPG's +91s). Zero loss,
**9% outage** (vs 30%). **Patroni wins the majority-favoring geometry** on
both speed and hygiene.

## sync03 @ Patroni — sync 2-node, leader isolated

**Measured (n=1):** structural mirror of CNPG's cell: acks froze at cut+0,
leader demoted offline ~+20s, the surviving standby (the whole sync set)
took over but `synchronous_mode_strict` blocked its writes until the old
node rejoined at heal — first ack heal+3s, **101% outage** (CNPG: 102%).
Zero loss, and the same cancelled-sync timeline split: **kept 49 / erased
3** (CNPG: 40/10). A tie, decided by physics rather than either stack.

## Overall verdict so far

Both stacks: **zero acked-write loss in every sync+quorum cell**. The
availability split is geometry-dependent and symmetric:

- **async:** Patroni decisively better (74 vs ~850 lost acks, 0 vs ~130s
  dual-ack) — fast self-demotion beats slow fencing.
- **sync, minority-favoring (sync01):** CNPG decisively better (37% vs 93%
  outage) — quorum failover legitimizes the trapped pair; Patroni's
  all-members failsafe kills it.
- **sync, majority-favoring (sync02):** Patroni better (9% vs 30% outage, no
  zombie vs 120s) — again fast demotion + fast election vs slow fence.
- **sync, 2-node (sync03):** tie — the config's physics dominates.

Each stack carries one fencing behavior worth improving: CNPG's
`smartShutdownTimeout` grace + all-peers isolation check (most of its
deficit in async01/sync02), Patroni's all-members failsafe (all of its deficit in
sync01).
