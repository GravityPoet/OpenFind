# OpenFind Native Utility Parity Matrix

This document is the acceptance contract for replacing three locally installed
utilities with native OpenFind modules. It is intentionally stricter than a
launcher integration: no external app bundle is embedded or required at runtime.

Status: `[ ]` planned, `[~]` implementation started, `[x]` verified parity.

## Reference Baseline

- Amphetamine 5.3.2 (`com.if.Amphetamine`), its installed scripting dictionary,
  localized UI resources, bundled scripts, and official App Store feature list.
- Maccy 2.6.1 (`org.p0deje.Maccy`), with MIT implementation patterns used only
  where attribution and license obligations are preserved.
- KeyboardCleanTool 7 (`com.hegenberg.KeyboardCleanTool`) behavior observed from
  the installed signed application; no third-party binary or artwork is copied.

Parity means equivalent user-visible capability and lifecycle behavior on the
supported macOS versions. It does not require copying branding, undocumented
implementation defects, or unsafe shell construction.

## Awake Sessions

- `[x]` Indefinite sessions.
- `[x]` Fixed-duration sessions, including custom durations.
- `[x]` Sessions ending at a specified date/time.
- `[x]` Sessions active while a selected application or background process is running.
- `[x]` Sessions active while a selected file is downloading or changing.
- `[x]` Per-session display-sleep policy with live override.
- `[x]` Per-session screen-saver policy, delay, and process exceptions.
- `[x]` Per-session closed-display policy is implemented and covered; a real privileged
  `pmset` transition was accepted on the installed Mac and restored transactionally.
- `[x]` Extend or replace an active session without assertion gaps; failed replacement
  leaves the previous session intact.
- `[x]` Default duration and monotonic-timer/system-clock end-time calculation, including
  clock-change rescheduling.
- `[x]` Start at launch, start after wake, and restart after power reconnection.
- `[x]` End non-Trigger sessions on forced sleep, fast-user switch, power disconnect,
  or low battery.
- `[x]` Optional low-battery prompt and AC-connected battery exemption.
- `[x]` Cursor movement after inactivity, stop threshold, and speed.
- `[x]` Screen lock after inactivity, close-lid lock, and locked-display policy.

The assertion core uses `IOPMAssertionCreateWithDescription`. A system assertion
is always acquired; a display assertion is added only when display sleep is not
allowed. Replacement is transactional: failure leaves the previous session in
force, and failed releases remain retryable.

## Triggers

Global behavior:

- `[x]` Bounded-by-persistence ordered triggers, global enable switch, and per-trigger switch.
- `[x]` Evaluate triggers top-to-bottom; first enabled trigger whose criteria are
  all true owns the trigger session.
- `[x]` At most one instance of each criterion type per trigger.
- `[x]` Live transition, 5-second correctness fallback, manual-session protection,
  deterministic trigger handoff, and selective native wake sources.
- `[x]` A manual end disables Triggers so a still-true criterion cannot silently restart.
- `[x]` Per-trigger display sleep, screen saver/delay/exceptions, and closed-display
  settings, independent from non-trigger defaults.

Criterion inventory from the installed Amphetamine 5.3.2 build:

1. `[x]` Schedule: selected weekdays and from/until times, including midnight spans.
2. `[x]` System Idle Time: less-than or greater-than a minute threshold.
3. `[x]` DNS Server: configured server-address matching.
4. `[x]` Wi-Fi Network: exact current SSID and lazy Location permission; the installed
   app received the Location decision and displayed the live criterion without exposing
   the SSID in logs or acceptance output.
5. `[x]` IP Matching: exact IPv4/IPv6 value or inclusive value range.
6. `[~]` Cisco AnyConnect VPN: active configured/dynamic service matching is implemented;
   the current Mac's active network-extension VPN signal passed the live production
   snapshot/evaluator/session chain, while a Cisco-specific tunnel remains unavailable.
7. `[x]` Volumes/Drives: selected local or network volume mounted.
8. `[x]` Application: app/process running, optionally requiring it to be frontmost.
9. `[x]` CPU Utilization: less-than or greater-than a percentage threshold.
10. `[~]` Displays: count `<`, `=`, or `>`; main-display mirroring; optional built-in-display
    exclusion; multi-display/mirroring hardware acceptance remains open. The mirror check
    now follows Amphetamine's `CGMainDisplayID()` semantics instead of treating any
    secondary mirror member as the main display.
