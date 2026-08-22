# Results

Measured behavior of CloudNativePG **1.30.0** under network partitions, per
scenario. All faults are full pairwise cuts (node IPs + pod CIDRs) held for
300s. Offsets are relative to `cut` (partition applied) and `heal`
(partition removed). See the [README](README.md) for invariants and
terminology; raw evidence for every run lives in `results/<run-id>/`.

## Summary

| Scenario | Config | Lost clean acks | Dual-ack overlap | Write outage (% of fault) | Notes |
|---|---|---|---|---|---|
| s01 | async, defaults | **~850** | **~130s** | 0% | availability preserved via split-brain |
| s02 | sync any/1 + quorum | 0 | 0 | 37% `[cut+213 → heal+24]` | outage manufactured by isolation fence |
| s03 | sync any/2 + quorum | 0 | 0 | 30% `[cut+0 → promotion+91]` | healthy pattern; zombie 120s |
| s04 | sync any/1, 2 nodes | 0 | 0 | 102% `[cut+0 → heal+6]` | structural: no writes without the peer |
| s05 | async, operator trapped | **~840 in 5/7 runs** | 0 | 38% `[cut+210 → heal+24]` | heal-time race; loss without split-brain |

Recurring signatures across all runs: the primary-isolation fence SIGTERMs at
~cut+30s but established sessions keep operating until ~cut+210s (the 180s
`smartShutdownTimeout` smart-shutdown grace); promotion, where allowed, lands
at ~cut+70..91s.

---

## s01 — async baseline, primary isolated

