---
version: alpha
name: Midnight SSH
description: Native macOS and iPadOS SSH workspace design system for dense operational tools.
colors:
  primary: "#0B0F14"
  fallback-secondary: "#4B5563"
  fallback-accent: "#0066CC"
  fallback-window: "#F5F7FA"
  fallback-surface: "#FFFFFF"
  fallback-surface-subtle: "#F2F4F8"
  fallback-surface-elevated: "#FFFFFF"
  fallback-sidebar-tint-top: "#D4DEF5"
  fallback-sidebar-tint-bottom: "#E6EDFA"
  fallback-terminal-background: "#111111"
  fallback-terminal-foreground: "#EAEAEA"
  fallback-terminal-caret: "#EAEAEA"
  fallback-separator: "#D1D5DB"
  fallback-success: "#1F7A3D"
  fallback-warning: "#FFCC00"
  fallback-danger: "#C62828"
  fallback-info: "#0066CC"
  fallback-on-accent: "#FFFFFF"
  fallback-on-surface: "#111827"
  fallback-on-status: "#FFFFFF"
typography:
  macos-title:
    fontFamily: SF Pro Display
    fontSize: 17px
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: 0em
  macos-headline:
    fontFamily: SF Pro Text
    fontSize: 13px
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: 0em
  macos-body:
    fontFamily: SF Pro Text
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: 0em
  macos-callout:
    fontFamily: SF Pro Text
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: 0em
  macos-subheadline:
    fontFamily: SF Pro Text
    fontSize: 11px
    fontWeight: 400
    lineHeight: 1.3
    letterSpacing: 0em
  macos-caption:
    fontFamily: SF Pro Text
    fontSize: 10px
    fontWeight: 400
    lineHeight: 1.3
    letterSpacing: 0em
  ipados-title:
    fontFamily: SF Pro Display
    fontSize: 22px
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: 0em
  ipados-body:
    fontFamily: SF Pro Text
    fontSize: 17px
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: 0em
  ipados-subheadline:
    fontFamily: SF Pro Text
    fontSize: 15px
    fontWeight: 400
    lineHeight: 1.3
    letterSpacing: 0em
  ipados-caption:
    fontFamily: SF Pro Text
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.25
    letterSpacing: 0em
  terminal-body:
    fontFamily: SF Mono
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: 0em
  data-caption:
    fontFamily: SF Mono
    fontSize: 11px
    fontWeight: 400
    lineHeight: 1.25
    letterSpacing: 0em
rounded:
  none: 0px
  xxs: 2px
  xs: 4px
  sm: 6px
  md: 8px
  lg: 12px
  overlay: 16px
  full: 9999px
spacing:
  xxs: 2px
  xs: 4px
  sm: 6px
  md: 8px
  lg: 12px
  xl: 16px
  xxl: 24px
  toolbar-height: 32px
  sidebar-padding: 12px
  panel-padding: 12px
  inspector-width-default: 320px
  sidebar-width-default: 240px