11. `[x]` Bluetooth Device: paired-device connection matching plus native wake callbacks;
    a real radio off/on cycle reevaluated in the same installed process without a crash.
12. `[x]` Audio Output: selected route, built-in output/speakers, or wired headphones;
    the live default route was switched, observed, and restored.
13. `[~]` USB Device: selected device connection matching is implemented; hot-plug
    hardware acceptance remains open.
14. `[~]` Battery & Power Adapter: minimum charge plus connected/disconnected AC
    requirements with the original AND/OR combinations.

Trigger evaluators must be event-driven where macOS exposes notifications. Slow
or polling-only signals use bounded, suspendable monitors and never log SSIDs,
device names, process names, IP addresses, DNS addresses, or paths as payloads.

## Closed-Display Mode

- `[x]` Detect portable support, physical clamshell state, and current `SleepDisabled` state.
- `[x]` Save the exact pre-session state before any change.
- `[x]` Apply `pmset -a disablesleep 1` only for a session that requests it (the
  privileged write path is fixed-command `osascript`, not user-interpolated shell);
  the installed-app P1 run observed `SleepDisabled=1` during the session.
- `[x]` Restore the saved state on session end, configuration change, normal quit,
  crash recovery, next launch reconciliation, and power-source changes; the P1 run
  restored `SleepDisabled=0` and removed the recovery journal.
- `[x]` Optional validated `/etc/sudoers.d` rule for passwordless session toggles was
  installed, exercised, and removed again; the pre-existing Amphetamine rule was left
  untouched.
- `[x]` Atomic install, `visudo -cf` validation, exact command/content allowlist,
  root:wheel/0440 validation, uninstall, and rollback are covered; the P1 run verified
  the install and clean uninstall paths.
- `[~]` Real-lid warning tone, repeat interval, temporary-volume restoration, and
  ordinary powered-clamshell suppression are implemented; audible/hardware acceptance
  remains open.

This is a P1 system-power change. OpenFind will not use Amphetamine's direct
`touch`/append/move AppleScript sequence; it will use a separately auditable helper
transaction and preserve the user's original power policy.

## Drive Alive

- `[x]` Global enable switch and configurable write interval (10 seconds default).
- `[x]` Multiple user-selected local, removable, or network volumes/folders.
- `[x]` Per-target “session only” versus “while OpenFind is running” policy.
- `[x]` Repeatedly overwrite one bounded payload instead of growing files.
- `[x]` Security-scoped bookmark persistence with stale-bookmark refresh.
- `[x]` Disconnect timeout/cancellation so unavailable network volumes cannot hang UI.
- `[x]` Permission/read-only diagnostics, conflict-safe cleanup, and target removal even
  when a volume is disconnected.
- `[x]` Per-target names, policies, and health in settings/menu without full paths in logs.

## Automation, Menu Bar, and Notifications

- `[x]` Independent configurable hotkeys cover all six Amphetamine actions: start,
  end, start/end, open menu, toggle display sleep, and toggle screen saver. OpenFind
  additionally exposes a closed-display sleep toggle. Duplicate/conflicting
  registrations are rejected atomically; a live `Control-Option-M` acceptance opened
  the installed app's native menu from Chrome without Accessibility or admin access.
- `[x]` The 21-command Amphetamine-compatible AppleScript dictionary covers session
  state/start/end/time, display sleep, screen saver, closed-display mode, Triggers, and
  Drive Alive. Standard Suite properties, all read-only custom queries, both no-option
  and user-record `start new session` forms, end, preference toggles, and `quit` are
  verified against the installed app. The `optn` field is intentionally declared as
  `any` in the SDEF because macOS 27's Cocoa validator rejects a Swift `record` command
  before dispatch; the handler parses the raw record descriptor and preserves the
  Amphetamine wire format. The installed-app P1 run also exercised the privileged
  closed-display transition through a real bounded session.
- `[x]` Quick settings, current-session details, transactional extension, persistent
  ring-and-dot icon, remaining/end-time formats, 12/24-hour clock, and optional seconds.
- `[x]` Start/end/replacement sounds, reminders, automatic-session notifications,
  closed-display warnings, and cleanup are implemented. Apple-team builds use
  `UNUserNotificationCenter`; the self-signed customer build uses OpenFind's own
  permissionless, nonactivating banner. A real automatic-end banner was visually
  accepted and disappeared after its bounded display interval.
