# OpenFind — Development Document

A local, real-time, developer-friendly advanced file search tool for macOS 26+,
backed by a persistent path/name index and on-demand content matching.

**Product principle:** fast, focused, and quiet. Do one thing — find files — and
make it feel effortless. Apple-minimalist design: progressive disclosure,
generous whitespace, restrained color, native controls.

---

## Product Goals

1. **Instant** — results stream in as you type from a local path/name index.
2. **Accurate** — include hidden files, normal user-file locations, and mounted volumes by default; name search means file names; path search is explicit with `/` or `path:`.
3. **Native** — feels like an Apple app: keyboard-first, Quick Look, dark mode.
4. **Trustworthy** — no network, security-scoped folders, transparent about permissions.
5. **Shippable** — universal app bundle, signing/notarization path, CI, tests, accessibility.

---

## Modularization Red Lines

- Every Swift source file must remain under 200 lines.
- One main type / view per file.
- Views are purely for layout; logic belongs to ViewModel; IO belongs to Engine/Store.
- Strictly unidirectional dependencies: `Views -> State -> Engine -> Models`.

## Architecture

Single SwiftUI executable (SPM), split by concern:

| Layer | Files | Responsibility |
|-------|-------|----------------|
| Models | `SearchModels`, `Matcher` | Value types, query → predicate |
| Engine | `SearchEngine`, `SearchIndex` | Persistent path/name index + bounded-concurrency content match |
| State | `SearchViewModel`, `Preferences`, `ScopeStore` | UI state, persistence, security-scoped access |
| Views | `ContentView`, `SearchHeader`, `FilterBar`, `ResultsView`, `SettingsView` | Presentation |
| Support | `FileActions`, `FileIcon`, `Localized` | System integration |
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
- ✅ Convert all comments/strings to English (code language = English)
- ✅ `Preferences`: persist search options via `@AppStorage`
- ✅ `ScopeStore`: security-scoped bookmarks so folder access survives relaunch

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

### Phase 5 — Distribution Readiness
- ✅ Direct and sandbox entitlement profiles
- ✅ Universal app bundle build script
- ✅ ZIP-only build output, single customer signing identity, atomic local install without persistent duplicate backups, and product-App uniqueness checks
- ✅ Developer ID signing and notarization automation path
- ✅ CI for tests, app bundle, and benchmark smoke test
- ⬜ About + Help, polished Info.plist, category, copyright
- ⬜ Accessibility labels (VoiceOver)
- ⬜ Final notarized release artifact with real Developer ID credentials

### Backlog / Post-1.0
- ⬜ Localization (add zh-Hans and others)
- ⬜ Saved searches, smart folders
- ⬜ File type / size / date filters
- ⬜ Spotlight-metadata hybrid mode
- ⬜ Notarized DMG for direct distribution

---

## Development Log

Newest first. Each entry: what changed, why, how verified.

### 2026-07-06 — Product positioning, search semantics, quiet indexing defaults
- Updated product positioning: OpenFind is now documented as a local, real-time, developer-friendly advanced file searcher.
- Whole-Mac indexing includes hidden files, user-file locations, and mounted volumes by default while filtering caches, logs, `/private/var`, and other noisy locations unless Deep Index is enabled.
- Plain name search now matches file names only. Path search is explicit through `/` path syntax or `path:` / folder-scope filters.
- Added indexing/permission readiness states so the UI does not show a definitive no-results screen while the local index is still building.
- Added direct and sandbox entitlement profiles, universal build/sign/notarization automation, GitHub Actions CI, benchmark smoke script, and index scale regression coverage.

### 2026-07-01 — Independent review, deadlock fix & hardening
- Audited the modularization refactor against reality (not the report): clean build, single-definition types, sub-200-line files, CLI accuracy (grep cross-check), and localization were each verified independently.
- Found the committed HEAD shipped a deadlocking CLI entry point: `main.swift` blocked the `@MainActor` executor with `semaphore.wait()`, so the CLI `Task` never started (reproduced as a SIGALRM hang). The working fix existed only in the uncommitted working tree; committed it.
- Hardened: switched the CLI wait to `dispatchMain()` (non-spinning, idiomatic main-thread yield); normalized SwiftPM's lowercased `zh-hans.lproj` back to canonical `zh-Hans` in `build_app.sh` so Chinese resolves on case-sensitive volumes/CI too.
- Verified: debug + release builds green; CLI name/content search correct and non-hanging; shipped bundle reports `["en", "zh-Hans"]` and resolves Chinese (`搜索...`, `名称`).

### 2026-07-01 — Phase 1 completed & modularization repaired
- Refactored layout and created modern Spotlight-style SearchHeader, progressive FilterBar, ResultsTable, and StatusBar.
- Introduced strict modularization guidelines (all files under 200 lines, single concerns).
- Built localization infrastructure utilizing `.module` resource bundle with supporting Chinese (`zh-Hans`) and English (`en`) key mappings.
- Implemented App commands structure for keyboard-first navigation and Settings scene (⌘,).
- Created automated icon renderer using AppKit rendering APIs and consolidated deployment pipeline script producing finalized application bundles.
- Verified compilation and build pipeline passes cleanly via `xcrun --sdk macosx swift build` and CLI functionalities.

### 2026-07-01 — Phase 0 baseline recorded
- Baseline from prior session: working engine + GUI + CLI, packaged ad-hoc app.
- Established this development document and the phased roadmap above.
- Next: Phase 1 (English conversion + persistence foundation).
