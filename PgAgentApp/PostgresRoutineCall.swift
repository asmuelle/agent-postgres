import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresRoutineCall — pure introspection + invocation building for the
// routine runner (Slice 2). Kept free of UI/FFI so it's unit-testable.
//
//   - `introspectionQuery` asks the catalog for the exact overload's INPUT
//     parameters (name, type, mode, has-default) plus prokind / set-returning.
//   - `parseParams` turns those rows into a `RoutineCallInfo`.
//   - `buildInvocation` assembles a correct, type-aware call:
//       * procedures      → CALL schema.name(args)
//       * functions       → SELECT * FROM schema.name(args)   (works for
//         scalar, composite, OUT-param and SETOF/TABLE returns alike)
//     using named `name => value::type` notation when every input parameter
//     is named and none is VARIADIC, else positional (with `VARIADIC` for the
//     variadic tail and trailing-default omission).
//
// Only INPUT-ish params are prompted (modes i / b / v); pure OUT and TABLE
// columns come back as result columns, not inputs.
// =============================================================================

/// One input parameter of a routine overload.
struct RoutineParam: Identifiable, Equatable, Sendable {
    /// 1-based position among the *input* parameters (stable key for values
    /// and the `$n` label of an unnamed argument).
    let ordinal: Int
    /// Declared name, or "" when the argument is unnamed.
    let name: String
    /// `format_type` spelling, e.g. `integer`, `character varying`,
    /// `integer[]`, `myschema.mytype`. "" when unknown.
    let type: String
    /// pg_proc arg mode: `i` (in), `b` (inout), `v` (variadic).
    let mode: String
    /// `true` when the routine declares a DEFAULT for this argument, so the
    /// runner can offer to omit it.
    let hasDefault: Bool

    var id: Int { ordinal }
    var label: String { name.isEmpty ? "$\(ordinal)" : name }
    var isVariadic: Bool { mode == "v" }
}

/// What the runner needs to build a call: the input parameters plus how to
/// invoke (CALL vs SELECT).
struct RoutineCallInfo: Equatable, Sendable {
    let isProcedure: Bool
    let returnsSet: Bool
    let params: [RoutineParam]
}

/// Per-parameter form state. `isNull` and `useDefault` are mutually exclusive;
/// both off means "send the typed value".
struct RoutineParamValue: Equatable, Sendable {
    var text: String = ""
    var isNull: Bool = false
    var useDefault: Bool = false
}

enum PostgresRoutineCall {

    // MARK: - Introspection

    /// Catalog query for the exact overload identified by `signature`
    /// (`pg_get_function_identity_arguments`, exactly what the routine tab
    /// carries). Returns one row per argument (ordered), or a single
    /// arg-less row for a zero-arg routine; every row repeats prokind /
    /// proretset so they're available even with no arguments.
    /// Columns: 0 prokind, 1 retset, 2 arg_name, 3 arg_type, 4 arg_mode, 5 has_default.
    static func introspectionQuery(schema: String, name: String, signature: String) -> String {
        """
        WITH t AS (
          SELECT p.oid, p.prokind::text AS prokind, p.proretset, p.pronargdefaults,
                 p.proargnames, p.proargmodes,
                 COALESCE(p.proallargtypes, p.proargtypes::oid[]) AS argtypes
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = \(pgQuoteLiteral(schema))
            AND p.proname = \(pgQuoteLiteral(name))
            AND pg_get_function_identity_arguments(p.oid) = \(pgQuoteLiteral(signature))
          LIMIT 1
        ),
        a AS (
          SELECT t.prokind, t.proretset, t.pronargdefaults, u.ord,
                 t.proargnames[u.ord] AS arg_name,
                 CASE WHEN u.type_oid IS NULL THEN NULL
                      ELSE pg_catalog.format_type(u.type_oid, NULL) END AS arg_type,
                 COALESCE(t.proargmodes[u.ord]::text, 'i') AS arg_mode
          FROM t
          LEFT JOIN LATERAL unnest(t.argtypes) WITH ORDINALITY AS u(type_oid, ord) ON true
        ),
        inp AS (
          SELECT *,
            row_number() OVER (
              PARTITION BY (arg_type IS NOT NULL AND arg_mode IN ('i','b','v'))
              ORDER BY ord) AS in_pos,
            sum(CASE WHEN arg_type IS NOT NULL AND arg_mode IN ('i','b','v')
                     THEN 1 ELSE 0 END) OVER () AS in_count
          FROM a
        )
        SELECT prokind, proretset::text, arg_name, arg_type, arg_mode,
          CASE WHEN arg_type IS NOT NULL AND arg_mode IN ('i','b','v')
                    AND in_pos > in_count - pronargdefaults
               THEN 'true' ELSE 'false' END AS has_default
        FROM inp
        ORDER BY ord NULLS FIRST;
        """
    }

