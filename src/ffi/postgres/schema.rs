// ---------------------------------------------------------------------------
// Schema contents — DataGrip-style six-category groupings.
// ---------------------------------------------------------------------------

#[derive(uniffi::Record, Debug)]
pub struct FfiPgSequence {
    pub schema: String,
    pub name: String,
    pub owner: String,
}

#[derive(uniffi::Enum, Debug)]
pub enum FfiPgRoutineKind {
    Function,
    Procedure,
    Aggregate,
    Window,
}

impl From<ssh_commander_core::RoutineKind> for FfiPgRoutineKind {
    fn from(k: ssh_commander_core::RoutineKind) -> Self {
        match k {
            ssh_commander_core::RoutineKind::Function => Self::Function,
            ssh_commander_core::RoutineKind::Procedure => Self::Procedure,
            ssh_commander_core::RoutineKind::Aggregate => Self::Aggregate,
            ssh_commander_core::RoutineKind::Window => Self::Window,
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgRoutine {
    pub schema: String,
    pub name: String,
    pub kind: FfiPgRoutineKind,
    pub owner: String,
    /// Pretty-printed `(integer, text)` argument list.
    pub argument_signature: String,
    /// `nil` for procedures.
    pub return_type: Option<String>,
}

#[derive(uniffi::Enum, Debug)]
pub enum FfiPgObjectTypeKind {
    Composite,
    Enum,
    Domain,
    Range,
}

impl From<ssh_commander_core::ObjectTypeKind> for FfiPgObjectTypeKind {
    fn from(k: ssh_commander_core::ObjectTypeKind) -> Self {
        match k {
            ssh_commander_core::ObjectTypeKind::Composite => Self::Composite,
            ssh_commander_core::ObjectTypeKind::Enum => Self::Enum,
            ssh_commander_core::ObjectTypeKind::Domain => Self::Domain,
            ssh_commander_core::ObjectTypeKind::Range => Self::Range,
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgObjectType {
    pub schema: String,
    pub name: String,
    pub kind: FfiPgObjectTypeKind,
    pub owner: String,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgSchemaContents {
    pub tables: Vec<FfiPgRelation>,
    pub views: Vec<FfiPgRelation>,
    pub materialized_views: Vec<FfiPgRelation>,
    pub sequences: Vec<FfiPgSequence>,
    pub routines: Vec<FfiPgRoutine>,
    pub object_types: Vec<FfiPgObjectType>,
}

impl From<ssh_commander_core::SchemaContents> for FfiPgSchemaContents {
    fn from(c: ssh_commander_core::SchemaContents) -> Self {
        fn map_rel(r: ssh_commander_core::Relation) -> FfiPgRelation {
            FfiPgRelation {
                schema: r.schema,
                name: r.name,
                kind: r.kind.into(),
                owner: r.owner,
                estimated_rows: r.estimated_rows,
            }
        }
        Self {
            tables: c.tables.into_iter().map(map_rel).collect(),
            views: c.views.into_iter().map(map_rel).collect(),
            materialized_views: c.materialized_views.into_iter().map(map_rel).collect(),
            sequences: c
                .sequences
                .into_iter()
                .map(|s| FfiPgSequence {
                    schema: s.schema,
                    name: s.name,
                    owner: s.owner,
                })
                .collect(),
            routines: c
                .routines
                .into_iter()
                .map(|r| FfiPgRoutine {
                    schema: r.schema,
                    name: r.name,
                    kind: r.kind.into(),
                    owner: r.owner,
                    argument_signature: r.argument_signature,
                    return_type: r.return_type,
                })
                .collect(),
            object_types: c
                .object_types
                .into_iter()
                .map(|t| FfiPgObjectType {
                    schema: t.schema,
                    name: t.name,
                    kind: t.kind.into(),
                    owner: t.owner,
                })
                .collect(),
        }
    }
}

/// Unified expand-a-schema fetch. Replaces the older
/// `rshell_pg_list_relations`-only path with a six-category result.
/// `database == nil` queries the connection's default DB.
#[uniffi::export]
pub fn rshell_pg_list_schema_contents(
    connection_id: String,
    schema: String,
    database: Option<String>,
) -> Result<FfiPgSchemaContents, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.list_schema_contents_in(&schema, database.as_deref())
                .await
        })
        .await
        .map(FfiPgSchemaContents::from)
    })
}

/// Per-column metadata for the INSERT form. Read from
/// `pg_attribute` + `pg_attrdef`. UI uses this to pre-set
/// the form's per-column toggles + skip generated columns.
#[derive(uniffi::Record, Debug)]
pub struct FfiPgColumnDetail {
    pub name: String,
    pub type_name: String,
    pub not_null: bool,
    pub has_default: bool,
    pub is_generated: bool,
}

impl From<ssh_commander_core::ColumnDetail> for FfiPgColumnDetail {
    fn from(c: ssh_commander_core::ColumnDetail) -> Self {
        Self {
            name: c.name,
            type_name: c.type_name,
            not_null: c.not_null,
            has_default: c.has_default,
            is_generated: c.is_generated,
        }
    }
}

#[uniffi::export]
pub fn rshell_pg_describe_columns(
    connection_id: String,
    schema: String,
    table: String,
) -> Result<Vec<FfiPgColumnDetail>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.describe_columns(&schema, &table).await
        })
        .await
        .map(|cols| cols.into_iter().map(FfiPgColumnDetail::from).collect())
    })
}