Config: `instances: 3`, no synchronous replication (the CNPG default and the
original [cloudnative-pg#7407](https://github.com/cloudnative-pg/cloudnative-pg/issues/7407)
reproduction). Harness-validation case: the checker must detect the loss.

```mermaid
flowchart LR
    subgraph iso["⚡ isolated zone"]
        P[("pglab-1<br/>PRIMARY")]
        CA["clients"]
        CA -->|writes acked| P
    end
    subgraph maj["majority zone"]
        CP["control plane<br/>API server + operator"]
        R1[("pglab-2<br/>replica")]
        R2[("pglab-3<br/>replica")]
        CB["clients"]
        CP -->|"promotes at cut+70s"| R1
        CB -->|writes acked| R1
    end
    P -. ✗ WAL .- R1
    P -. ✗ WAL .- R2
    P -. ✗ API .- CP
```

**Measured (n=3, consistent):** promotion at cut+70s; old primary keeps
acking its zone until cut+207s (fence SIGTERM +30s, smart-shutdown grace
+180s) → **~130s with two acking primaries** and **~850 clean-acked writes
erased** by `pg_rewind` on heal; ~850 reads of erased writes. Write
availability never drops. Every anomaly sits inside the smart-shutdown grace:
with a fast shutdown on fencing, the fence (+30s) would beat promotion (+70s)
and this geometry would have no dual-ack window at all.

---

## s02 — sync + quorum, primary and its sync standby trapped together

Config: `instances: 3`, `synchronous: {method: any, number: 1,
dataDurability: required, failoverQuorum: true}`.

```mermaid
flowchart LR
    subgraph iso["⚡ isolated zone"]
        P[("pglab-1<br/>PRIMARY")]
        R1[("pglab-2<br/>replica<br/>(acking sync)")]
        CA["clients"]
        CA -->|"acked until fence (cut+213s)"| P
        P -->|"WAL + sync ack"| R1
    end
    subgraph maj["majority zone"]
        CP["control plane<br/>API + operator"]
        R2[("pglab-3<br/>replica")]
        CP -->|"quorum check DENIES failover<br/>R=1 W=1 N=2"| R2
    end
    P -. ✗ WAL .- R2
    P -. ✗ API .- CP
```

**Measured (n=2):** zero loss, zero dual-ack. The quorum check denied
promotion every reconcile cycle (logged: `R=1, W=1, N=2`) — correctly, since
the reachable replica may be missing acked commits. The trapped pair kept
serving *safely* until the isolation fence killed the primary at cut+213s
(all-peers semantics — the docs' any-peer wording implies it should NOT fence
here), producing a **37% outage that would be 0% under the documented
semantics**. On heal the same primary resumed; nothing was rewound.

---

## s03 — sync + quorum, 5 nodes, primary and one replica trapped

Config: `instances: 5`, `synchronous: {method: any, number: 2,
dataDurability: required, failoverQuorum: true}`.

```mermaid
flowchart LR
    subgraph iso["⚡ isolated zone"]
        P[("pglab-1<br/>PRIMARY<br/>commits hang: 1 ack < 2")]
        R1[("replica")]
        CA["clients"]
        CA -->|"reads + hung writes"| P
        P -->|WAL| R1
    end
    subgraph maj["majority zone"]
        CP["control plane<br/>API + operator"]
        R2[("replica")]
        R3[("replica")]
        R4[("replica")]
        CB["clients"]
        CP -->|"quorum ALLOWS failover<br/>R=3 W=2 N=4 → promote at cut+91s"| R2
        CB -->|writes acked| R2
    end
    P -. ✗ .- R2
    P -. ✗ .- CP
```

**Measured (n=2):** the strongest config's headline — **zero clean-ack loss,
zero dual-ack**. Clean acks freeze at the cut instant (write quorum
unreachable); quorum-approved promotion restores service at cut+91s (outage
30% of fault). Costs are visibility-side: the fenced old primary answers
reads for **120s** after takeover (deterministic: promotion ~+85s → fence
effective ~+205s), mints ~20 cancelled-sync commits (all erased), and its
zone observes ~1600 reads of erased writes.

---

## s04 — sync, two nodes, primary isolated

Config: `instances: 2`, `synchronous: {method: any, number: 1,
dataDurability: required, failoverQuorum: true}`.

```mermaid
flowchart LR
    subgraph iso["⚡ isolated zone"]
        P[("pglab-1<br/>PRIMARY<br/>commits hang")]
        CA["clients"]
        CA -->|"cancelled-sync commits<br/>(10, all erased)"| P
    end
    subgraph maj["majority zone"]
        CP["control plane<br/>API + operator"]
        R1[("pglab-2<br/>replica → promoted<br/>commits hang too:<br/>its only standby is pglab-1")]
        CB["clients"]
        CP -->|promotes| R1
        CB -->|"cancelled-sync commits<br/>(40, all KEPT)"| R1
    end
    P -. ✗ .- R1
    P -. ✗ .- CP
```

**Measured (n=2):** zero loss, zero dual-ack — promotion is always safe (the
survivor holds every acked commit) — but **write outage spans the entire
fault (102%)**: the promoted survivor cannot commit until the old primary
rejoins as its replica (first ack heal+6s). Unique to this cell: the
cancelled-sync-commit timeline split — the same client behavior yields
**kept** commits on the winning side (40) and **erased** ones on the losing
side (10).

---

## s05 — async, operator trapped with the primary

Config: as s01, but the (single-replica) operator is re-pinned onto the
primary's node before the cut. Identical fault to s01; the only variable is
operator placement.

```mermaid
flowchart LR
    subgraph iso["⚡ isolated zone"]
        P[("pglab-1<br/>PRIMARY")]
        OP["operator<br/>(cannot reach API)"]
        CA["clients"]
        CA -->|"acked until fence (cut+210s)"| P
    end
    subgraph maj["majority zone"]
        CP["control plane<br/>API server (no operator!)"]
        R1[("replica")]
        R2[("replica")]
    end
    OP -. ✗ API .- CP
    P -. ✗ .- R1
    P -. ✗ .- CP
```

**Measured (n=7):** no promotion during the fault — automated recovery is
lost; the majority zone has replicas and an API server but no decision-maker.
The primary's zone is served until the fence (cut+210s), then total outage.
**The durability outcome is decided by a race at heal**: the returning
operator re-acquires leadership at ~heal+8s and promotes a stale replica at
~heal+24s, unless the fenced old primary's `wait-for-get-cluster` retry
happens to fire first and it resumes. Observed: **writes lost in 5/7 runs
(~840 each), survived in 2/7** — acked-write loss *without any dual-ack*,
via promote-past-unreachable-writes after the network is healthy again.
`.spec.failoverDelay` (default 0) would tilt this race toward survival.

---

## Findings worth raising upstream

1. **`smartShutdownTimeout` blunts every fencing path.** The isolation-check
   SIGTERM arrives at ~+30s as documented, but the termination path runs a
   *smart* shutdown (180s default) that only blocks new connections;
   established sessions keep writing (s01: the entire dual-ack window and all
   lost acks), reading, and minting cancelled-sync commits (s02–s05).
   Effective fence latency is ~210s vs the documented "~30s". The instance
   manager knows its own isolation state, so "fast shutdown when fencing" is
   a plausible fix; lowering `.spec.smartShutdownTimeout` is the available
   mitigation (at the cost of blunt ordinary shutdowns).
2. **Isolation-check docs contradict the code.** Docs: fence when the
   primary "cannot reach **any** other instance". Code
   (`pinger.go ensureInstancesAreReachable`): fence unless it can reach
   **every** instance (first unreachable peer fails the probe). Behavioral
   consequence measured in s02: an API-isolated primary with a healthy,
   acking sync standby gets fenced, converting a safe, quorum-protected
   partition into a 37% outage.
3. **The heal-time race (s05).** After a partition in which no failover
   could run, the operator promotes a stale replica within seconds of
   regaining API access, racing the fenced primary's restart — losing acked
   writes ~2/3 of the time in our environment, without split-brain. A grace
   period for a returning `targetPrimary` (or `failoverDelay` applying at
   heal) would close it.
