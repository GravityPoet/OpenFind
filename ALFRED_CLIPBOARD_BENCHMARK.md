# Alfred Clipboard Benchmark and OpenFind Decisions

Evidence date: 2026-07-24. Local reference: `/Applications/Alfred 5.app`, version
5.7.3 (build 2320), Universal `arm64`/`x86_64`.

Alfred is proprietary. Its source code is not present on this Mac. The local review was
limited to observable runtime behavior, bundle metadata, Interface Builder resources,
Objective-C class/method names, accessibility output, and non-sensitive preference
shape. OpenFind does not copy Alfred code, artwork, wording, or brand colors.

## Evidence

- [Alfred Clipboard History](https://www.alfredapp.com/help/features/clipboard/):
  searchable text/image/file history, auto-paste, per-type retention, ignore rules,
  clearing recent history, clipboard merging, and saving an item as a snippet.
- [Accessing Clipboard History](https://www.alfredapp.com/help/features/clipboard/accessing-clipboard-history/):
  numbered clipboard placeholders and workflow access to older clips.
- [Alfred Snippets](https://www.alfredapp.com/help/features/snippets/): permanent,
  searchable reusable text grouped in collections with dynamic placeholders.
- [Alfred Universal Actions](https://www.alfredapp.com/help/features/universal-actions/):
  a contextual action surface whose commands depend on the selected item type.
- [Alfred Changelog](https://www.alfredapp.com/changelog/): no clipboard-specific UI
  change was published during the latest three-month research window. The installed
  5.7.3 release records a multi-space window-rendering mitigation.
- [Raycast Clipboard History](https://manual.raycast.com/clipboard-history) and
  [Raycast Windows Changelog](https://www.raycast.com/changelog/windows/2): current
  competitors preserve original formats, group multi-content entries, rename saved
  items, improve long-string/image previews, and identify the target app in paste
  actions.
- [Maccy 2.6.1 source](https://github.com/p0deje/Maccy/tree/dec66013b1a6865608949845e8eabd85cff3fc29):
  the exact local release is an `LSUIElement` utility with one no-animation,
  nonactivating floating panel and no foreground/background activation-policy switch.

## Adopt / Keep / Reject

| Capability | Alfred evidence | OpenFind decision |
| --- | --- | --- |
| Focused search, dense single-line rows, app icon, `⌘1–9`, two-pane preview | Runtime and bundle resources | **Keep**. OpenFind already provides these with Liquid Glass and richer source/copy metadata. |
| Return/click pastes to the previous app | Official help and runtime | **Keep**. This remains the primary action; the action surface never replaces it. |
| Permanent reusable clips | `⌘S` saves a clip as a snippet | **Adopt now** as `⌘S` “Save for Reuse”, backed by OpenFind's existing encrypted pinned-item model, aliases, editable text, and stable keys. |
| Contextual item actions | Universal Actions and local `showActionsPanelForSelection` symbol | **Adopt now** as a type-aware `⌘K`/ellipsis popover. URL and file-only actions are not shown for unrelated content. |
| Quick Look for files | Local `toggleQuickLook` and preview renderer symbols | **Adopt now** using native `QLPreviewPanel`; retain OpenFind's inline preview as the normal path. |
| Clipboard merging | Official `⌘C`-twice feature | **Adopt with a safer default**: explicit ordered multi-selection and Paste Stack work without interception; a guarded double-`⌘C` Quick Merge is available as an explicit opt-in. |
| Clear recent history | Official 5/15-minute clearing | **Adopt now**, preserving saved/pinned entries. |
| Snippet collections and automatic expansion | Official snippets help | **Adopted** through the encrypted reusable-item model: collections, keywords, stable shortcuts, placeholders, and opt-in expansion share one database instead of duplicating pins. |
| Explicit batch/offset loading | Local `historyWithFilter:limit:` / `historyWithOffset:` symbols | **Evidence gate**. OpenFind already uses a lazy list capped by encrypted storage limits; paginate only if performance tests show a real regression. |
| Opaque custom accessibility tree | Runtime exposes the search field but not list rows | **Reject**. OpenFind keeps each clipboard row accessible and selected-state aware. |
| Alfred purple selection, branding, “All Snippets” synthetic row | Runtime | **Reject visual copying**. OpenFind keeps native system typography, Liquid Glass, one search surface, and no redundant visible title. |
| OCR text inside images | No OCR-search behavior is documented in Alfred's clipboard help | **Extend beyond parity** with local Vision recognition at background priority, encrypted persistence, and privacy-rule rejection. |
| Source/type/state/collection filters | Clipboard help documents ordinary word/phrase filtering | **Extend beyond parity** with a compact filter menu that composes structured filters with normal text search. |
| Recovery after delete/clear | Individual and recent clearing are documented without a persistent recovery control | **Extend beyond parity** with a visible, keyboard-operable undo action that preserves new captures. |
| Resident shortcut latency | Alfred warm invocation measured at 40–55 ms with the earlier AX method; exact Maccy/OpenFind measurements use a separate identical CGWindow script | **Match the resident architecture**. The final Universal OpenFind build improved from 903.6 ms to 184.4 ms on the first invocation after closing its main window and 103.5 ms warm median; the identical Maccy run measured 237.8 ms first and 150.7 ms warm median. |

## Acceptance Contract for the Alfred-Derived Interaction Layer

1. `⌘K` and the existing ellipsis open the same compact action popover.
2. Single-item actions are content-aware; multi-selection offers Paste Stack and
   newline-joined plain-text copy in explicit selection order.
3. `⌘S` saves an unsaved item and is idempotent for an already saved item.
4. Clear-last-5/15-minutes never removes saved items.
5. Search/IME, hover selection, wheel scrolling, direct click/Return paste, source-app
   identity, and row accessibility remain unchanged.
