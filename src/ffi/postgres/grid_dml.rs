// ---------------------------------------------------------------------------
// Grid DML — UPDATE / INSERT / DELETE built as SQL text.
//
// ssh-commander-core 0.1.0's editor API (`update_cell` / `insert_row` /
// `delete_rows`) binds every parameter as `String` while writing
// `$N::<type>` placeholders. Postgres infers the parameter to BE that
// type, so tokio-postgres fails to serialize the text for any non-text
// target — including the `tid` ctid every statement keys on, which
// breaks all three calls unconditionally ("error serializing parameter").
// Until a fixed core ships, these functions render the statement as SQL
// text (quoted identifiers, safely-quoted literals, explicit casts) and
// run it through the same `pool.execute` path query tabs use.
// ---------------------------------------------------------------------------

/// Magic alias the generated browse SELECT gives `ctid`; mirrored by
/// `POSTGRES_ROWID_COLUMN` on the Swift side.
const PG_ROWID_COLUMN: &str = "__pg_rowid__";

/// Quote an identifier for direct embedding in SQL text.
fn pg_quote_ident(s: &str) -> String {
    format!("\"{}\"", s.replace('"', "\"\""))
}

/// Quote a text value as a SQL string literal. Values containing a
/// backslash are emitted as an `E''` string with backslashes doubled,
/// which is correct regardless of the server's
/// `standard_conforming_strings` setting; plain values use `''`
/// doubling only.
fn pg_quote_literal(s: &str) -> String {
    if s.contains('\\') {
        format!("E'{}'", s.replace('\\', "\\\\").replace('\'', "''"))
    } else {
        format!("'{}'", s.replace('\'', "''"))
    }
}

/// Resolve a CAST target type name to something Postgres will actually
/// accept when quoted as an identifier.
///
/// Callers pass two different flavors of type name through here:
/// - The UPDATE-cell path uses short catalog `typname`s (`int4`,
///   `varchar`, `timestamptz`, `mood`, `uuid`, ...) — these are valid
///   quoted identifiers already and must pass through unchanged.
/// - The INSERT-row path uses `describe_columns`, which reports
///   Postgres `format_type()` *display* names (`integer`, `boolean`,
///   `character varying(255)`, `timestamp without time zone`, ...).
///   Quoting those verbatim as an identifier produces a type that
///   doesn't exist (`type "integer" does not exist`), so they need to
///   be mapped back to their short catalog form first.
fn pg_cast_type(type_name: &str) -> String {
    let trimmed = type_name.trim();

    // Peel off (possibly repeated) array suffixes, resolve the base,
    // then re-append them — `"int4"[]` is valid cast syntax.
    let mut base = trimmed;
    let mut array_suffix = String::new();
    while let Some(stripped) = base.strip_suffix("[]") {
        base = stripped.trim_end();
        array_suffix.push_str("[]");
    }

    // Drop a trailing parenthesized modifier — `character varying(255)`
    // → `character varying`, `numeric(10,2)` → `numeric`. An assignment
    // cast on INSERT re-applies the column's real modifier, so dropping
    // it here is safe.
    let base = match base.find('(') {
        Some(idx) if base.ends_with(')') => base[..idx].trim_end(),
        _ => base,
    };

    let lower = base.to_ascii_lowercase();
    let mapped = match lower.as_str() {
        "integer" | "int" => Some("int4"),
        "bigint" => Some("int8"),
        "smallint" => Some("int2"),
        "boolean" => Some("bool"),
        "real" => Some("float4"),
        "double precision" => Some("float8"),
        "character varying" => Some("varchar"),
        "character" => Some("bpchar"),
        "bit varying" => Some("varbit"),
        "timestamp without time zone" => Some("timestamp"),
        "timestamp with time zone" => Some("timestamptz"),
        "time without time zone" => Some("time"),
        "time with time zone" => Some("timetz"),
        "decimal" => Some("numeric"),
        "\"char\"" => Some("char"),
        _ => None,
    };

    let resolved: &str = match mapped {
        Some(short) => short,
        // format_type() wraps mixed-case/custom type names in double
        // quotes (e.g. `"MyType"`) — unwrap before re-quoting, or the
        // old code doubled up to `"""MyType"""`.
        None => base
            .strip_prefix('"')
            .and_then(|s| s.strip_suffix('"'))
            .unwrap_or(base),
    };

    format!("{}{}", pg_quote_ident(resolved), array_suffix)
}