/// One column's worth of input for an INSERT row. Caller emits a
/// list of these for the columns it sets explicitly; columns not in
/// the list are left to the server's `DEFAULT` (sequence values,
/// generated columns, attrdef defaults).
#[derive(uniffi::Record, Debug)]
pub struct FfiPgInsertColumn {
    pub name: String,
    pub type_name: String,
    /// `None` = SQL NULL. `Some(text)` = bound + cast server-side.
    pub value: Option<String>,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgInsertedRow {
    /// Cells in the order the caller specified via `return_columns`.
    /// Matches `FfiPgRow.cells` shape so the UI can append directly.
    pub cells: Vec<Option<String>>,
}

/// Insert one row, returning the requested columns of the new row.
/// `return_columns` should typically be the visible-column names
/// from the existing result (including the magic `__pg_rowid__`)
/// so the new row slots straight into the UI's in-memory grid.
#[uniffi::export]
pub fn rshell_pg_insert_row(
    connection_id: String,
    session_id: String,
    schema: String,
    table: String,
    inputs: Vec<FfiPgInsertColumn>,
    return_columns: Vec<String>,
) -> Result<FfiPgInsertedRow, FfiPgError> {
    let bridge = MacOsBridge::global();
    let sql = build_insert_row_sql(&schema, &table, &inputs, &return_columns);
    let expects_row = !return_columns.is_empty();
    bridge.runtime.block_on(async move {
        let outcome = with_pg_pool(&connection_id, |pool| async move {
            // Page size covers the single RETURNING row; anything more
            // means the statement wasn't the INSERT we built.
            pool.execute(&session_id, &sql, 2).await
        })
        .await?;
        match outcome.rows.into_iter().next() {
            Some(cells) => Ok(FfiPgInsertedRow { cells }),
            None if !expects_row => Ok(FfiPgInsertedRow { cells: Vec::new() }),
            None => Err(FfiPgError::Other {
                detail: "INSERT reported success but returned no row".into(),
            }),
        }
    })
}

/// Delete one or more rows by ctid. Returns the actual rows-deleted
/// count; the UI compares against the requested count and surfaces
/// "some rows already gone" when they don't match.
#[uniffi::export]
pub fn rshell_pg_delete_rows(
    connection_id: String,
    session_id: String,
    schema: String,
    table: String,
    row_ids: Vec<String>,
) -> Result<FfiPgUpdateResult, FfiPgError> {
    let bridge = MacOsBridge::global();
    let Some(sql) = build_delete_rows_sql(&schema, &table, &row_ids) else {
        return Ok(FfiPgUpdateResult { rows_affected: 0 });
    };
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

/// Cancel whatever query is in flight on the session's connection.
/// Other sessions are unaffected. The connection stays open for the
/// next query in this session.
#[uniffi::export]
pub fn rshell_pg_cancel(connection_id: String, session_id: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let result: Result<(), FfiPgError> = bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.cancel(&session_id).await
        })
        .await
    });
    match result {
        Ok(()) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

/// Release a session's lease on its pooled connection. Closes any
/// active cursor first, then returns the connection to idle so other
/// sessions can use it. Best-effort — never throws to the FFI caller.
#[uniffi::export]
pub fn rshell_pg_release_session(connection_id: String, session_id: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let result: Result<(), FfiPgError> = bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.release_session(&session_id).await;
            Ok(())
        })
        .await
    });
    match result {
        Ok(()) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

#[uniffi::export]
pub fn rshell_pg_list_relations(
    connection_id: String,
    schema: String,
    database: Option<String>,
) -> Result<Vec<FfiPgRelation>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.list_relations_in(&schema, database.as_deref()).await
        })
        .await
        .map(|relations| {
            relations
                .into_iter()
                .map(|r| FfiPgRelation {
                    schema: r.schema,
                    name: r.name,
                    kind: r.kind.into(),
                    owner: r.owner,
                    estimated_rows: r.estimated_rows,
                })
                .collect()
        })
    })
}

#[cfg(test)]
mod pg_schema_tests {
    use super::*;

    #[test]
    fn pg_list_schemas_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_list_schemas("pg:nobody@nowhere:5432/none".into(), None) {
            Err(FfiPgError::NotConnected { detail }) => {
                assert!(detail.contains("postgres"));
            }
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }
}
