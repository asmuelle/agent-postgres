# Mobile Fleet Monitor — Sliced Plan

A minimal iOS surface that monitors multiple Postgres instances and offers
one-tap quick fixes. Built on the **existing** Rust FFI + Swift bridge, which
already compile and link into the `PgAgentMobile` target. No Rust/UniFFI
changes are required for Slices 1–3 (this is deliberate — it avoids the FFI
checksum-mismatch footgun).

## Backend already in place

| Capability             | FFI                              | Swift bridge (`BridgeManager+Postgres`) |
| ---------------------- | -------------------------------- | --------------------------------------- |
| Long-running queries   | `rshell_pg_list_sessions`        | `pgListSessions(connectionId:)`         |
| Lock / deadlock view   | `rshell_pg_list_locks`           | `pgListLocks(connectionId:)`            |
| Cancel a query         | `rshell_pg_cancel_backend(pid)`  | `pgCancelBackend(connectionId:pid:)`    |
| Kill a connection      | `rshell_pg_terminate_backend`    | `pgTerminateBackend(connectionId:pid:)` |
| VACUUM / ANALYZE       | `rshell_pg_execute`              | `pgExecute(...)`                        |
| Multiple instances     | —                                | `PostgresConnectionManager.shared`      |

All of `BridgeManager+Postgres.swift`, `PostgresConnectionManager.swift`, and
the generated `bindings/pg_agent.swift` are already in the `PgAgentMobile`
target's sources (`project.yml`). The only gap is mobile UI.

FFI record shapes:

- `FfiPgSessionDetail { pid: Int32, datname, usename, clientAddr?, state, query?, waitEvent?, queryStart? (epoch secs) }`
- `FfiPgLockDetail { pid: Int32, relation?, mode, granted: Bool, blockedByPid: Int32? }`

## Slices

### Slice 1 — Fleet overview + Activity tab ✅ (this slice)

- `FleetHealthStore` — `@MainActor` poller. For each saved profile: connect via
  `PostgresConnectionManager`, run `pgListSessions` + `pgListLocks`, derive a
  per-instance health glance (reachable, active backends, # long-running,
  # blocked locks). Auto-refresh on a timer + pull-to-refresh.
- `MobileFleetMonitorView` — list of instance health cards; presented as a sheet
  from the connection list. Tap an instance → Activity.
- `MobileInstanceActivityView` — `pgListSessions` sorted oldest-first; per-row
  swipe actions **Cancel** (`pgCancelBackend`) and **Terminate**
  (`pgTerminateBackend`), each gated by a confirmation alert showing the exact
  effect and target.
- Entry point: a "Monitor" toolbar button on the compact connection list.

Proves the whole approach end-to-end with zero Rust changes.

### Slice 2 — Locks / deadlock chains ✅

- `LockChainModel` — pure `lockWaitGroups(from:)` that shapes `pgListLocks`
  edges into blocker→waiters groups (de-dups waiters, flags chains where the
  blocker is itself blocked). Unit-tested.
- `MobileInstanceLocksView` — renders the groups; quick fix = "Terminate the
  blocker" on the head of a wait chain (`pgTerminateBackend`), gated by a
  confirmation alert that warns when the blocker is itself in a chain.
- `MobileInstanceDetailView` — Activity / Locks tabs behind a segmented
  control, mirroring the macOS activity monitor. (Maintenance tab lands in
  Slice 3.)

### Slice 3 — Maintenance / vacuum

- A bloat/dead-tuple candidates query against `pg_stat_user_tables`
  (net-new SQL, runs through `pgExecute` — no FFI change).
- Per-table **VACUUM (ANALYZE)** button; **VACUUM FULL** behind extra confirm.

### Slice 4 — Safety posture (biometric gate)

- Route destructive fixes (`terminate_backend`, `VACUUM FULL`) through a
  Face/Touch ID check using the already-linked `LocalAuthentication` +
  `MobilePrivacyGateView` pattern. Non-destructive fixes stay friction-free.

### Slice 5 — Background monitoring + notifications

- BGAppRefresh poll; local notification when an instance crosses a threshold
  (long-running count, blocked locks). Fits the "monitor" framing.

### Slice 6 — iPad regular layout + polish

- Surface the monitor in the iPad `NavigationSplitView` (currently only wired
  into the compact connection list), empty/error states, thresholds in Settings.

## Decisions

- **Destructive posture (Slice 4):** monitoring + non-destructive fixes
  (VACUUM/ANALYZE, cancel-query) stay friction-free; `terminate_backend` and
  `VACUUM FULL` get a biometric speed bump. Killing a prod backend from a phone
  on the train is exactly the fat-finger risk worth gating.
- **Long-running threshold:** default 5s (`FleetHealthStore.longRunningThreshold`),
  later configurable in Settings.
</content>
</invoke>