/// Render an optional cell value as a SQL expression: `NULL`, a cast
/// literal when the column type is known, or a bare (untyped) literal
/// otherwise — Postgres coerces an unknown literal to the target
/// column's type on its own.
fn pg_value_expr(value: Option<&str>, type_name: &str) -> String {
    match value {
        None => "NULL".to_string(),
        Some(v) if type_name.is_empty() => pg_quote_literal(v),
        Some(v) => format!(
            "CAST({} AS {})",
            pg_quote_literal(v),
            pg_cast_type(type_name)
        ),
    }
}

fn build_update_cell_sql(
    schema: &str,
    table: &str,
    column: &str,
    column_type: &str,
    new_value: Option<&str>,
    row_id: &str,
) -> String {
    format!(
        "UPDATE {}.{} SET {} = {} WHERE ctid = {}::tid",
        pg_quote_ident(schema),
        pg_quote_ident(table),
        pg_quote_ident(column),
        pg_value_expr(new_value, column_type),
        pg_quote_literal(row_id),
    )
}

/// One RETURNING entry: the magic rowid alias maps back to `ctid`
/// (as text, matching the browse SELECT's shape); everything else is
/// the quoted column itself.
fn pg_returning_expr(name: &str) -> String {
    if name == PG_ROWID_COLUMN {
        format!("ctid::text AS {}", pg_quote_ident(PG_ROWID_COLUMN))
    } else {
        pg_quote_ident(name)
    }
}

fn build_insert_row_sql(
    schema: &str,
    table: &str,
    inputs: &[FfiPgInsertColumn],
    return_columns: &[String],
) -> String {
    let target = format!("{}.{}", pg_quote_ident(schema), pg_quote_ident(table));
    let body = if inputs.is_empty() {
        format!("INSERT INTO {target} DEFAULT VALUES")
    } else {
        let columns: Vec<String> = inputs.iter().map(|c| pg_quote_ident(&c.name)).collect();
        let values: Vec<String> = inputs
            .iter()
            .map(|c| pg_value_expr(c.value.as_deref(), &c.type_name))
            .collect();
        format!(
            "INSERT INTO {target} ({}) VALUES ({})",
            columns.join(", "),
            values.join(", ")
        )
    };
    if return_columns.is_empty() {
        body
    } else {
        let returning: Vec<String> = return_columns
            .iter()
            .map(|c| pg_returning_expr(c))
            .collect();
        // The trailing `; --` suffix is load-bearing: core 0.1.0's
        // execute path cursor-wraps any statement whose prepared form
        // has result columns, and `DECLARE … CURSOR FOR INSERT` is a
        // syntax error. A semicolon followed by only a comment makes
        // core's `is_multi_statement` true while its statement
        // splitter bails (comment-only main), routing the whole
        // statement through the simple_query bulk path — which
        // executes INSERT … RETURNING correctly and surfaces its
        // rows. Pinned by the grid-DML integration test.
        format!(
            "{body} RETURNING {}; -- simple_query route",
            returning.join(", ")
        )
    }
}

/// `None` when `row_ids` is empty — there is nothing to delete and
/// `WHERE ctid IN ()` would be a syntax error.
fn build_delete_rows_sql(schema: &str, table: &str, row_ids: &[String]) -> Option<String> {
    if row_ids.is_empty() {
        return None;
    }
    let ids: Vec<String> = row_ids
        .iter()
        .map(|id| format!("{}::tid", pg_quote_literal(id)))
        .collect();
    Some(format!(
        "DELETE FROM {}.{} WHERE ctid IN ({})",
        pg_quote_ident(schema),
        pg_quote_ident(table),
        ids.join(", ")
    ))
}

/// Update a single cell. `new_value: None` means SET NULL; a non-null
/// value is rendered as a quoted literal with an explicit cast to
/// `column_type`. Identifiers are quoted here — callers don't need to
/// escape `schema` / `table` / `column`.
// Flat argument lists are idiomatic for the UniFFI surface; bundling these
// into a record would force a binding regen + every Swift call site to change
// for no real readability gain, so the lint is allowed here deliberately.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn rshell_pg_update_cell(
    connection_id: String,
    session_id: String,
    schema: String,
    table: String,
    column: String,
    column_type: String,
    new_value: Option<String>,
    row_id: String,
) -> Result<FfiPgUpdateResult, FfiPgError> {
    let bridge = MacOsBridge::global();
    let sql = build_update_cell_sql(
        &schema,
        &table,
        &column,
        &column_type,
        new_value.as_deref(),
        &row_id,
    );
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.execute(&session_id, &sql, 1).await
        })
        .await
        .map(|outcome| FfiPgUpdateResult {
            rows_affected: outcome.rows_affected.unwrap_or(0),
        })
    })
}

