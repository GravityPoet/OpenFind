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
- `[~]` Per-session closed-display policy is implemented and covered; a real privileged
  `pmset` transition remains an explicit user-run acceptance step.
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
4. `[~]` Wi-Fi Network: exact current SSID and lazy Location permission are implemented;
   live acceptance requires the user's Location decision.
5. `[x]` IP Address: exact IPv4/IPv6 address or inclusive address range.
6. `[~]` Cisco AnyConnect VPN: active configured/dynamic service matching is implemented;
   no active Cisco tunnel was available for live acceptance.
7. `[x]` Volumes/Drives: selected local or network volume mounted.
8. `[x]` Application: app/process running, optionally requiring it to be frontmost.
9. `[x]` CPU Utilization: less-than or greater-than a percentage threshold.
10. `[~]` Displays: count `<`, `=`, or `>`; mirroring; optional built-in-display exclusion;
    multi-display/mirroring hardware acceptance remains open.
11. `[~]` Bluetooth Device: paired-device connection matching is implemented; live
    Bluetooth hardware acceptance remains open.
12. `[~]` Audio Output: selected route, built-in output/speakers, or wired headphones;
    route-change hardware acceptance remains open.
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
- `[~]` Apply `pmset -a disablesleep 1` only for a session that requests it (the
  privileged write path is fixed-command `osascript`, not user-interpolated shell);
  the real write remains an explicit P1 acceptance step.
- `[~]` Restore the saved state on session end, configuration change, normal quit,
  crash recovery, next launch reconciliation, and power-source changes; real privileged
  restoration acceptance remains open.
- `[~]` Optional validated `/etc/sudoers.d` rule for passwordless session toggles is
  implemented but intentionally not installed during unattended verification.
- `[~]` Atomic install, `visudo -cf` validation, exact command/content allowlist,
  root:wheel/0440 validation, uninstall, and rollback are covered; privileged install
  and uninstall remain explicit P1 acceptance steps.
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

- `[~]` Independent configurable hotkeys: start, end, start/end, menu, display sleep,
  and screen saver; duplicate/conflicting registrations are rejected atomically, while
  live global registration remains permission/environment dependent.
- `[~]` The 21-command Amphetamine-compatible AppleScript dictionary covers session
  state/start/end/time, display sleep, screen saver, closed-display mode, Triggers, and
  Drive Alive. Standard Suite properties and `quit` are verified; external custom events
  are blocked in the current macOS Apple Events environment for both OpenFind and
  Amphetamine 5.3.2.
- `[x]` Quick settings, current-session details, transactional extension, active/inactive
  icon state, remaining/end-time formats, 12/24-hour clock, and optional seconds.
- `[~]` Start/end/replacement sounds, reminders, automatic-session notifications,
  closed-display warnings, and cleanup are implemented; notification authorization and
  audible acceptance remain open.
- `[~]` Launch at login uses `SMAppService`; enabling it remains a user-controlled action.
- `[~]` OpenFind's template icon has active/inactive states and optional time text;
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
- `[x]` AES-GCM history persistence uses a device-only Keychain key; payloads remain local
  and never enter logs, analytics, crash breadcrumbs, or sync.
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

## Verification Record (2026-07-20)

- `329 tests / 41 suites` passed; three consecutive full-suite runs also passed after
  hardening the IOKit power-source callback lifetime.
- Customer-signed Universal (`arm64` + `x86_64`) archive passed deep signature, SDEF,
  packaged smoke, checksum, and atomic `/Applications/OpenFind.app` installation checks.
- Physical bundle, Spotlight, LaunchServices, and Dock checks resolve only to
  `/Applications/OpenFind.app`; standard AppleScript returns `OpenFind|1.1.0`, and the
  real AppleScript `quit` event exits the installed process within the bounded window.
- Main window and native Settings scene were opened through Accessibility automation;
  cold-start indexing was observed separately from the steady-state menu-bar process.
- No `pmset` write, Power Protect install/uninstall, sudoers change, Bluetooth/USB/audio
  device mutation, Location authorization, or Accessibility authorization was performed.
  Those hardware/permission rows remain `[~]` by design.
- A prior test-helper `SIGBUS` was traced to an unretained IOKit power-source callback;
  the current implementation uses a retained, invalidated registration and the repeated
  regression runs above are the acceptance evidence for that fix.
- Network-configuration and USB hot-plug wake callbacks now use the same retained,
  invalidated, weak-monitor context pattern; the full suite passed again after this
  lifecycle hardening.
- Commit `10930ec` was rebuilt into a fresh customer archive and atomically installed;
  the new installed process reached steady state after the expected cold index pass
  (about 2m43s) and then remained responsive at about 0.9% CPU, with no OpenFind-owned
  power assertion.

## Completion Gate

No row becomes `[x]` until it has unit or integration coverage plus a fresh product
build. Hardware- or permission-dependent rows also require a real-app acceptance
record. Final completion additionally requires Universal architecture, signing,
installed-app uniqueness, permissions continuity, localization, and rollback checks.