- `[x]` Launch at login uses `SMAppService` when macOS exposes the main-app service and
  an atomic user LaunchAgent fallback when the customer-signed build reports `notFound`.
  The installed toggle, exact create/remove lifecycle, bootstrap, and relaunch from
  `/Applications/OpenFind.app` passed. The final preference is off with no job or plist.
- `[x]` OpenFind's stable 18-point template icon uses a persistent ring-and-dot mark and
  optional time text. Normal and highlighted menu-bar states were accepted visually;
  arbitrary custom artwork is intentionally not copied from Amphetamine.
- `[x]` Opt-in local aggregate statistics, live totals/average, persistence, and reset.
  OpenFind has no persistent “do not show again” flags, so a dialog-reset control would
  be a no-op and is intentionally omitted.

## Clipboard (Maccy-equivalent)

- `[x]` Local `NSPasteboard` history for text, rich text, URLs, files, and images.
- `[x]` Search, keyboard navigation, preview, copy, optional automatic paste, delete,
  clear, pin, ordering, duplicate handling, and bounded retention.
- `[x]` Ignore rules for transient/concealed/password-manager data and selected apps.
- `[x]` Configurable size/history limits, paste-without-formatting, and menu-bar access.
- `[x]` AES-GCM history persistence keeps Apple-team build keys in Keychain and local
  self-signed build keys in an owner-only `0600` file. Legacy ciphertext is never
  overwritten before authenticated migration; symlink, ownership, size, and mode checks
  are covered. Payloads remain local and never enter logs, analytics, or sync.
- `[~]` This Mac's 1,019,072-byte legacy ciphertext is preserved byte-for-byte and no
  longer opens Keychain during startup. Its one-time decryption migration still requires
  the user to click `解锁并迁移历史` and authorize the old Keychain item once.
- `[x]` Migration/import is optional; OpenFind does not read Maccy's database silently.

## Keyboard Cleaning (KeyboardCleanTool-equivalent)

- `[~]` Accessibility-gated `CGEventTap` suppresses ordinary keys, modifiers, media keys,
  and supported system-defined keyboard events; live acceptance requires the user's
  Accessibility decision.
- `[~]` Pointer-only unlock control, explicit countdown, elapsed state, and emergency timer
  are covered; live event-tap acceptance remains open.
- `[~]` Event-tap timeout recovery and automatic cleanup on quit, crash, screen lock,
  fast-user switch, and sleep/wake are covered; lifecycle hardware acceptance remains open.
- `[x]` The UI states that hardware power and Touch ID controls are not exposed by macOS.

## Verification Record (2026-07-21)

- `349 tests / 43 suites` passed in the latest serial run; earlier targeted and full-suite
  runs also passed after hardening native callback lifetimes and encrypted-key migration.
- Customer-signed Universal (`arm64` + `x86_64`) archive passed deep signature, SDEF,
  packaged smoke, checksum, and atomic `/Applications/OpenFind.app` installation checks.
- Physical bundle, Spotlight, LaunchServices, and Dock checks resolve only to
  `/Applications/OpenFind.app`; standard AppleScript returns `OpenFind|1.1.0`, and the
  real AppleScript `quit` event exits the installed process within the bounded window.
- Main window and native Settings scene were opened through Accessibility automation;
  cold-start indexing was observed separately from the steady-state menu-bar process.
- The installed customer build originally exposed `SMAppService.mainApp.status ==
  notFound` as a disabled launch-at-login control. After the fallback fix, the same real
  Settings control was enabled; toggling it on wrote a `plutil`-valid, fixed-command
  LaunchAgent for `/Applications/OpenFind.app`, and toggling it off removed the file.
  The user's final preference remains off and no launch-item residue remains.
- The P1 power acceptance recorded the original `SleepDisabled=0`, installed the exact
  OpenFind rule (`root:wheel`, mode `0440`, `visudo`-valid), observed `SleepDisabled=1`
  during an OpenFind bounded session, restored `SleepDisabled=0` with the journal
  removed, and then removed the OpenFind rule. The pre-existing
  `/private/etc/sudoers.d/amphetamine_PowerProtect` rule remained unchanged.
- Real Location, Bluetooth, and audio-route acceptance is recorded above. No USB device
  was available and no Accessibility decision was made; those rows remain `[~]`.