/// Open a Parquet writer at `path` with the given column names.
/// All columns serialize as Utf8 (matches the explorer's text-only
/// model). Returns an opaque writer id; pass it to subsequent
/// `rshell_pg_parquet_append` calls and finally `rshell_pg_parquet_close`.
#[uniffi::export]
pub fn rshell_pg_parquet_open(path: String, columns: Vec<String>) -> Result<u64, FfiPgError> {
    ssh_commander_pg_parquet::ParquetRegistry::global()
        .open(std::path::Path::new(&path), &columns)
        .map_err(|e| FfiPgError::Other {
            detail: format!("parquet open failed: {e}"),
        })
}

/// Append a batch of rows to an open Parquet writer. `rows` is a
/// list of `FfiPgRow`; each row's `cells` must match the column
/// list passed to `rshell_pg_parquet_open` in length.
#[uniffi::export]
pub fn rshell_pg_parquet_append(writer_id: u64, rows: Vec<FfiPgRow>) -> Result<(), FfiPgError> {
    let row_vecs: Vec<Vec<Option<String>>> = rows.into_iter().map(|r| r.cells).collect();
    ssh_commander_pg_parquet::ParquetRegistry::global()
        .append(writer_id, &row_vecs)
        .map_err(|e| FfiPgError::Other {
            detail: format!("parquet append failed: {e}"),
        })
}

/// Close a Parquet writer. Flushes the metadata footer to disk;
/// the file isn't readable as Parquet until this returns. Idempotent
/// against the same id (subsequent calls return UnknownWriter; the
/// caller surfaces that as a no-op since the file is already valid).
#[uniffi::export]
pub fn rshell_pg_parquet_close(writer_id: u64) -> Result<(), FfiPgError> {
    ssh_commander_pg_parquet::ParquetRegistry::global()
        .close(writer_id)
        .map_err(|e| FfiPgError::Other {
            detail: format!("parquet close failed: {e}"),
        })
}

#[cfg(test)]
mod grid_dml_tests {
    use super::*;

    #[test]
    fn pg_quote_literal_escapes_quotes_and_backslashes() {
        assert_eq!(pg_quote_literal("plain"), "'plain'");
        assert_eq!(pg_quote_literal("it's"), "'it''s'");
        // Backslash forces the E-string form, safe under either
        // standard_conforming_strings setting.
        assert_eq!(pg_quote_literal("a\\b"), "E'a\\\\b'");
        assert_eq!(pg_quote_literal("a\\'b"), "E'a\\\\''b'");
    }

    #[test]
    fn pg_value_expr_renders_null_cast_and_bare_literal() {
        assert_eq!(pg_value_expr(None, "int4"), "NULL");
        assert_eq!(pg_value_expr(Some("5"), "int4"), "CAST('5' AS \"int4\")");
        // Unknown type: bare literal, server coerces to the column type.
        assert_eq!(pg_value_expr(Some("x"), ""), "'x'");
    }

    #[test]
    fn pg_cast_type_maps_format_type_display_names_to_catalog_typnames() {
        assert_eq!(pg_cast_type("integer"), "\"int4\"");
        assert_eq!(pg_cast_type("boolean"), "\"bool\"");
        assert_eq!(pg_cast_type("bigint"), "\"int8\"");
        assert_eq!(pg_cast_type("double precision"), "\"float8\"");
        assert_eq!(pg_cast_type("character varying(255)"), "\"varchar\"");
        assert_eq!(pg_cast_type("numeric(10,2)"), "\"numeric\"");
        assert_eq!(pg_cast_type("timestamp without time zone"), "\"timestamp\"");
    }

    #[test]
    fn pg_cast_type_passes_short_catalog_typnames_through_unchanged() {
        // The UPDATE-cell path already supplies short typnames; these
        // must keep working exactly as before.
        assert_eq!(pg_cast_type("timestamptz"), "\"timestamptz\"");
        assert_eq!(pg_cast_type("int4"), "\"int4\"");
        assert_eq!(pg_cast_type("text"), "\"text\"");
        assert_eq!(pg_cast_type("mood"), "\"mood\"");
    }

