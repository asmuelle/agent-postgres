# pgAgent Product Roadmap

Date: 2026-07-04
Status: living document — update slice status as work ships; keep phase ordering honest when priorities shift.

## Positioning

**"The Postgres cockpit, native on every Apple device."**

pgAgent does not compete with Postico/TablePlus as a fourth query editor, nor with
DataGrip/pgAdmin as a cross-platform IDE. It owns the operations wedge — monitoring,
locks, maintenance, on-call response, safety against production — where no native
Apple tool exists at all, and where the iPhone/iPad market is entirely empty.
The editor must be *good enough to not lose users*; the cockpit is *why they come*.

Three structural moats no Electron/Java/web competitor can copy:

1. **On-call on iPhone** — alert → lock chain → Face ID → fix, end to end on device.
2. **On-device AI** (FoundationModels) — "AI that has read your schema but your data
   never leaves the device."
3. **Apple-shaped architecture** — Mac-as-monitoring-hub with CloudKit push relay,
   Handoff, App Intents, Live Activities, widgets, keychain/biometrics.

## Current state (assets to build on)

| Asset | Where | Maturity |
|---|---|---|
| Query tabs, editor, results grid (50k rows, insert/update/delete) | `PostgresQueryTab*`, `PostgresResultsTable` | Shipping |
| CSV / JSONL / Parquet export | `PostgresQueryTabView` export pipeline | Shipping |
| Schema browser, ERD, object wizard, DDL views | `SidebarView`, `PostgresERD*`, `Postgres*DDL` | Shipping |
| EXPLAIN visualizer | `PostgresExplainVisualizerView` | Shipping, needs depth |
| Activity monitor, lock/deadlock chains | `PostgresActivityMonitorView`, `LockChainModel` | Shipping |
| Vacuum/bloat maintenance tab | `MaintenanceModel` (mobile), macOS views | Shipping (Slice 3 of mobile plan) |
| Fleet overview + background alerts (iOS) | `FleetHealthStore`, `FleetBackgroundMonitor` | Shipping, BGAppRefresh-limited |
| Biometric gate on destructive fixes | `BiometricGate` (iOS), `SSHKeyAccessCoordinator` (macOS) | Shipping |
| Safe Apply (guarded DDL/DML) | `PostgresSafeApply*` | Shipping |
| Server doctor, security patch monitor | `src/doctor.rs`, `src/security_patch.rs` | Shipping (macOS direct-distribution only) |
| SSH tunnels (first-class, incl. jump hosts) | `SSHTunnelResolver`, `src/port_forward.rs` | Shipping — heritage advantage |
| On-device AI assistant | `PgAIAssistant` (FoundationModels) | Early |
| Widgets (macOS + iOS) | `PgAgentWidgets`, `PgAgentMobileWidgets` | Early |
| Routine editor | `docs/routine-editor-plan.md` | Slice 1 shipped, 2–6 open |
| Mobile fleet monitor | `docs/mobile-monitor-plan.md` | Slice 1 shipped, 2–6 open |

Distribution today: macOS via Developer ID + Sparkle (un-sandboxed; doctor needs
system tools). iOS target builds but is not yet on the App Store.

---

## Phase 0 — Foundation hardening (now → +4 weeks)

Goal: a tree we can ship from weekly. Mostly complete as of 2026-07-04 review-fix pass.

| Slice | Work | Status |
|---|---|---|
| 0.1 | Fix all 2026-07-04 review findings (insert-row CAST bug, biometric gate stub, entitlements, CI iOS job, collector locks, etc.) | In progress — see review session |
| 0.2 | `src/ffi.rs` module split (`src/ffi/` by domain) — every panic here is an app crash; 5k-line file is the biggest stability liability | Planned |
| 0.3 | Split `PostgresQueryTabView` (2.3k lines), `PostgresResultsTable` (2k), `SidebarView` (1.7k) into focused files; extract export pipeline | Planned |
| 0.4 | Per-tab invalidation for `PostgresQueryTabsStore` (stop full-array diffs of 50k-row results on unrelated tab updates) | Planned |
| 0.5 | Shared-directory source split for `PgAgentMobile` (kill the per-file target list drift class) | Planned |
| 0.6 | TestFlight pipeline: archive + upload lane in `justfile` (`just ios-archive`, `just ios-upload`), App Store Connect app record, internal TestFlight group | Planned |

