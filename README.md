# pg-ha-lab

A Jepsen-style lab for PostgreSQL HA operators on Kubernetes.

**Measured results, per-scenario diagrams and findings: [RESULTS.md](RESULTS.md)
(CNPG) and [RESULTS-PATRONI.md](RESULTS-PATRONI.md) (Patroni + cross-stack
comparison).**

The lab injects network partitions (and other faults) into a kind cluster
running a managed PostgreSQL setup, drives client workloads from *inside* each
partition, records a full operation history, and checks invariants after the
fault heals. 

## Invariants checked

1. **Durability of clean acks** — every write acknowledged without warnings at
   `synchronous_commit=on` must be present exactly once in the final state.
   A violation here is a bug in the stack under test (or in PostgreSQL).
2. **Single acker** — no two servers may acknowledge clean writes
   concurrently (checked from history overlap per server identity).

Other properties are measured:

- cancelled-sync commits: `COMMIT` successes carrying the "already committed
  locally" warning after a cancelled sync-replication wait — acknowledged to
  the client with local-only durability (a PostgreSQL-inherent channel,
  bucketed separately so it is never conflated with operator bugs); reported
  as kept vs erased depending on whether the row survives recovery;
- indeterminate ops (connection lost / hung commit abandoned);
- write-availability gaps: periods with no acknowledged write from any
  server, with offsets relative to the fault and as % of fault duration;
- old primary serving after takeover: how long the deposed primary keeps
  answering clients after the new primary starts acknowledging writes;
- reads of erased writes: reads observing data that does not survive
  recovery (Adya G1a-like "aborted reads").

## Layout

```
kind/            kind cluster topology (1 control-plane + 5 workers)
stacks/cnpg/     CNPG install, cluster configs (the test matrix), adapter lib
stacks/patroni/  Patroni (Spilo) stack: cluster configs + adapter
nemesis/         fault injectors: pairwise iptables partitions, pauses
harness/client/  Go workload client (clean writer / cancel writer / reader)
scenarios/       runnable end-to-end scenarios (deploy → fault → heal → check)
checker/         history + final-state invariant checker and report
results/         one directory per run (gitignored)
```

## Test matrix (CNPG)

| config | file | description |
|---|---|---|
| async-3   | `stacks/cnpg/clusters/async-3.yaml`   | 3 instances, defaults (async) — the #7407 baseline |
| sync-nq-3 | `stacks/cnpg/clusters/sync-nq-3.yaml` | sync `any/1`, `required`, **no** failoverQuorum |
| sync-q-3  | `stacks/cnpg/clusters/sync-q-3.yaml`  | sync `any/1`, `required`, failoverQuorum |
| sync-nq-5 | `stacks/cnpg/clusters/sync-nq-5.yaml` | 5 instances, sync `any/2`, no failoverQuorum |
| sync-q-5  | `stacks/cnpg/clusters/sync-q-5.yaml`  | 5 instances, sync `any/2`, failoverQuorum |

## Quickstart

```sh
make cluster-up          # kind cluster (6 nodes)
make cnpg-install        # pinned CNPG operator
make client-image        # build + load the workload client image
make run SCENARIO=async01-baseline    # reproduce the known async loss (harness validation)
make run SCENARIO=sync01-asym-3     # 3-node asymmetric partition, strongest config
make run SCENARIO=sync02-asym-5     # 5-node asymmetric partition, strongest config
LAB_STACK=patroni make run SCENARIO=async01-baseline   # same scenario against Patroni
make check RUN=results/<run-id>         # (re-)run the checker on a collected run
make cluster-down
```

`async01` doubles as harness validation: it must detect lost acknowledged writes
on the async baseline (the original cloudnative-pg#7407 behavior). A checker
that has never seen a positive proves nothing.

## Fault vocabulary (nemesis/)

- `partition.sh apply "<groupA>" "<groupB>" [--one-way]` — pairwise iptables
  DROP between two node groups (node IPs + pod CIDRs), arbitrary geometries
  including asymmetric; `partition.sh heal` removes everything.
- `pause.sh node <node> [resume]` — freeze/unfreeze an entire kind node
  (docker pause), a coarse process-pause nemesis.

Planned: partition during sync-config change, SIGSTOP of the instance
manager only, lossy links (tc netem), replica destroy-and-recreate during
partition, flapping partitions.

## Scenario anatomy

Each scenario script: deploys a cluster config, waits healthy, starts client
pods pinned to each worker (writers + readers, connecting through the `-rw`
service so stale kube-proxy routing is part of the experiment), records a
baseline, applies a fault at `t0`, holds it, heals, waits for convergence,
collects everything (client histories from pod logs, operator logs, events,
final table dump), then runs the checker.

## History format

One JSON object per line, per client (from pod logs):

```json
{"t":"2026-08-21T12:00:00.123Z","client":"clean-w2","mode":"clean","op":"write",
 "seq":412,"result":"ok","server":"10.244.3.5","ms":12.3}
```

`result` ∈ `ok | ok_warning | fail | info | late_ok`; `server` is
`inet_server_addr()` reported by the acking backend on the same round trip.
