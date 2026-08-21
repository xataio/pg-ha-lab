# Patroni stack (future)

Placeholder for the Patroni side of the comparison. The plan: Spilo (or the
Zalando postgres-operator) on the same kind topology, **using the Kubernetes
API as DCS**, so "partitioned from the DCS" and "partitioned from the API
server" are the same fault for both stacks. Config matrix mirroring CNPG's:

| config | description |
|---|---|
| async-3   | defaults, no synchronous replication |
| sync-3    | `synchronous_mode: true`, 3 nodes |
| sync-fs-3 | `synchronous_mode: true` + `failsafe_mode: true` |
| sync-q-5  | `synchronous_mode: quorum`, `synchronous_node_count: 2`, failsafe |

## Adapter contract

Implement `stacks/patroni/lib.sh` with the same functions as
`stacks/cnpg/lib.sh`:

- `stack::deploy <config.yaml>` — deploy and block until healthy
- `stack::wait_healthy <timeout>`
- `stack::primary_pod` — current leader pod name
- `stack::node_of <pod>` / `stack::pod_ip <pod>` / `stack::instances`
- `stack::rw_service` — the writer endpoint clients should use
- `stack::app_secret` — secret with `username`/`password` keys
- `stack::collect <outdir>` — cluster state, events, Patroni logs,
  `patronictl history`/`list` output
- `stack::destroy`
- `stack::dump_final_ids <outfile>`

Scenario scripts source `stacks/$STACK/lib.sh` and use only these functions,
so every scenario runs unchanged against either stack.

Fairness notes for the eventual comparison:

- keep `ttl`/`loop_wait`/`retry_timeout` at Patroni defaults, and CNPG probe
  timings at CNPG defaults, in the primary matrix; add tuned variants
  separately;
- record which replica holds the sync/quorum key before each fault
  (`patronictl list`), since it determines geometry outcomes;
- point the identical nemesis schedule at both stacks.
