# OpenFind — Development Document

A modern, App Store–quality reimplementation of the classic EasyFind concept:
instant, index-free file search for macOS. Clean-room, original Swift 6 / SwiftUI
code. No EasyFind source or assets are used.

**Product principle:** fast, focused, and quiet. Do one thing — find files — and
make it feel effortless. Apple-minimalist design: progressive disclosure,
generous whitespace, restrained color, native controls.

---

## Product Goals

1. **Instant** — results stream in as you type; no index, no waiting.
2. **Accurate** — find what Spotlight can't (system files, exact names, regex).
3. **Native** — feels like an Apple app: keyboard-first, Quick Look, dark mode.
4. **Trustworthy** — no network, sandboxed, transparent about permissions.
5. **Shippable** — sandbox entitlements, tests, accessibility, ready to submit.

---

## Architecture

Single SwiftUI executable (SPM), split by concern:

| Layer | Files | Responsibility |
|-------|-------|----------------|
| Models | `SearchModels`, `Matcher` | Value types, query → predicate |
| Engine | `SearchEngine` | Index-free traversal + bounded-concurrency content match |
| State | `SearchViewModel`, `Preferences`, `Bookmarks` | UI state, persistence, security-scoped access |
| Views | `ContentView`, `SearchHeader`, `FilterBar`, `ResultsView`, `SettingsView` | Presentation |
| Support | `FileActions`, `QuickLook` | System integration |
| Entry | `main`, `OpenFindApp`, `AppCommands`, `CLIRunner` | Lifecycle, menus, CLI |

Build note: local `swift build` mis-infers the SDK; always use
`xcrun --sdk macosx swift build`. `Scripts/build_app.sh` bakes this in.

---

## Roadmap

Status: ✅ done · 🚧 in progress · ⬜ planned

### Phase 0 — Foundation (shipped in previous session)
- ✅ Core engine, GUI, packaging, CLI mode
- ✅ Verified: engine accuracy (grep cross-check), GUI launch, packaged `.app`

### Phase 1 — English + Persistence
- ⬜ Convert all comments/strings to English (code language = English)
- ⬜ `Preferences`: persist search options via `@AppStorage`
- ⬜ `Bookmarks`: security-scoped bookmarks so folder access survives relaunch

### Phase 2 — Apple-Minimalist Redesign
- ⬜ Prominent search header (Spotlight-like), calm and centered
- ⬜ Filter bar with progressive disclosure (advanced options behind a menu)
- ⬜ Refined results table: icon, name, subtle path, aligned metadata
- ⬜ Considered empty / loading / no-results states
- ⬜ Verified light + dark appearance

### Phase 3 — Mac-Native UX
- ⬜ Full keyboard control: ↑↓ navigate, ⏎ open, ⌘⏎ reveal, Space = Quick Look
- ⬜ Quick Look preview integration
- ⬜ Recent searches
- ⬜ Settings window (⌘,)
- ⬜ Restore window + options on relaunch

### Phase 4 — Robustness + Tests
- ⬜ Content search: encoding detection, match highlighting
- ⬜ Unit tests: `Matcher` (all modes), `SearchEngine` (fixtures)
- ⬜ Performance sanity on large trees

### Phase 5 — App Store Readiness
- ⬜ App Sandbox entitlements + user-selected file access via bookmarks
- ⬜ About + Help, polished Info.plist, category, copyright
- ⬜ Privacy posture documented (no network, no telemetry)
- ⬜ Accessibility labels (VoiceOver)
- ⬜ Final packaged, signed build

### Backlog / Post-1.0
- ⬜ Localization (add zh-Hans and others)
- ⬜ Saved searches, smart folders
- ⬜ File type / size / date filters
- ⬜ Spotlight-metadata hybrid mode
- ⬜ Notarized DMG for direct distribution

---

## Development Log

Newest first. Each entry: what changed, why, how verified.

### 2026-07-01 — Phase 0 baseline recorded
- Baseline from prior session: working engine + GUI + CLI, packaged ad-hoc app.
- Established this development document and the phased roadmap above.
- Next: Phase 1 (English conversion + persistence foundation).