components:
  button-primary:
    backgroundColor: "{colors.fallback-accent}"
    textColor: "{colors.fallback-on-accent}"
    typography: "{typography.macos-body}"
    rounded: "{rounded.sm}"
    padding: 8px
  button-plain:
    backgroundColor: "{colors.fallback-surface}"
    textColor: "{colors.fallback-on-surface}"
    typography: "{typography.macos-callout}"
    rounded: "{rounded.xs}"
    padding: 6px
  workspace-background:
    backgroundColor: "{colors.fallback-window}"
    textColor: "{colors.fallback-on-surface}"
    typography: "{typography.macos-body}"
  divider:
    backgroundColor: "{colors.fallback-separator}"
    height: 1px
  sidebar-material:
    backgroundColor: "{colors.fallback-surface-subtle}"
    textColor: "{colors.fallback-on-surface}"
  sidebar-tint-top:
    backgroundColor: "{colors.fallback-sidebar-tint-top}"
    textColor: "{colors.primary}"
  sidebar-tint-bottom:
    backgroundColor: "{colors.fallback-sidebar-tint-bottom}"
    textColor: "{colors.primary}"
  sidebar-search:
    backgroundColor: "{colors.fallback-surface-subtle}"
    textColor: "{colors.fallback-on-surface}"
    typography: "{typography.macos-callout}"
    rounded: "{rounded.sm}"
    padding: 8px
  workspace-tab-strip:
    backgroundColor: "{colors.fallback-surface-subtle}"
    textColor: "{colors.fallback-on-surface}"
    typography: "{typography.macos-subheadline}"
    height: "{spacing.toolbar-height}"
  workspace-tab-active:
    backgroundColor: "{colors.fallback-info}"
    textColor: "{colors.fallback-on-accent}"
    typography: "{typography.macos-subheadline}"
    rounded: "{rounded.xs}"
    padding: 6px
  terminal-pane:
    backgroundColor: "{colors.fallback-terminal-background}"
    textColor: "{colors.fallback-terminal-foreground}"
    typography: "{typography.terminal-body}"
    rounded: "{rounded.sm}"
    padding: 5px
  terminal-caret:
    backgroundColor: "{colors.fallback-terminal-caret}"
    textColor: "{colors.fallback-terminal-background}"
  transfer-overlay:
    backgroundColor: "{colors.fallback-surface-elevated}"
    textColor: "{colors.fallback-on-surface}"
    typography: "{typography.macos-callout}"
    rounded: "{rounded.lg}"
    padding: 12px
  inspector-card:
    backgroundColor: "{colors.fallback-surface-subtle}"
    textColor: "{colors.fallback-on-surface}"
    typography: "{typography.macos-callout}"
    rounded: "{rounded.md}"
    padding: 12px
  command-palette-row:
    backgroundColor: "{colors.fallback-surface}"
    textColor: "{colors.fallback-on-surface}"
    typography: "{typography.macos-body}"
    rounded: "{rounded.xs}"
    padding: 8px
  metadata-label:
    backgroundColor: "{colors.fallback-surface}"
    textColor: "{colors.fallback-secondary}"
    typography: "{typography.macos-caption}"
  status-success:
    backgroundColor: "{colors.fallback-success}"
    textColor: "{colors.fallback-on-status}"
    typography: "{typography.macos-caption}"
    rounded: "{rounded.full}"
    padding: 6px
  status-warning:
    backgroundColor: "{colors.fallback-warning}"
    textColor: "{colors.primary}"
    typography: "{typography.macos-caption}"
    rounded: "{rounded.full}"
    padding: 6px
  status-danger:
    backgroundColor: "{colors.fallback-danger}"
    textColor: "{colors.fallback-on-status}"
    typography: "{typography.macos-caption}"
    rounded: "{rounded.full}"
    padding: 6px
---

# DESIGN.md

## Overview

This file follows the DESIGN.md format from https://github.com/google-labs-code/design.md: YAML front matter holds exact tokens, while the markdown sections explain how to apply them.

Midnight SSH is a native Mac and iPad workspace for SSH, SFTP, Postgres, network tools, and host monitoring. The interface should feel like an operations console: dense, quiet, native, and trustworthy. It should prioritize readable terminal output, fast scanning of host state, and predictable split-pane workflows over decorative branding.

Design for repeated daily use by engineers and operators. Keep the first screen functional. Avoid marketing-style heroes, large illustration-led compositions, and visual flourishes that compete with terminals, file lists, database tables, or monitoring data.

## Colors

Use Apple system semantic colors in Swift. The YAML colors are portable approximations for agents, docs, screenshots, generated assets, or non-native surfaces. The `primary` key is present for DESIGN.md compatibility; the rest are intentionally prefixed `fallback-*`. They are not app implementation tokens and should not replace `Color(NSColor.controlBackgroundColor)`, `Color(NSColor.textBackgroundColor)`, `Color(.secondarySystemGroupedBackground)`, `.foregroundStyle(.secondary)`, or `Color.accentColor`.

