# Alfred Clipboard Benchmark and OpenFind Decisions

Evidence date: 2026-07-22. Local reference: `/Applications/Alfred 5.app`, version
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

## Adopt / Keep / Reject

| Capability | Alfred evidence | OpenFind decision |
| --- | --- | --- |
| Focused search, dense single-line rows, app icon, `⌘1–9`, two-pane preview | Runtime and bundle resources | **Keep**. OpenFind already provides these with Liquid Glass and richer source/copy metadata. |
| Return/click pastes to the previous app | Official help and runtime | **Keep**. This remains the primary action; the action surface never replaces it. |
| Permanent reusable clips | `⌘S` saves a clip as a snippet | **Adopt now** as `⌘S` “Save for Reuse”, backed by OpenFind's existing encrypted pinned-item model, aliases, editable text, and stable keys. |
| Contextual item actions | Universal Actions and local `showActionsPanelForSelection` symbol | **Adopt now** as a type-aware `⌘K`/ellipsis popover. URL and file-only actions are not shown for unrelated content. |
| Quick Look for files | Local `toggleQuickLook` and preview renderer symbols | **Adopt now** using native `QLPreviewPanel`; retain OpenFind's inline preview as the normal path. |
| Clipboard merging | Official `⌘C`-twice feature | **Adopt the useful core now**: merge an explicit multi-selection in its chosen order. Do not globally intercept a user's second `⌘C`. |
| Clear recent history | Official 5/15-minute clearing | **Adopt now**, preserving saved/pinned entries. |
| Snippet collections and automatic expansion | Official snippets help | **Later**. Adding a second permanent-content database would duplicate pins today; collections should arrive only with an auto-expansion product contract. |
| Explicit batch/offset loading | Local `historyWithFilter:limit:` / `historyWithOffset:` symbols | **Evidence gate**. OpenFind already uses a lazy list capped by encrypted storage limits; paginate only if performance tests show a real regression. |
| Opaque custom accessibility tree | Runtime exposes the search field but not list rows | **Reject**. OpenFind keeps each clipboard row accessible and selected-state aware. |
| Alfred purple selection, branding, “All Snippets” synthetic row | Runtime | **Reject visual copying**. OpenFind keeps native system typography, Liquid Glass, one search surface, and no redundant visible title. |

## Acceptance Contract for This Iteration

1. `⌘K` and the existing ellipsis open the same compact action popover.
2. Single-item actions are content-aware; multi-selection offers Paste Stack and
   newline-joined plain-text copy in explicit selection order.
3. `⌘S` saves an unsaved item and is idempotent for an already saved item.
4. Clear-last-5/15-minutes never removes saved items.
5. Search/IME, hover selection, wheel scrolling, direct click/Return paste, source-app
   identity, and row accessibility remain unchanged.
