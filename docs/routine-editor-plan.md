# Routine Editor — Plan to Beat IntelliJ DataGrip

Status: living plan. Slice 1 shipped (PR #21). Slice 2 in progress (see "Build sequence").
Last updated: 2026-06-16.

## TL;DR

Today the routine surface (`PostgresRoutineVisualizerView`) is a **read-only viewer** —
it shows DDL in a copy-only box plus three property cards. There is no edit, apply,
run-with-parameters, or validation.

We do **not** win by matching DataGrip feature-for-feature. We win on three axes
DataGrip structurally cannot match:

1. **Native-mac speed** — instant, like Postico/TablePlus, not a JVM IDE.
2. **On-device AI grounded in the real catalog** — exact overload, attributes,
   dependents, linter output fed to the model, so it doesn't hallucinate overloads
   or dollar-quoting.
3. **A safe-apply story no one else has** — transactional dry-run + dependency
   blast-radius + ACL/`search_path` preservation, in one gesture.

The strategic wedge: **a routine editor that actually works well on managed
Postgres (RDS / Cloud SQL)**, where `pldebugger` (pgAdmin/DBeaver's debugger) is
unavailable. Our answer is inline `plpgsql_check` + a typed test runner, which need
only an extension query, not a server preload.

## Competitive landscape (summary of research)

- **DataGrip** — competent but heavy/JVM, generic-not-PG-native, modal parameter
  dialogs, submit-vs-rollback confusion, and **no PL/pgSQL debugger at all**.
- **pgAdmin 4** — most complete lifecycle; real `pldebugger` step/breakpoint/vars;
  Dependencies/Dependents tabs; live SQL preview; param dialog that *remembers
  last-used values*. But web/Electron-slow, heavyweight modal dialogs, debugger
  needs server `shared_preload_libraries` (unavailable on managed PG).
- **DBeaver** — source-first text editing, uniform "Generate DDL", debugger in the
  free tier (server-extension dependent). Eclipse-heavy/un-native; known footgun:
  Generate DDL can serve a **cached** routine definition (#11198) — always fetch live.
- **TablePlus** — fast native mac; routines as editable sidebar objects; `:variable`
  placeholder prompts for calling. No debugger, no dependency view, no guided form.
- **Postico 2 / Beekeeper** — polished/native but weakest routine editing; mostly
  view + run-CREATE-OR-REPLACE-in-a-query-tab. Beekeeper shows arg/return types
  inline in the sidebar (nice discoverability).

Ideas worth stealing: pgAdmin's **remembered parameter sets**, the **live SQL
preview**, and **Dependencies/Dependents**; TablePlus's lightweight `:variable`
prompts and native speed; DBeaver's lesson to **always fetch live DDL** (never cache).

## What we reuse (mostly assembly, not greenfield)

| Need | Existing asset |
|---|---|
| Body/DDL editor with highlighting, autocomplete, **error underline via `errorCharOffset`** | `PostgresSQLEditor` |
| Authoritative load of the **exact overload** `pg_get_functiondef` | `PostgresNodeDDL.routineQuery` / `renderRoutineDDL` (handles overloads, procedures, aggregates, C-stub) |
| The CREATE-OR-REPLACE **submit loop** (build SQL → `pgExecute` → refresh `loadSchemaContents` → surface error) | `PostgresPropertyInspectorView.executeDDL` |
| Exec-state machine + server **error-position → editor underline** | `PostgresQueryTabView` execute path + `PostgresServerError.position` |
| Form + **live DDL preview** + execute | `PostgresObjectWizardView` |
| Schema-grounded **on-device AI** (generate / explain-error), availability-gated | `PgAgentApp/AI/` (`PgAIAssistant`, `PgSchemaContextBuilder`) |
| Result grid, history, saved drafts | `PostgresResultsTable`, history/saved-query stores |

Build gaps: per-argument metadata over FFI (`proargnames`/`proargmodes`/
`proargdefaults`), structured attribute introspection (`provolatility`/`proparallel`/
`prosecdef`/`proconfig`/`proacl`), dollar-quote awareness in the highlighter, and a
dry-run/validation path.

## Tiered roadmap

### Tier 1 — Quick wins (make it a real editor)

1. **Editable body + Apply** — swap `MonospacedCodeView` for `PostgresSQLEditor`,
   seed from `PostgresNodeDDL.renderRoutineDDL` (exact overload), add an **Apply**
   that runs `CREATE OR REPLACE` via the cloned `executeDDL` loop, then reload + refresh.
2. **Server error → exact line** — wire `PostgresServerError.position` to the
   editor's `errorCharOffset`.
3. **plpgsql-aware highlighting** — extend `PostgresSQLSyntax` with the plpgsql
   keyword set (and dollar-quote delimiter awareness).
4. **Run with parameters (lightweight)** — `:variable` placeholder pattern; generate
   the correct call form (`SELECT` / `SELECT * FROM f(...)` for SETOF / `CALL` for
   procedures); render in the existing result grid.

### Tier 2 — Core upgrades (what defines the product)

5. **Structured attribute panel** — volatility / parallel / security-definer / strict
   / leakproof / cost / rows / `SET search_path` as real controls, edited as a clean
   `ALTER FUNCTION` separate from the body.
6. **Typed parameter runner with saved fixtures** — per-overload typed form
   (composite/array/enum/`DEFAULT`/`VARIADIC` builders, NULL toggles) that doubles as
   a lightweight regression harness; saves named fixtures re-run after every edit.
7. **Inline `plpgsql_check`** — auto-run `plpgsql_check_function(oid)` on save/preview;
   gutter diagnostics mapped to body lines; graceful no-op when the extension is
   absent. The managed-cloud debugger substitute.

### Tier 3 — Ambitious bets (the moat)

8. **Safe-Apply panel** — before commit, show: which path runs (`CREATE OR REPLACE`
   vs forced `DROP+CREATE`) and why; the full `pg_depend` blast radius with each
   dependent's regenerated DDL; the ACL/`search_path` that will be preserved; and the
   `BEGIN … ROLLBACK` dry-run result with mapped errors — then one explicit Commit.
9. **AI grounded in catalog truth** — feed the model the exact overload, `prolang`,
   attributes, `search_path`, dependents, and `plpgsql_check` output to explain
   errors at the right line, propose attribute fixes with rationale, and draft typed
   fixtures. Needs new (non-SELECT) prompt instructions; apply path bypasses
   `PgReadOnlyGuard` (which forbids all DDL).
10. **Security lens** — `SECURITY DEFINER` without pinned `search_path` → CRITICAL
    with one-click fix; flag untrusted-language functions and default `PUBLIC EXECUTE`.

## Correctness moat (this *is* the product)

These are where a naive editor silently corrupts a database — getting them right is
the differentiator:

- **Pin every edit to `pg_proc.oid` + identity-arg fingerprint, never the display
  name.** Build emitted `ALTER`/`DROP`/`COMMENT`/`GRANT` signatures from
  `pg_get_function_identity_arguments(oid)` verbatim; re-resolve the oid right before
  apply to detect a concurrent redefinition. (`renderRoutineDDL` already does exact
  overload matching on identity args — extend to the edit path.)
- **Never re-wrap a body you didn't unwrap.** Synthesize a collision-free dollar tag;
  treat the body as one opaque literal (injection-safe). `pg_get_functiondef` already
  picks a safe tag on load — preserve it.
- **`CREATE OR REPLACE` cannot change return type, rename input/OUT params, or change
  arg types** — those force `DROP+CREATE`, which can `CASCADE` away views, triggers,
  policies, generated columns. Detect the path, show the blast radius via `pg_depend`,
  preserve `proacl` + `proconfig` across recreate.
- **Error-line mapping is three coordinate systems** (editor lines, submitted DDL,
  server "line N from body"). In Slice 1 we submit the editor text verbatim, so the
  syntax-error position maps directly (`position - 1`); runtime CONTEXT mapping is a
  later slice.
- **One pinned session for edit → dry-run → apply** with a true `BEGIN … ROLLBACK`
  dry-run and an auto-rollback timeout (Tier 3).
- **C/internal functions have no editable SQL body** (`prosrc` is a symbol;
  `pg_get_functiondef` raises) — read-only with the symbol shown. Aggregates render as
  `CREATE AGGREGATE`. The editor flags these as not plainly re-appliable.

## Headline differentiators (feature-page lines)

- "Edit, dry-run, and **see the blast radius before you commit** — in one transaction."
- "A **routine debugger that works on RDS**" — inline `plpgsql_check` + typed test runner.
- "AI that **knows your exact overload**, not a guess."
- "**Native-mac fast** — no JVM, no modal dialogs."

## Build sequence

1. **Slice 1** — editable body + Apply + error-line underline + plpgsql highlighting.
   Repoint `TabKind.routine` from the viewer to a new `PostgresRoutineEditorView`.
2. **Slice 2** — typed parameter runner + saved fixtures.
3. **Slice 3** — structured attribute panel + security lens.
4. **Slice 4** — inline `plpgsql_check`.
5. **Slice 5** — Safe-Apply panel (the moat).
6. **Slice 6** — AI grounding.
