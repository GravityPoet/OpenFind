# OpenFind Clipboard Parity Matrix

This is the acceptance contract for OpenFind's clipboard module. Evidence was refreshed
on 2026-07-24 against the installed Universal builds of Maccy 2.6.1 and Alfred 5.7.3
(build 2320). The Maccy behavior review also uses upstream commit
`dec66013b1a6865608949845e8eabd85cff3fc29`, the exact 2.6.1 tag. Maccy's MIT
implementation is evidence for
behavior; Alfred's proprietary bundle was reviewed only through observable behavior,
metadata, accessibility output, and public documentation.

Status: `[x]` verified and enabled by default, `[~]` supported but intentionally opt-in,
`[-]` intentionally different or outside this module, `[ ]` a remaining core gap.

## Current Local Comparison

| Experience | Maccy 2.6.1 | Alfred 5.7.3 | OpenFind | Classification |
| --- | --- | --- | --- | --- |
| Dedicated clipboard shortcut | Compact menu/list | Dedicated two-pane viewer | One centered two-pane panel; never raises the file-search window | `[x]` |
| Search on invocation | Search field in the clipboard surface | Typing immediately filters | Search field is visible on the first frame and focus is coalesced within 50 ms | `[x]` |
| Source application identity | App icon per item | App icon per item | Installed app icon/name plus bundle ID in metadata | `[x]` |
| Click/Return behavior | Paste to previous app | Paste to previous app by default | Paste to previous app and close | `[x]` |
| Hot invocation | Same-script first 237.8 ms; warm median 150.7 ms | 40–55 ms warm in the earlier AX observation | Final Universal build: same-script first 184.4 ms after closing the main window; warm median 103.5 ms, versus 903.6 ms before the resident-utility fix | `[x]` |
| Image text search | No built-in OCR search | Image history, but no documented OCR text filter | Local Vision OCR, encrypted with the item and paused while the panel is open | `[x]` exceeds |
| Precise filtering | Text search | Text search and workflow/snippet context | Text plus source app, content type, pinned/snippet state, and collection filters | `[x]` exceeds |
| Destructive-action recovery | Delete/clear without a persistent recovery banner | Individual/recent/all clearing | Visible undo banner and `⌘Z` for individual, multi-item, recent, or full clear | `[x]` exceeds |
| Retention | Primarily capacity based | Per-type time choices | User-selected 3/7/15/30 days or Forever; reusable items never age out | `[-]` user-selected model |
| Clipboard merging | Paste Queue | Global double-`⌘C` merge | Explicit ordered multi-selection and Paste Stack by default; guarded double-`⌘C` Quick Merge is available | `[x]` explicit / `[~]` Quick Merge |
| Reusable snippets | Pins | Collections, keywords, expansion | Encrypted collections, keywords, aliases, placeholders, and stable shortcuts | `[x]` |
| Automatic snippet expansion | No equivalent | Supported | Supported with an application-scoped bounded typing buffer | `[~]` off by default |
| Custom themes/launcher workflows | Limited | Extensive | System appearance and App Intents, without an Alfred-compatible workflow/theme runtime | `[-]` outside clipboard scope |
| Accessibility | Native menu semantics | Improved keyboard/VoiceOver support; list exposure remains implementation-specific | Explicit row labels, values, selected state, actions, full keyboard flow, contrast/transparency adaptations | `[x]` |

No unresolved core clipboard interaction gap remains in this comparison. The remaining
intentional differences are the time-retention model requested for OpenFind, avoidance of
silently enabling global double-`⌘C` interception, and not recreating Alfred's broader
proprietary workflow/theme platform.

The user's explicit product decisions override the reference defaults:

- The clipboard shortcut opens a focused clipboard-only search panel, centered on
  the active screen. It never creates, restores, or raises OpenFind's main search
  window.
- The panel has no visible “Clipboard History” title or redundant title icon.
- Hovering a row moves the solid selection and preview to that row. Pointer-driven
  selection never recenters or snaps the scroll view.