- The opt-in privacy-safe live Trigger acceptance used production signal collectors and
  evaluators, then crossed `TriggerCoordinator` into an isolated awake-session lifecycle.
  Twelve currently observable kinds passed: schedule, idle, DNS, IP, active VPN service,
  volume, application, CPU, display count, Bluetooth, audio output, and battery/adapter.
  Wi-Fi SSID (Location decision absent) and USB (no connected device) were reported as
  unavailable without printing identifiers or changing system state.
- The installed menu-bar item now keeps one persistent center dot inside the OpenFind ring.
  The monochrome template renders as the user-approved white ring/white dot on the current
  menu bar and remains system-adaptive across appearance and highlighted states.
- The local Amphetamine 5.3.2 bundle confirms six configurable hot-key actions,
  including `Open Menu`. OpenFind now exposes all six, and the installed Universal app
  passed a real global-hot-key-to-native-menu screenshot acceptance with temporary
  preferences restored afterward.
- A prior test-helper `SIGBUS` was traced to an unretained IOKit power-source callback;
  the current implementation uses a retained, invalidated registration and the repeated
  regression runs above are the acceptance evidence for that fix.
- Network-configuration and USB hot-plug wake callbacks now use the same retained,
  invalidated, weak-monitor context pattern; the full suite passed again after this
  lifecycle hardening.
- Dedicated restart/stop regression tests cover both native network and USB wake
  monitors (32 cycles plus idempotent stop) without requiring hardware or privilege.
- A termination regression test proves that an in-flight index rebuild is cancelled before
  the application waits for durable persistence.
- The display Trigger snapshot now checks only `CGMainDisplayID()` for the mirroring
  criterion; the installed-app snapshot test compares that result with CoreGraphics.
- Startup closed-display journal recovery no longer strands non-privileged Trigger and
  Drive Alive services when a privileged reconciliation fails. Automatic launch is held
  back until recovery succeeds, while ordinary Trigger evaluation remains available.
- The installed customer binary now resolves Cocoa scripting through a weak process-local
  delegate reference; fresh `osascript` queries return the Amphetamine sentinels instead
  of the previous “AppleScript service unavailable” error.
- Raw Apple Event `optn` records (integer/string and built-in numeric minute/hour forms)
  now start bounded and indefinite sessions, return the expected remaining-time values,
  and end cleanly; script-ending a Trigger session preserves Triggers as in Amphetamine.
- Standard `quit` is routed through `OpenFindQuitScriptCommand` instead of a raw launch-time
  Apple Event handler. This survives Cocoa Scripting's lazy dispatcher installation: the
  installed app completed the full custom-query/start/end/toggle sequence, then accepted
  `quit` while background indexing was active and exited after its bounded persistence
  window. Termination also cancels rebuild, watcher, retry, and content-enrichment work
  before flushing durable index state.
- The current source was rebuilt into a fresh customer archive and atomically installed;
  both cold-index and steady-state processes remained responsive, with no OpenFind-owned
  power assertion after every scripted session ended.
- Bluetooth callbacks now hop from IOBluetooth's queue to the main actor before touching
  observable state; the installed process survived a real radio off/on cycle with no new
  crash report and the temporary trigger was removed.
- The search-target selector is a native custom segmented control whose selected fill
  reaches both rounded outer edges. Name, content, and combined states were accepted in
  the installed app; the user's final selection remains `名称或内容`.
- A real one-minute installed-app session returned `false` after deadline expiry and left
  no OpenFind assertion. Timed IOPM assertions that powerd already released are now
  normalized from `kIOReturnBadArgument` to an idempotent release result.
- Modern notification authorization rejects the self-signed customer identity. The
  installed build therefore used a local level-25 OpenFind banner for a real automatic
  session end; it showed the localized title/body and close control without stealing focus.
- Two clean installed-app relaunches completed without an OpenFind Keychain dialog while
  retaining the legacy clipboard ciphertext SHA-256
  `8c03f45357fae81c6693002ba5547544d0dc849e0126765085169aa52099d609`.
- Final read-only state reports portable model `Mac16,1`, `SleepDisabled=0`, no
  `/private/etc/sudoers.d/openfind-power-protect` rule, no OpenFind-owned power
  assertion, and the pre-existing Amphetamine PowerProtect rule still present.

## Completion Gate

No row becomes `[x]` until it has unit or integration coverage plus a fresh product
build. Hardware- or permission-dependent rows also require a real-app acceptance
record. Final completion additionally requires Universal architecture, signing,
installed-app uniqueness, permissions continuity, localization, and rollback checks.