- **Primary (#0B0F14):** Required fallback main text color for DESIGN.md compatibility; use native semantic text colors in Swift.
- **Fallback secondary (#4B5563):** Metadata, captions, subtitles, separators, and low-emphasis controls outside native Swift surfaces.
- **Fallback accent (#0066CC):** Accessible fallback interactive accent. Use the user's system accent on native Apple platforms.
- **Fallback window (#F5F7FA):** Light workspace foundation for non-terminal fallback surfaces.
- **Fallback surface / surface-subtle:** Panels, rows, grouped cards, forms, and inspector modules outside native Swift surfaces.
- **Sidebar tints:** Subtle Finder-style blue overlay for the macOS sidebar material.
- **Terminal background / foreground:** Fallback terminal chrome colors. Named terminal themes may override these independently.
- **Success / warning / danger:** Connection, health, transfer, process, firewall, and destructive-state indicators.

Color should encode state, not decoration. Connection dots, health pills, warning rows, and error affordances may use saturated status colors. General chrome should remain neutral and platform-native.

### Semantic Color Mapping

On macOS, map design intent to AppKit semantic colors: window foundations use `windowBackgroundColor`; large browser and table surfaces use `controlBackgroundColor`; editable text and code surfaces use `textBackgroundColor`; primary copy uses `labelColor` or `textColor`; metadata uses `secondaryLabelColor` or `tertiaryLabelColor`; dividers use `separatorColor`; selection uses `selectedContentBackgroundColor`; interactive emphasis uses `controlAccentColor` or SwiftUI `Color.accentColor`.

On iPadOS, map grouped screens to `systemGroupedBackground`, `secondarySystemGroupedBackground`, and `tertiarySystemGroupedBackground`. Use `systemBackground` only for ungrouped content regions, modal content, and full-screen reading surfaces.

Status colors should use system semantic colors where possible: green for connected or healthy, yellow/orange for pending, degraded, or warning, red for failed or destructive, and gray for unavailable or disconnected. Pair status color with text, icon, or shape when the state matters.

## Typography

Use platform defaults: SF Pro for app chrome and SF Mono for terminal, code, paths, hostnames, ports, timestamps, query text, and tabular metrics. The front matter includes both `macos-*` and `ipados-*` type tokens; choose the platform set for the surface being built.

macOS operational chrome should sit mostly in the 11-13 pt range, with 10 pt reserved for low-emphasis captions and compact metadata. iPadOS should start from larger system text styles: body at 17 pt, subheadline at 15 pt, and caption at 12 pt. Do not reuse macOS dense chrome sizes as the default iPad reading model.

Use `macos-title`, `ipados-title`, or native `.headline` only for panel titles, empty states, and modal headings. Avoid hero-scale type inside operational panels.

Use monospaced digits for counters, percentages, byte sizes, ports, durations, CPU and memory metrics, query timings, and transfer rates. Keep letter spacing at `0em`; use weight, color, and layout instead of tracking for emphasis.

## Layout

The primary macOS layout is a persistent split workspace: sidebar, main work area, and optional inspector. The default sidebar is about 240 px wide, the inspector about 320 px wide, and the workspace tab strip is 32 px tall. Layout should remain compact and resizable, with stable minimums so terminal panes, tables, and file browsers do not collapse into unusable states.

Use full-height panes separated by native split-view dividers. The main work area should privilege the terminal and dual-pane file browser. The right inspector is for system monitoring and server health. Multi-host dashboards can take over the main area when at least two SSH hosts are connected.

On iPadOS, prefer `NavigationSplitView` for regular widths and `NavigationStack` for compact widths. Touch surfaces may use larger hit targets, but the visual language should still be operational rather than promotional.

Spacing follows small increments: 4 px for micro-adjustments, 6-8 px inside compact controls, 10-12 px between related controls, and 16-24 px only for larger modal or empty-state breathing room.

## Platform Adaptation

macOS is the primary dense workspace. Use compact split panes, resizable sidebars, keyboard-first commands, hover affordances, focus rings, contextual menus, and titlebar toolbar items. The macOS default body size is 13 pt; smaller text is acceptable for metadata, tab labels, and dense tables, but never below the platform minimum without a user-controlled terminal or data-density setting.

iPadOS should use larger reading and touch defaults. Prefer system text styles such as `.body`, `.subheadline`, and `.caption` instead of reusing macOS 11-13 pt chrome everywhere. Regular-width iPad layouts should preserve a two-column or three-column structure with `NavigationSplitView`; compact layouts should collapse into `NavigationStack` without hiding primary actions.

Terminal typography is its own preference domain. Respect user-selected terminal font size, rows, columns, theme, and scrollback settings. Do not let general app typography tokens override terminal readability or ANSI color themes.

Keep platform idioms distinct. On macOS, important toolbar actions must also be reachable through the menu bar or command palette. On iPadOS, actions should be reachable from toolbars, context menus, keyboard shortcuts where useful, and touch-friendly menus without requiring hover.

## Window & Commands

macOS windows should use the titlebar toolbar for high-frequency navigation and workspace controls: show or hide sidebar, show or hide inspector, command palette, search, dashboard, reconnect, diagnostics, and settings where appropriate. Toolbar items should use SF Symbols and platform tooltips, and should collapse cleanly into overflow when the window narrows.

Every toolbar command needs an equivalent route through the menu bar, command palette, contextual menu, or keyboard shortcut. The toolbar is a convenience layer, not the only command surface. Destructive, credential, host-key, and file overwrite commands need explicit wording and platform roles regardless of where they are invoked.

Search fields should stay local to the surface they filter: sidebar search filters connections, command palette search filters commands and profiles, terminal search filters scrollback, file search filters file listings, and Postgres search filters schemas, history, saved queries, or results depending on context. Avoid one ambiguous global search box unless it clearly opens the command palette.

## Materials & Accessibility Modes

Let SwiftUI and AppKit provide the current system appearance for standard controls, navigation, sidebars, popovers, sheets, and toolbars. Use custom `NSVisualEffectView` materials only where the app needs a clear pane relationship, such as Finder-style sidebars, inspectors, transient overlays, and dashboard chrome.

Do not manually apply glass effects, blur, or translucency to content that needs sustained reading: terminals, Postgres tables, file lists, log streams, process lists, diff views, and code editors should remain opaque and high-contrast. Materials belong around these surfaces, not inside the content rows.

Validate every major surface in light appearance, dark appearance, Increase Contrast, Reduce Transparency, and full keyboard access. If Reduce Transparency is enabled, material-backed surfaces must fall back to clear opaque system backgrounds. If Increase Contrast is enabled, separators, selections, focus rings, and status boundaries should become more explicit.

Color cannot be the only state cue. Pair important colors with labels, icons, row text, or shape: a green dot still needs a "Connected" affordance where status matters; a red destructive state needs text, role, and confirmation behavior; a warning should include both a symbol and concise explanation.

## Interaction States

Every reusable component needs defined states for default, hover, pressed, focused, selected, disabled, loading, error, empty, offline, and read-only where applicable. Dense controls can stay visually quiet by default, but focus and selection must be unmistakable for keyboard users.

Drag-and-drop targets should visibly activate before the drop, using a combination of accent tint, border, insertion indicator, or row highlight. Do not rely on cursor changes alone. File, folder, tab, and connection reordering should preserve layout dimensions while a drag is active.

Long-running work needs progress and recovery states. Transfers, query exports, remote commands, tcpdump streams, reconnects, and monitor polling should show whether work is queued, active, paused, failed, retryable, or complete. Error states should offer the next practical action, such as reconnect, retry, reveal logs, copy diagnostics, or cancel.

Destructive actions should use platform roles and context. Disconnect, delete, kill process, overwrite remote file, revoke key, and trust host key mismatch are different risks; style and confirmation copy should reflect the consequence instead of using a generic danger pattern for all of them.

## Elevation & Depth

Depth comes from native materials, tonal layering, separators, and subtle overlays. Prefer `.sidebar`, `.contentBackground`, `.bar`, grouped backgrounds, and system list materials over custom shadows.

Use shadows sparingly. Floating progress overlays, reconnect overlays, and transient HUDs may use a soft shadow or material blur. Routine cards, tables, file rows, and inspector sections should rely on background contrast and borders instead.

Terminal panes should feel flat and stable. Do not add decorative gradients, glows, or heavy frames around terminal content.

## Shapes

Use tight, utilitarian geometry. The common radius is 6-8 px. Tabs and small icon buttons may use 4-6 px. Progress bars can use 2 px. Popovers, reconnect overlays, and transfer overlays may use 12 px; reserve 16 px for iPad modal HUDs and large transient sheets.

Capsules are appropriate for status badges, small counts, and compact pills. Do not turn ordinary buttons, table cells, or sidebar rows into pill shapes.

## Components

**Sidebar:** Use native list behavior, Finder-style material, compact search, folder disclosure, and SF Symbols. Rows should expose identity first: name, then `user@host:port`, then state.

**Workspace tab strip:** This is a browser-style session switcher, not a platform tab bar. Keep it compact. Each workspace tab shows connection status, title, close affordance, and optional terminal theme menu. Active state should be obvious but not loud.

**Terminal pane:** Preserve scrollback readability. Padding should be minimal. Terminal themes own ANSI palettes and terminal background/foreground; app chrome around the terminal should not reinterpret terminal colors.

**Inspector and dashboards:** Favor scannable modules with short labels, monospaced metrics, and status color only where it represents host state. Side-by-side host comparisons should align metrics and use stable widths.

**Command palette:** Make it fast to scan: icon, action title, concise subtitle, no explanatory copy. Disabled rows should be visibly secondary but remain understandable.

**Forms and settings:** Use native `Form`, `Picker`, `Toggle`, sliders, and platform controls. Keep field labels direct. Use helper text only when it changes user behavior or prevents data loss.

**Tables and browsers:** Postgres results, file lists, process lists, and logs should use compact rows, visible sorting/filtering affordances, and monospaced values for technical data. Preserve column alignment and avoid row-height jumps.

**Status indicators:** Green means connected or healthy, yellow/orange means pending, degraded, or warning, red means failed or destructive. Gray means disconnected, unavailable, or low-emphasis metadata.

## Do's and Don'ts

- Do prefer native Apple controls, materials, semantic colors, and SF Symbols.
- Do keep operational surfaces dense, stable, and easy to scan.
- Do use monospaced typography for terminal content, code, paths, metrics, and network/database identifiers.
- Do use platform-specific typography tokens and status colors consistently across workspace tabs, dashboards, transfer queues, monitor panels, and mobile cards.
- Do preserve platform accessibility behavior, dynamic type where practical, keyboard navigation, and contrast.
- Don't hard-code app-wide colors in Swift when a semantic system color or `Color.accentColor` is the correct platform value.
- Don't create landing pages, decorative hero sections, gradient-orb backgrounds, or oversized marketing cards inside the app.
- Don't use color as decoration in tables or monitoring surfaces; color should communicate state or action.
- Don't put cards inside cards. Use panes, dividers, grouped backgrounds, and repeated item cards only where they represent distinct records.
- Don't add heavy shadows around routine panels, terminal panes, lists, or database tables.
- Don't change generated bindings or Xcode project files as part of visual work unless the underlying build step explicitly requires regeneration.