- A plain click or Return pastes directly into the previously active application and
  closes the panel. Copy-only remains available through explicit shortcuts and menus.
- Retention is time based: 3, 7, 15, or 30 days, plus Forever. Forever disables age
  expiry and automatic item-count deletion. Per-item size remains bounded and manual
  cleanup stays available.
- Global typing and copy interception are never enabled silently. Snippet expansion and
  double-`⌘C` Quick Merge are explicit opt-ins, display their permission/readiness
  state, use bounded application-scoped state, and still honor ignored/allow-listed
  applications.

## Maccy 2.6.1 Source-Derived Resident Architecture

The exact 2.6.1 source tag establishes four latency-relevant facts: Maccy declares
`LSUIElement`, constructs its popup once during application launch, dispatches the
registered shortcut directly to the popup, and presents a nonactivating panel with no
animation using `orderFrontRegardless()` plus `makeKey()`. It does not switch between
regular and accessory activation policies when its primary UI opens or closes:
[Info.plist](https://github.com/p0deje/Maccy/blob/dec66013b1a6865608949845e8eabd85cff3fc29/Maccy/Info.plist),
[AppDelegate](https://github.com/p0deje/Maccy/blob/dec66013b1a6865608949845e8eabd85cff3fc29/Maccy/AppDelegate.swift),
[Popup](https://github.com/p0deje/Maccy/blob/dec66013b1a6865608949845e8eabd85cff3fc29/Maccy/Observables/Popup.swift),
and [FloatingPanel](https://github.com/p0deje/Maccy/blob/dec66013b1a6865608949845e8eabd85cff3fc29/Maccy/FloatingPanel.swift).

OpenFind adopts that architecture, not Maccy's implementation or branding: the process
remains an accessory utility for its full lifetime, while its one pre-rendered
clipboard panel stays centered, noninteractive, visually imperceptible, and excluded
from accessibility until the shortcut presents it. This removed the reproducible
activation-policy/TextInputUI timeout without dropping OpenFind's two-pane preview.

## Capture, Storage, and Privacy

- `[x]` Capture text, rich text, URLs, files, and images without flattening retained
  pasteboard representations; preserve multiple file pasteboard items.
- `[x]` Deduplicate equivalent payloads while preserving first-copy time, latest-copy
  time, copy count, pin state, and newest real source application.
- `[x]` Record source bundle identifier and display the installed application icon/name
  for new copies; legacy entries decode without invented provenance.
- `[x]` Ignore concealed, transient, autogenerated, password-manager, and Universal
  Clipboard payloads before persistence.
- `[x]` Encrypt persistent history locally. Retention is 3/7/15/30 days or Forever;
  expiry and capacity cleanup never silently remove pinned entries.
- `[x]` Enable or disable retained files, images, and text independently, preserving an
  allowed fallback representation when a disallowed one shares the same pasteboard item.
- `[x]` Display current retained storage size and support first-copy/last-copy sorting.
- `[x]` Manage ignored applications with an application picker or bundle identifier,
  including an independent, default-empty allow list in advanced settings. New and
  existing deny-list profiles receive a versioned catalog covering common password
  managers and Apple's Passwords/Keychain utilities; a user's later removals remain
  removed.
- `[x]` Manage custom ignored pasteboard types and reset the default privacy list.
- `[x]` Manage validated regular expressions whose matching text must not be retained.
- `[x]` Pause all capture and ignore exactly the next external copy.
- `[x]` Configure the bounded clipboard polling interval.

## Window, Rows, and Preview

- `[x]` Use a native floating panel with Liquid Glass reserved for the control layer,
  standard adaptive materials in the content layer, compact single-line rows, solid
  selection, image thumbnails, source application icons, and right-aligned shortcuts.
- `[x]` The global shortcut opens only the clipboard panel, centered on the current
  screen, with the clipboard search field visible and focused; the main OpenFind search
  window remains hidden.
- `[x]` Omit the visible “Clipboard History” label and icon while retaining an internal
  accessibility/window name.
- `[x]` Hover moves selection and the right preview to the pointer row. Wheel scrolling
  remains pointer-controlled and is not pulled back by programmatic `scrollTo`.
- `[x]` Text, image, and file preview shows source application, dimensions, first/last
  copy time, copy count, byte size, and full selectable content.
- `[x]` The first visible frame is the complete two-pane list and preview; no hover task
  or configurable delay is involved. The preview can still be toggled manually and its
  resized width is retained.
- `[x]` A compositor-resident panel surface removes WindowServer remapping delay while
  remaining centered, visually imperceptible, noninteractive, and absent from the
  accessibility tree. Keyboard handling is gated by presentation state, not AppKit's
  `isVisible` flag.
- `[x]` Configure popup position/screen for non-shortcut entry points, pinned-item
  position, image-row height, footer, application icons, and special-symbol visibility.
- `[x]` Render a compact color swatch for valid hexadecimal color entries.
- `[x]` Optionally expose the most recent copy in OpenFind's menu-bar menu.
- `[-]` Maccy logo/menu-icon artwork and standalone-app branding are outside this module;
  OpenFind keeps its shared menu-bar identity.

## Search

- `[x]` The search field is immediately available and searches item text, custom title,
  source application name, and bundle identifier.
- `[x]` Exact substring, fuzzy, regular-expression, and mixed modes preserve pin ordering
  and stable selection; invalid regular expressions fail safely.
- `[x]` Highlight every visible match with configurable bold, color, italic, or underline
  styling.
- `[x]` Search editing supports clear, character/word deletion, IME marked text, and
  first/last/next/previous keyboard navigation without stealing system shortcuts.
- `[x]` Local Vision OCR makes image text searchable and copyable. It starts after a
  delay at background priority, pauses between items while the panel is presented, and
  applies privacy text rules before an OCR result remains in encrypted history.
- `[x]` The compact filter menu composes source-application, content-type,
  pinned/snippet-state, and snippet-collection filters with ordinary text search.

## Actions and Keyboard Flow

- `[x]` Arrow/Page/Home/End navigation is stable; pointer selection is a distinct origin
  that does not trigger keyboard-style scroll recentering.
- `[x]` Plain click and Return automatically paste and close. Target activation waits for
  the previously active process; failures keep the copied content and expose an error.
- `[x]` Explicit copy, paste, and paste-without-formatting work from keyboard, numeric
  shortcut, and context menu.
- `[x]` Pin/unpin, delete, clear unpinned, and clear all preserve a valid selection.
- `[x]` Individual deletion, multi-selection deletion, recent clearing, unpinned
  clearing, and full clearing expose one visible recovery action and `⌘Z`; newly copied
  entries are preserved when older entries are restored.
- `[x]` Pin, delete, and preview shortcuts are configurable.
- `[x]` Repeated global shortcut presses cycle through items and confirm on modifier
  release.
- `[x]` Pinned items receive stable unique shortcuts and support a custom key, alias/title,
  and editable plain-text value.
- `[x]` Command/Shift multi-selection creates a Paste Stack in selection order. Matching
  Maccy, confirmation primes the first item; each real Command-V key-up advances the
  clipboard to the next item without racing the target application's paste.
- `[x]` Menu-bar modifier actions pause capture or ignore only the next copy.

## Alfred-Derived Extensions

- `[x]` `⌘K` and the compact ellipsis button open the same keyboard-navigable,
  type-aware action popover without displacing the always-visible search field.
- `[x]` Text and rich-text entries offer paste/copy variants; URLs add Open Link;
  file entries add Open, Reveal in Finder, and native Quick Look. Unrelated actions
  are omitted instead of disabled clutter.
- `[x]` `⌘S` idempotently saves the selected entry for reuse through OpenFind's
  existing encrypted pinned-item model, retaining stable shortcuts, aliases, and
  editable text rather than introducing a duplicate snippet database.
- `[x]` Explicit multi-selection can start a Paste Stack or newline-merge plain-text
  entries in the user's selection order. The separate, guarded double-`⌘C` Quick Merge
  is available but remains off by default.
- `[x]` Clear-last-5-minutes and clear-last-15-minutes remove only unpinned entries;
  saved items survive both actions.
- `[-]` Alfred branding, purple selection, opaque list accessibility, synthetic “All
  Snippets” rows, and proprietary implementation details are intentionally excluded.
  The evidence and adopt/keep/reject rationale live in
  `ALFRED_CLIPBOARD_BENCHMARK.md`.

## Apple Design and Accessibility Basis

- Apple positions Liquid Glass as the top functional layer for controls and navigation,
  and standard materials as the content layer. OpenFind therefore avoids glass-on-glass
  rows and uses the system material only where hierarchy requires it:
  [Human Interface Guidelines — Materials](https://developer.apple.com/design/human-interface-guidelines/materials).
- macOS 27 refines Liquid Glass automatically and emphasizes keyboard navigation,
  concentric geometry, and adaptive system components:
  [Modernize your AppKit app — WWDC26](https://developer.apple.com/videos/play/wwdc2026/289/).
- Reduce Transparency must replace semitransparent window backgrounds with an opaque
  surface, while Increase Contrast and VoiceOver require explicit semantic adaptations:
  [accessibilityReduceTransparency](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityReduceTransparency),
  [ColorSchemeContrast](https://developer.apple.com/documentation/swiftui/colorschemecontrast),
  and [SwiftUI accessibility modifiers](https://developer.apple.com/documentation/SwiftUI/View-Accessibility).

## Verification

- `[x]` Automated coverage includes capture and migration, malformed preferences,
  retention expiry/Forever, deduplication, source application metadata, search modes,
  ignore rules, sorting, pin keys/editing, shortcut cycling, pointer selection, and Paste
  Stack ordering/interruption.
- `[x]` `swift test` passed 425 tests in 55 suites on 2026-07-24;
  the command also completed the debug build.
- `[x]` The 1,000/5,000-item cached search and pointer-selection cases remained below
  their 250 ms interaction ceilings; the 5,000-item encrypted database save/load/update
  test passed its 5-second initial and 2-second incremental ceilings.
- `[x]` Installed `/Applications/OpenFind.app` passed real GUI acceptance for centered
  clipboard-only shortcut presentation, visible/focused search, real IME input, source
  app identity, hover selection/preview, wheel scrolling without snap-back, click paste,
  Return paste, two-step Paste Stack use in TextEdit, `⌘K`/ellipsis action presentation,
  focus restoration after dismissal, first-shortcut recovery after app deactivation,
  ordered text merging, URL/file action routing, and native Quick Look.
- `[x]` The first accessibility-visible shortcut frame was centered at `720×500`; it
  remained `720×500` after 200 ms and 2 seconds, confirming that both panes are present
  synchronously rather than expanded by a hover timer. The default privacy catalog covers
  common password managers and Apple's password utilities through versioned, removal-safe
  migrations; exact re-search after QA cleanup found no test markers.
- `[x]` After opening and closing a primary OpenFind window, the clipboard shortcut
  produced exactly one opaque `720×500` panel at the visible-screen center, exposed an
  `AXTextField` as the focused element, kept the OpenFind process alive, and left no
  OpenFind icon in the Dock. The menu-bar Settings item also opened its window directly
  while the main window was closed.
- `[x]` `/Applications/OpenFind.app` and `dist/OpenFind.zip` both contain `x86_64 arm64`,
  pass deep strict signature verification, ZIP integrity and SHA-256 verification. The
  installed process, physical bundle, Spotlight, and LaunchServices all resolve only to
  `/Applications/OpenFind.app`.
