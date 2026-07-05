## SwiftTerm Capability Audit — Sprint 7

Comparison of xterm.js (current Tauri app) vs SwiftTerm (native macOS):

| Feature | xterm.js | SwiftTerm | Gap? |
|---------|----------|-----------|------|
| True color (24-bit) | ✅ | ✅ | — |
| 256-color palette | ✅ | ✅ | — |
| Bold/italic/underline | ✅ | ✅ | — |
| Alternate screen (vim) | ✅ | ✅ | — |
| Mouse tracking (tmux) | ✅ | ✅ | — |
| Unicode (CJK, Emoji) | ✅ | ✅ | Partial — width calculation differs |
| Scrollback buffer | ✅ | ✅ | Configurable up to 10k lines |
| Search within terminal | ✅ (addon) | ❌ | Need native search bar |
| Web links | ✅ (addon) | ✅ (automatic) | Actually better |
| Sixel / Kitty image protocol | ✅ (addon) | ❌ | Not needed for v1 |
| Clipboard integration | ✅ (addon) | ✅ | Native NSPasteboard |
| Selection (copy) | ✅ | ✅ | Native text selection |
| Drag & drop files | ✅ | ❌ | Not needed for v1 |
| Cursor styles (block/bar/line) | ✅ | ✅ | — |
| Themes (colors, background) | ✅ | ✅ | CSS vs native NSColor |

**Key gaps to address in Sprint 8:**
- Search UI needs a custom implementation (SwiftTerm has no built-in search)
- Sixel/image not supported — acceptable for v1
- Unicode width may differ subtly from xterm.js — test CJK explicitly

**Verdict:** SwiftTerm covers all core interactive workflows (`vim`, `less`, `tmux`, `htop`, shell editing). No blockning gaps for v1.