    #[test]
    fn pg_cast_type_handles_arrays_and_quoted_custom_types() {
        assert_eq!(pg_cast_type("integer[]"), "\"int4\"[]");
        // format_type() wraps mixed-case/custom types in double quotes;
        // unwrap before re-quoting instead of doubling the quotes.
        assert_eq!(pg_cast_type("\"MyType\""), "\"MyType\"");
    }

    #[test]
    fn build_insert_row_sql_casts_display_name_type_to_catalog_typname() {
        let inputs = vec![FfiPgInsertColumn {
            name: "age".into(),
            type_name: "integer".into(),
            value: Some("42".into()),
        }];
        let sql = build_insert_row_sql("public", "t", &inputs, &[]);
        assert!(
            sql.contains("AS \"int4\""),
            "expected cast to short typname, got: {sql}"
        );
    }

    #[test]
    fn build_update_cell_sql_casts_value_and_keys_on_ctid() {
        assert_eq!(
            build_update_cell_sql("public", "users", "age", "int4", Some("42"), "(0,1)"),
            "UPDATE \"public\".\"users\" SET \"age\" = CAST('42' AS \"int4\") \
             WHERE ctid = '(0,1)'::tid"
        );
        assert_eq!(
            build_update_cell_sql("s", "t", "c", "text", None, "(0,2)"),
            "UPDATE \"s\".\"t\" SET \"c\" = NULL WHERE ctid = '(0,2)'::tid"
        );
        // Hostile identifiers stay inert.
        assert_eq!(
            build_update_cell_sql("pu\"blic", "t", "c", "text", Some("v"), "(0,3)"),
            "UPDATE \"pu\"\"blic\".\"t\" SET \"c\" = CAST('v' AS \"text\") \
             WHERE ctid = '(0,3)'::tid"
        );
    }

    #[test]
    fn build_insert_row_sql_handles_values_defaults_and_rowid_alias() {
        let inputs = vec![
            FfiPgInsertColumn {
                name: "id".into(),
                type_name: "int4".into(),
                value: Some("7".into()),
            },
            FfiPgInsertColumn {
                name: "label".into(),
                type_name: "text".into(),
                value: None,
            },
        ];
        assert_eq!(
            build_insert_row_sql(
                "public",
                "t",
                &inputs,
                &["id".into(), "__pg_rowid__".into()]
            ),
            "INSERT INTO \"public\".\"t\" (\"id\", \"label\") \
             VALUES (CAST('7' AS \"int4\"), NULL) \
             RETURNING \"id\", ctid::text AS \"__pg_rowid__\"; -- simple_query route"
        );
        // No explicit inputs → all server defaults.
        assert_eq!(
            build_insert_row_sql("s", "t", &[], &["id".into()]),
            "INSERT INTO \"s\".\"t\" DEFAULT VALUES RETURNING \"id\"; -- simple_query route"
        );
        // No RETURNING list at all.
        assert_eq!(
            build_insert_row_sql("s", "t", &[], &[]),
            "INSERT INTO \"s\".\"t\" DEFAULT VALUES"
        );
    }

    #[test]
    fn build_delete_rows_sql_lists_ctids_and_rejects_empty() {
        assert_eq!(
            build_delete_rows_sql("s", "t", &["(0,1)".into(), "(0,2)".into()]),
            Some("DELETE FROM \"s\".\"t\" WHERE ctid IN ('(0,1)'::tid, '(0,2)'::tid)".to_string())
        );
        assert_eq!(build_delete_rows_sql("s", "t", &[]), None);
    }