    /// Parse introspection rows into a `RoutineCallInfo`, or `nil` when the
    /// overload wasn't found (no rows).
    static func parseParams(rows: [[String?]]) -> RoutineCallInfo? {
        guard let first = rows.first else { return nil }
        func cell(_ row: [String?], _ i: Int) -> String? { i < row.count ? row[i] : nil }
        let isProcedure = cell(first, 0) == "p"
        let returnsSet = cell(first, 1) == "true"

        var params: [RoutineParam] = []
        var ordinal = 0
        for row in rows {
            guard let type = cell(row, 3), !type.isEmpty else { continue } // arg-less row
            let mode = cell(row, 4) ?? "i"
            guard mode == "i" || mode == "b" || mode == "v" else { continue } // skip OUT / TABLE
            ordinal += 1
            params.append(RoutineParam(
                ordinal: ordinal,
                name: cell(row, 2) ?? "",
                type: type,
                mode: mode,
                hasDefault: cell(row, 5) == "true"
            ))
        }
        return RoutineCallInfo(isProcedure: isProcedure, returnsSet: returnsSet, params: params)
    }

    // MARK: - Invocation building

    /// Build the call statement. `values` is keyed by `RoutineParam.ordinal`;
    /// missing entries default to an empty (non-null, non-default) value.
    static func buildInvocation(
        schema: String,
        name: String,
        info: RoutineCallInfo,
        values: [Int: RoutineParamValue]
    ) -> String {
        let qualified = "\(pgQuoteIdent(schema)).\(pgQuoteIdent(name))"
        let argList = buildArgList(info: info, values: values)
        let verb = info.isProcedure ? "CALL \(qualified)" : "SELECT * FROM \(qualified)"
        return "\(verb)(\(argList));"
    }

    /// The comma-joined argument fragments (no surrounding parens).
    private static func buildArgList(
        info: RoutineCallInfo, values: [Int: RoutineParamValue]
    ) -> String {
        let params = info.params
        guard !params.isEmpty else { return "" }

        let allNamed = params.allSatisfy { !$0.name.isEmpty }
        let hasVariadic = params.contains { $0.isVariadic }
        let useNamed = allNamed && !hasVariadic

        if useNamed {
            // Named notation: omit any param the user set to DEFAULT; order is
            // irrelevant, so this cleanly handles middle defaults too.
            return params.compactMap { p -> String? in
                let v = values[p.ordinal] ?? RoutineParamValue()
                if v.useDefault && p.hasDefault { return nil }
                return "\(pgQuoteIdent(p.name)) => \(valueExpr(v, type: p.type))"
            }.joined(separator: ", ")
        }

        // Positional: can only omit a contiguous trailing run of defaulted args.
        var lastIncluded = params.count - 1
        while lastIncluded >= 0 {
            let p = params[lastIncluded]
            let v = values[p.ordinal] ?? RoutineParamValue()
            if v.useDefault && p.hasDefault { lastIncluded -= 1 } else { break }
        }
        guard lastIncluded >= 0 else { return "" }
        return params[0...lastIncluded].map { p -> String in
            let v = values[p.ordinal] ?? RoutineParamValue()
            let expr = valueExpr(v, type: p.type)
            // Calling a variadic function with an explicit array needs the
            // VARIADIC keyword; the value is the array (e.g. '{1,2}'::int[]).
            return p.isVariadic ? "VARIADIC \(expr)" : expr
        }.joined(separator: ", ")
    }

    /// A single argument's SQL expression: `NULL`, or a quoted literal cast to
    /// the declared type (skipping the cast for pseudo-types that can't be cast).
    static func valueExpr(_ value: RoutineParamValue, type: String) -> String {
        if value.isNull { return "NULL" }
        let literal = pgQuoteLiteral(value.text)
        return literal + castSuffix(for: type)
    }

    /// `::type`, or "" for unknown / pseudo types where an explicit cast is
    /// illegal or meaningless.
    static func castSuffix(for type: String) -> String {
        let t = type.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || pseudoTypes.contains(t) { return "" }
        return "::\(type)"
    }

    private static let pseudoTypes: Set<String> = [
        "any", "anyarray", "anyelement", "anyenum", "anynonarray", "anyrange",
        "anymultirange", "anycompatible", "anycompatiblearray",
        "anycompatiblenonarray", "anycompatiblerange", "anycompatiblemultirange",
        "cstring", "internal", "language_handler", "fdw_handler",
        "table_am_handler", "index_am_handler", "tsm_handler", "record",
        "trigger", "event_trigger", "pg_ddl_command", "void", "unknown",
    ]
}