Exit criteria: CI green incl. iOS job; no file > 800 lines in touched areas;
TestFlight build installable on a real device.

---

## Phase 1 — The on-call story (weeks 2–10) · **category-defining**

Goal: the demo — push arrives, open iPhone, see blocking query, Face ID, kill it.

### 1.1 Mac-as-monitoring-hub with CloudKit push relay (the keystone)

iOS BGAppRefresh cannot deliver reliable alerting; a vendor cloud contradicts the
privacy story. Instead the **Mac app becomes the always-on monitor** and relays
alerts to iPhone/iPad via CloudKit (record change → silent/alert push).

- Mac side: background monitoring service reusing `FleetHealthStore` polling
  rules; writes `Alert` records to the user's private CloudKit database.
- iOS side: CloudKit subscription → push → local notification with deep link to
  the affected instance/lock chain. Works even when the iOS app was never opened
  that day.
- Menu bar presence on macOS: fleet-health item (green/amber/red), click → mini
  dashboard, mirrors what iOS widgets show.
- Fallback when the user has no Mac running: keep BGAppRefresh best-effort mode
  (already shipped) and say so honestly in settings ("alert latency: minutes vs
  seconds").
- Entitlements: CloudKit + push for both app targets; needs App Store-capable
  provisioning even for the Developer ID Mac build (CloudKit works with
  Developer ID).

Acceptance: kill the Wi-Fi on the iPhone, lock a row in a test DB from a laptop,
unlock phone → notification present within seconds of Mac detecting the lock.

### 1.2 Alert → action loop on iOS

- Notification deep-links into the lock/deadlock chain view (exists) with the
  offending PID pre-selected.
- One-tap guarded actions behind the biometric gate (exists): cancel query,
  terminate backend, with Safe Apply-style preview of blast radius.
- Post-action verification: re-poll and show "chain cleared" confirmation.

### 1.3 Live Activities + widgets

- Live Activity for long-running operations: query > N seconds, vacuum progress,
  export progress. Dynamic Island states: running / done / failed.
- Lock-screen + Home-screen widget: fleet health tiles (extend
  `PgAgentMobileWidgets`).
- macOS widget parity where sensible.

### 1.4 Environment badges + read-only mode (safety brand pillar)

- Per-connection environment tag: production / staging / dev. Production gets an
  unmissable treatment (red accent on tab bar, sidebar, and window title) on both
  platforms.
- Per-connection read-only mode: strips write affordances from grid/editor UI and
  refuses non-SELECT at the bridge layer (defense in depth, not just UI).
- Audit log of every write executed through pgAgent (local, exportable).

Exit criteria: full on-call demo recordable as the App Store preview video.

---

## Phase 2 — Funnel: onboarding + editor credibility (weeks 8–16)

Goal: first-run-to-first-query < 60 seconds; Postico defectors don't bounce.

### 2.1 Provider-aware onboarding

- Paste any `postgres://` / `postgresql://` URL → parsed into a profile
  (host, port, db, user, TLS), password straight into keychain.
- Provider integrations, in order of user volume: **Supabase** (API token → list
  projects → import connection), **Neon**, **RDS/Aurora** (via AWS profile or
  paste), **Fly.io**, **Railway**. Each is a thin "list databases, mint
  connection profile" client — no provider lock-in features.
- Detect `~/.pg_service.conf` and `~/.pgpass` on macOS and offer import.
- First-run experience: sample database option (connect to a bundled read-only
  demo dataset via localhost if Postgres.app detected, else a hosted sample) so
  screenshots/AI features are explorable before the user risks a real DB.

### 2.2 Editor catch-up (good-enough bar vs Postico/TablePlus)

- Schema-aware autocomplete: tables/columns/functions from `PgSchemaStore`,
  keyword+cast aware, ranked by schema proximity. This is the single most-missed
  feature vs competitors.
- ⌘K command palette: connections, tables, saved queries, actions ("vacuum
  table…", "explain last query").
- JSON/JSONB cell viewer-editor with tree + raw modes (cell inspector exists;
  add editing + path copy).
- Multiple result sets per script run; per-statement timing gutter.
- Snippet library with placeholders (align with routine editor work).

### 2.3 Sync (opt-in)

- iCloud/CloudKit sync of connection profiles (sans secrets), saved queries,
  snippets, environment tags.
- Optional credential sync via `kSecAttrSynchronizable` keychain items —
  explicit opt-in per connection, default stays ThisDeviceOnly.

Exit criteria: cold install → connected to a Supabase project → autocompleted
query executed, in under a minute, on video.

---

## Phase 3 — DBA table stakes (weeks 12–22)

Goal: "best Postgres tool" is a defensible claim in reviews, not a tagline.

### 3.1 Query performance dashboard (`pg_stat_statements`)

- Top queries by total/mean time, calls, rows; sparkline history via periodic
  snapshots stored locally (feeds off the monitoring poller from 1.1).
- Regression detection: "this query got 4× slower since Tuesday."
- One tap from a slow statement → EXPLAIN visualizer → AI narration (3.4).
- Graceful degradation when the extension isn't installed: one-tap
  `CREATE EXTENSION` behind Safe Apply, or fall back to `pg_stat_activity`
  sampling.

### 3.2 Schema diff + migration generation (**pairs with Safe Apply — the feature DBAs pay for on sight**)

- Diff two connections (or two schemas): tables, columns, types, defaults,
  constraints, indexes, functions, RLS policies, grants.
- Output: reviewable, ordered migration script (with lock-impact annotations:
  "this `ALTER` takes ACCESS EXCLUSIVE") feeding directly into Safe Apply's
  preview/confirm flow.
- Reverse diff for rollback script generation.
- Reuses existing DDL renderers (`PostgresTableDDL`, `PostgresNodeDDL`) and the
  Rust introspection layer.

### 3.3 Index advisor + replication health

- Unused / duplicate / redundant-prefix index detection (catalog-only, cheap);
  missing-index hints from `pg_stat_user_tables` seq-scan ratios.
- Replication panel: WAL lag per replica, replication slots (incl. dangerous
  retained-WAL warnings), logical replication subscription status. Alerts from
  1.1 can subscribe to lag thresholds.

### 3.4 AI assistant expansion (on-device, FoundationModels)

- Text-to-SQL grounded in the live schema (`PgSchemaStore` context window
  budgeting; never send data rows, only schema + optional sampled stats the user
  approves).
- EXPLAIN narration: plain-English "why is this slow + what to try" attached to
  the visualizer.
- Error translation: Postgres error + hint → actionable explanation, offered
  inline under the error banner.
- Marketing line everywhere: *schema-aware AI, zero data egress*.

### 3.5 Extension-aware features

- **pgvector**: recognize vector columns; similarity-search playground (pick a
  row → nearest neighbors); index type/params surfaced in DDL views.
- **PostGIS**: map preview for geometry/geography columns (MapKit) — the
  spectacular screenshot for the store listing.
- Extension catalog panel: installed vs available, versions, one-tap
  install/upgrade behind Safe Apply.

Exit criteria: a working DBA can run their Monday morning entirely in pgAgent.

---

## Phase 4 — Platform polish + App Store launch (weeks 18–28)

### 4.1 App Intents + Shortcuts

- Intents: Run Health Check, Run Saved Query, Get Fleet Status, Toggle
  Read-Only Mode, Kill Blocking Query (biometric-gated).
- Enables Siri, Shortcuts automations, and system AI integration for free.

### 4.2 Continuity + iPad

- Handoff an open query tab Mac ↔ iPad ↔ iPhone (NSUserActivity with tab
  state; results re-fetched, never serialized across).
- iPad: hardware-keyboard-first audit (all editor/grid shortcuts), Stage
  Manager + external display sanity pass, pointer hover states.
- Adopt current design language (Liquid Glass on iOS 26) — early adoption is
  featuring bait; keep the Midnight design system tokens as the base.

### 4.3 System integration

- Spotlight indexing: connections, saved queries (Core Spotlight).
- Quick Look extension for `.sql` and export files.
- Files integration for exports on iOS (already partial via share sheet).
- Accessibility pass: VoiceOver on grid/monitor views, Dynamic Type on iOS,
  reduced motion. (Also an Apple Design Award criterion.)

### 4.4 App Store launch (iOS/iPadOS flagship storefront)

- **Pricing**: Free — 2 connections, full editor, manual monitoring.
  **Pro subscription** — unlimited connections, fleet monitoring + push alerts,
  AI assistant, sync. **Lifetime tier** — priced ~3× annual (subscription
  fatigue is real in this audience; our own competitor teardown says so).
  Universal purchase iPhone/iPad; Mac stays Developer ID + Sparkle for now
  (doctor's system tools are sandbox-incompatible), license bridged via the
  subscription account or a simple receipt-sharing mechanism.
- **ASO**: category Developer Tools; win "postgres", "postgresql client",
  "pgadmin alternative". Screenshots lead with iPhone lock-chain + alert flow
  (the image no competitor can produce), then PostGIS map, AI narration,
  fleet widget. Preview video = the Phase 1 on-call demo.
- **Ratings**: prompt only after a "saved the day" moment (alert resolved,
  long export finished) — never at launch, never on a crash-adjacent session.
- **Launch motion**: public TestFlight (4–6 weeks) → Product Hunt / HN
  ("a native Postgres cockpit for your iPhone, with on-device AI") → pitch
  Apple developer relations for featuring around the FoundationModels story.

Exit criteria: live on the App Store with ≥ 4.5 sustained rating in first
90 days; one Apple featuring placement pitched with assets ready.

---

## Phase 5 — Expansion (post-launch, demand-driven)

Ordered by expected pull; commit only after Phase 4 data.

- **Team features**: shared connection profiles + saved queries via CloudKit
  shared databases; audit log export for compliance. (Termius territory — enter
  only if business demand shows.)
- **Backup orchestration**: scheduled `pg_dump` via the Mac hub with retention
  + alerting on failure; restore rehearsal flows (builds on existing
  backup/restore views).
- **Sandboxed Mac App Store build**: trimmed doctor (no tcpdump), same core —
  a storefront presence play once iOS proves demand.
- **Local playground**: detect Postgres.app / homebrew Postgres, one-tap create
  scratch database; "try a migration against a copy" flow feeding schema diff.
- **Multi-DB temptation**: resist. MySQL/SQLite support dilutes the one
  defensible claim — *best Postgres tool*. Revisit only if growth stalls.

---

## Success metrics

| Metric | Target |
|---|---|
| First-run → first successful query | < 60 s (P50) |
| Alert delivery latency (Mac-hub mode) | < 15 s from detection |
| App Store rating (iOS, first 90 days) | ≥ 4.5 |
| Free → Pro conversion | ≥ 4 % at 30 days |
| Weekly-active Pro retention (12 weeks) | ≥ 70 % |
| Crash-free sessions | ≥ 99.8 % (FFI panics are app crashes — Phase 0.2 matters) |

## Dependency graph (critical path)

```
0.1 fixes ─→ 0.6 TestFlight ─→ 1.1 Mac hub + push ─→ 1.2 alert→action ─→ 4.4 launch
                    │                 │
                    │                 └→ 1.3 Live Activities
                    └→ 2.1 onboarding ─→ 2.2 editor catch-up
3.1 pg_stat_statements ←─ monitoring poller (1.1)
3.2 schema diff ←─ existing Safe Apply + DDL renderers (no Phase 1 dependency — can parallelize)
```

Phases 1 and 2 can run as parallel tracks (ops track / funnel track); Phase 3
items 3.2 and 3.5 are independent and good "slice" candidates for parallel
sessions, matching the repo's established multi-slice workflow.