    #[test]
    fn pg_update_cell_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_update_cell(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "public".into(),
            "users".into(),
            "name".into(),
            "text".into(),
            Some("alice".into()),
            "(0,1)".into(),
        ) {
            Err(FfiPgError::NotConnected { .. }) => {}
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_insert_row_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_insert_row(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "public".into(),
            "users".into(),
            vec![FfiPgInsertColumn {
                name: "name".into(),
                type_name: "text".into(),
                value: Some("alice".into()),
            }],
            vec!["__pg_rowid__".into(), "name".into()],
        ) {
            Err(FfiPgError::NotConnected { .. }) => {}
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_delete_rows_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_delete_rows(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "public".into(),
            "users".into(),
            vec!["(0,1)".into()],
        ) {
            Err(FfiPgError::NotConnected { .. }) => {}
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    // Grid DML through the SQL-text path. Historically this test pinned the
    // opposite behavior: ssh-commander-core 0.1.0's editor API binds every
    // parameter as `String` against `$N::<type>` placeholders, which fails to
    // serialize for any non-text target — including the `tid` ctid — so
    // update_cell / insert_row / delete_rows were broken unconditionally. The
    // FFI now renders those statements as SQL text instead of calling core,
    // and this test requires the full edit cycle to succeed, non-text columns
    // included.
    #[test]
    fn pg_it_grid_dml_roundtrip_by_ctid() {
        let Some(cfg) = it_config("it-grid-dml") else {
            return;
        };
        rshell_init();
        let conn = rshell_pg_connect(cfg).expect("connect to live postgres");
        let sid = "it-grid-dml".to_string();

        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "DROP TABLE IF EXISTS pg_agent_it_grid".into(),
            1,
        )
        .expect("drop");
        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "CREATE TABLE pg_agent_it_grid (id int, label text, \"weird \"\"col\" int)".into(),
            1,
        )
        .expect("create");
        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "INSERT INTO pg_agent_it_grid VALUES (1, 'orig', 10)".into(),
            1,
        )
        .expect("insert seed");
        let ctid_of = |conn: &str, sid: &str| -> String {
            rshell_pg_execute(
                conn.to_string(),
                sid.to_string(),
                "SELECT ctid::text FROM pg_agent_it_grid WHERE id = 1".into(),
                1,
            )
            .expect("select ctid")
            .rows[0]
                .cells[0]
                .clone()
                .expect("ctid")
        };

        // Text column — exercises the literal path plus the ctid key.
        let upd = rshell_pg_update_cell(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            "label".into(),
            "text".into(),
            Some("it's \\edited".into()),
            ctid_of(&conn, &sid),
        )
        .expect("update text cell");
        assert_eq!(upd.rows_affected, 1);
        let sel = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "SELECT label FROM pg_agent_it_grid WHERE id = 1".into(),
            1,
        )
        .expect("verify text");
        assert_eq!(
            sel.rows[0].cells[0].as_deref(),
            Some("it's \\edited"),
            "quote/backslash escaping must round-trip"
        );

        // Non-text column with a quoted identifier — the case the old
        // core path could never serialize. ctid moves on UPDATE, so
        // re-read it.
        let upd = rshell_pg_update_cell(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            "weird \"col".into(),
            "int4".into(),
            Some("42".into()),
            ctid_of(&conn, &sid),
        )
        .expect("update int cell");
        assert_eq!(upd.rows_affected, 1);

        // SET NULL.
        let upd = rshell_pg_update_cell(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            "label".into(),
            "text".into(),
            None,
            ctid_of(&conn, &sid),
        )
        .expect("update to NULL");
        assert_eq!(upd.rows_affected, 1);

        let sel = rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "SELECT label, \"weird \"\"col\" FROM pg_agent_it_grid WHERE id = 1".into(),
            1,
        )
        .expect("verify");
        assert_eq!(sel.rows[0].cells[0], None, "label should be NULL");
        assert_eq!(sel.rows[0].cells[1].as_deref(), Some("42"));

        // INSERT with typed values + RETURNING, including the rowid alias.
        let inserted = rshell_pg_insert_row(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            vec![
                FfiPgInsertColumn {
                    name: "id".into(),
                    type_name: "int4".into(),
                    value: Some("2".into()),
                },
                FfiPgInsertColumn {
                    name: "label".into(),
                    type_name: "text".into(),
                    value: None,
                },
            ],
            vec!["id".into(), "label".into(), "__pg_rowid__".into()],
        )
        .expect("insert row");
        assert_eq!(inserted.cells[0].as_deref(), Some("2"));
        assert_eq!(inserted.cells[1], None);
        let new_ctid = inserted.cells[2].clone().expect("returned ctid");

        // DELETE by the returned ctid; a stale id deletes nothing.
        let del = rshell_pg_delete_rows(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            vec![new_ctid.clone()],
        )
        .expect("delete row");
        assert_eq!(del.rows_affected, 1);
        let del = rshell_pg_delete_rows(
            conn.clone(),
            sid.clone(),
            "public".into(),
            "pg_agent_it_grid".into(),
            vec![new_ctid],
        )
        .expect("delete stale ctid");
        assert_eq!(del.rows_affected, 0, "stale ctid should match nothing");

        rshell_pg_execute(
            conn.clone(),
            sid.clone(),
            "DROP TABLE IF EXISTS pg_agent_it_grid".into(),
            1,
        )
        .expect("drop teardown");
        let _ = rshell_pg_release_session(conn.clone(), sid);
        let _ = rshell_pg_disconnect(conn);
    }
}
