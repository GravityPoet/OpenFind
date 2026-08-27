# OpenFind Release SOP

This is the canonical release runbook for OpenFind. `RELEASING.md` is only a
compatibility entry point and must not contain an independent procedure.

## Release contract

- Repository: `GravityPoet/OpenFind`
- Default and release branch: `main`
- Public version format: semantic tags such as `v1.1.2`
- Product version source: the tag without the leading `v`
- Build number: `major * 1_000_000 + minor * 1_000 + patch`
- Supported platform: macOS 14 or later, Apple silicon and Intel
- Bundle identifier: `com.openfind.app`
- Distribution: GitHub Release with Sparkle appcast
- Signing identity: `OpenFind Customer Code Signing`
- Expected certificate SHA-1:
  `3E146B469F41DEB31E45C28D0E9C512B3E5A41C1`
- Expected designated requirement:
  `identifier "com.openfind.app" and certificate leaf = H"3e146b469f41deb31e45c28d0e9c512b3e5a41c1"`

The customer certificate is intentionally self-signed. OpenFind is not Apple
notarized, so every public Release body must lead with a direct recommended ZIP
download and contain complete English and Chinese sections for:

1. **Downloads / 下载资源**
2. **What's New / 更新亮点**
3. **macOS First Launch / macOS 首次启动**

The first-launch section must tell customers to double-click the ZIP, drag
`OpenFind.app` to Applications, open it from Finder → Applications, and—only
when macOS blocks that launch—use **System Settings → Privacy & Security → Open
Anyway**, then confirm **Open**. It must also explain that **Open Anyway**
appears only after one blocked launch attempt and is normally needed once.
Checksum and appcast files remain release-verification and automatic-update
assets; do not present them as normal customer download steps.

## Required GitHub Actions secrets

Check names only; never print or read secret values.

- `OPENFIND_CUSTOMER_CERT_BASE64`
- `OPENFIND_CUSTOMER_CERT_PASSWORD`
- `RELEASE_KEYCHAIN_PASSWORD`
- `SPARKLE_PRIVATE_ED_KEY`
- `SPARKLE_PUBLIC_ED_KEY`

## [A] Release procedure

Run every command from the repository root.

1. Preflight and collision checks:

   ```bash
   git status --short --branch
   git remote -v
   gh auth status
   gh secret list
   git fetch origin --prune --tags
   git ls-remote --tags origin "refs/tags/${TAG}" "refs/tags/${TAG}^{}"
   gh release view "${TAG}"
   ```

   The worktree must contain only the intended release changes. The local and
   remote tag checks and `gh release view` must all prove that the target tag is
   unused.

2. Resolve dependencies and run the release-quality gates:

   ```bash
   swift package resolve
   bash Scripts/test.sh
   OPENFIND_RUN_DRIVE_ALIVE_INTEGRATION=1 \
     bash Scripts/test.sh --filter DriveAliveIntegrationTests
   OPENFIND_RUN_VISUAL_REGRESSION=1 \
     bash Scripts/test.sh --filter VisualRegressionTests
   FILES=8000 BODY_KB=16 COPIES=4 bash Scripts/benchmark_content_index.sh
   FILES=600 MATCH_EVERY=60 bash Scripts/benchmark_index.sh
   NODES=250000 bash Scripts/benchmark_name_index.sh
   ```

3. Build the exact customer artifact. For the current `v1.1.2` target, use:

   ```bash
   APP_VERSION=1.1.2 BUILD_NUMBER=1001002 \
     bash Scripts/build_customer_app.sh
   ```

4. Verify the local artifact before commit/tag:

   ```bash
   (cd dist && shasum -a 256 -c OpenFind.zip.sha256)
   RELEASE_VERIFY_DIR="$(mktemp -d)"
   ditto -x -k dist/OpenFind.zip "$RELEASE_VERIFY_DIR"
   codesign --verify --deep --strict --verbose=2 \
     "$RELEASE_VERIFY_DIR/OpenFind.app"
   codesign -d -r- "$RELEASE_VERIFY_DIR/OpenFind.app"
   lipo -archs \
     "$RELEASE_VERIFY_DIR/OpenFind.app/Contents/MacOS/OpenFind"
   defaults read \
     "$RELEASE_VERIFY_DIR/OpenFind.app/Contents/Info" CFBundleShortVersionString
   defaults read \
     "$RELEASE_VERIFY_DIR/OpenFind.app/Contents/Info" CFBundleVersion
   ```

   The temporary directory is disposable after the recorded checks pass.

5. Install and verify the packaged app:

   ```bash
   bash Scripts/install_local_app.sh dist/OpenFind.zip
   ```

   Confirm one physical `/Applications/OpenFind.app`, one LaunchServices entry,
   one Dock bundle/path, the expected signature, both architectures, and a
   successful packaged CLI smoke search.

6. Commit the release state, push `main`, and wait for CI on the exact pushed
   commit:

   ```bash
   git status --short --branch
   git add <intended-files>
   git commit -m "release: prepare v1.1.2"
   git push origin main
   RELEASE_SHA="$(git rev-parse HEAD)"
   gh run list --workflow ci.yml --commit "${RELEASE_SHA}" --limit 1
   gh run watch <run-id> --exit-status
   ```

7. Re-run the tag and release collision checks, then create and push the
   annotated tag:

   ```bash
   git ls-remote --tags origin "refs/tags/${TAG}" "refs/tags/${TAG}^{}"
   gh release view "${TAG}"
   git tag -a "${TAG}" -m "OpenFind ${TAG}"
   git push origin "${TAG}"
   ```

   `.github/workflows/release.yml` owns the public GitHub Release, signed
   Sparkle appcast, ZIP, and checksums. Wait for that workflow to finish on the
   exact tag SHA before uploading the demo video.

8. If reviewed, version-appropriate source footage is available, build and
   verify the optional 60-second demo, then upload it without overwriting
   existing assets. Otherwise omit the optional demo asset; never reuse a
   video whose visible version does not match the Release:

   ```bash
   bash Scripts/build_release_demo.sh \
     <welcome.mov> \
     <typing.mov> \
     <results.mov> \
     <settings.mov>
   ffmpeg -hide_banner -i docs/assets/OpenFind-60s-demo.mp4 \
     -vf "freezedetect=n=-50dB:d=1.5" \
     -an -f null -
   gh release upload "${TAG}" \
     docs/assets/OpenFind-60s-demo.mp4
   ```

   The video must probe as H.264, exactly 60 seconds, 1920×1080, and 30 fps.
   Freeze detection must not report a span of 1.5 seconds or longer. If a
   published presentation-only video needs replacement after this gate passes,
   preserve its digest for rollback, then use the same upload command with
   `--clobber` and verify a clean public download against the new local digest.

   Keep product screenshots in `docs/assets/` and present them inline from the
   README, documentation, or Release body. Do not upload screenshots as
   downloadable Release assets.

## [B] Acceptance

The release is complete only when all of these checks pass:

- `main`, the annotated tag, the CI run, and the release workflow all resolve to
  the intended release commit.
- `dist/OpenFind.zip.sha256` verifies.
- The archive contains exactly one app, and the app has the expected identifier,
  version, build number, customer signature, and `arm64 x86_64` executable.
- Tests, visual regression, all three performance gates, packaged CLI smoke,
  local installation, and launch pass.
- The public release is not a draft or prerelease and exposes the ZIP,
  checksum, signed appcast, optional demo video, and generated notes without
  downloadable screenshot assets.
- The public Release body contains the direct ZIP link plus complete English
  and Chinese download, customer-value, and first-launch instructions,
  including the blocked-launch prerequisite for **Open Anyway**.
- A clean temporary download of every public asset succeeds and verifies
  against its published checksum where applicable.
- `appcast.xml` points at the public ZIP and contains the expected Sparkle
  signature and version.

## [C] Fuses

Stop external writes and return to diagnosis if any of these occurs:

- The target tag or release already exists.
- The worktree contains unrelated or unexplained changes.
- The customer certificate is missing or its SHA-1/designated requirement
  differs.
- Any quality gate, packaged smoke test, signature, architecture, version,
  checksum, exact-SHA CI, or public-download check fails.
- The release workflow does not publish from the intended tag commit.
- A rollback path cannot be stated before publication.

Do not weaken a quality gate to make a release pass. Fix the product or the
release automation, then repeat the failed gate and its dependent checks.

## [D] Rollback and recovery

Sparkle refuses lower build numbers, so customer rollback is forward-only.

1. Convert a bad GitHub Release to draft to stop new discovery.
2. Do not move or reuse the published tag.
3. Fix the issue on `main`.
4. Release a higher patch version and build number.
5. Verify that the new appcast makes the corrected version the newest item.

The appcast keeps three releases and full ZIP archives only. Local install
rollback is handled by `Scripts/install_local_app.sh`, which restores the
previous `/Applications/OpenFind.app` if replacement or verification fails.

## Failure ledger

Record release-specific command failures, incorrect assumptions, and detours
here when they reveal a reusable project lesson. Include the failed command,
cause, correction, and prevention.

| Date | Failed step | Cause | Correction | Prevention |
| --- | --- | --- | --- | --- |
| 2026-07-24 | Add the canonical SOP and demote `RELEASING.md` in one patch | The patch used stale `RELEASING.md` text instead of re-reading the current worktree | Re-read the file and apply the canonical SOP and compatibility pointer against current content | Refresh mutable release files immediately before context-sensitive patches |
| 2026-07-24 | Compile the first visual regression test | `NSColor` channel values are `CGFloat`, but the snapshot accumulator was `Double` | Convert each channel difference explicitly to `Double` before reduction | Compile new AppKit image-comparison helpers with a focused test before generating baselines |
| 2026-07-24 | Run the full `swift test` gate after adding visual regression | The visual suite performed slow per-pixel `NSColor` conversion while the entire suite was main-actor isolated, starving unrelated timer and async UI tests and producing secondary failures | Convert snapshots to RGBA buffers and keep only SwiftUI rendering on the main actor; run byte comparison off actor, then repeat failed tests and the complete gate | Snapshot rendering may use the main actor, but image comparison must not; validate new visual gates concurrently with timer tests |
| 2026-07-24 | Summarize a captured full-test log in zsh | The wrapper assigned to zsh's read-only special variable `status` | Read the already captured log separately and use a task-specific variable for later wrappers | Never use common shell status/options names for task variables |
| 2026-07-24 | Re-run the full gate after switching to RGBA comparison | The suite itself was still annotated `@MainActor`, so the faster comparison still blocked timer tests under full-suite contention | Remove suite-wide isolation and isolate only the SwiftUI render function | Actor isolation must be scoped to the smallest operation that actually requires it |
| 2026-07-24 | Compose the 60-second demo from three native screenshots | The source PNGs carried different sample-aspect-ratio metadata, so FFmpeg refused to concatenate otherwise identical 1920×1080 streams | Normalize every scene with `setsar=1` before concatenation; the finished file probes as exactly 60 seconds | Normalize geometry and sample aspect ratio before multi-source video concatenation |
| 2026-07-24 | Validate the customer-facing checksum command while writing download instructions | `build_app.sh` wrote the builder's absolute archive path into `OpenFind.zip.sha256`, which cannot verify after download | Emit only the basename in ZIP and appcast checksum files and verify from the asset directory | Public checksum manifests must be relocatable and tested from a clean download directory |
| 2026-07-24 | Review the new canonical SOP against repository scripts | The draft SOP used non-existent benchmark wrapper names rather than the actual workflow-owned scripts | Replace the three commands with `benchmark_content_index.sh`, `benchmark_index.sh`, and `benchmark_name_index.sh` | Cross-check every release command against executable repository paths before publication |
| 2026-07-24 | Run clean-directory artifact verification with an automatic `rm -rf` trap | The execution harness rejects `rm -rf`-style commands even when the target is a freshly resolved temporary directory | Re-run the unchanged verification in a new system temp directory without a destructive cleanup hook | Keep release evidence wrappers read-only under restricted harnesses; temp cleanup must not block artifact verification |
| 2026-07-24 | Repeat the complete test gate after reducing snapshots to 1× | Snapshot CPU time fell below 0.5 seconds, but AppKit rendering still queued on the same process `MainActor`; under 62-suite concurrency, unrelated one-second activity tests could time out before their actor work ran | Keep the 1× baselines and run visual regression as an explicit, isolated CI/Release step controlled by `OPENFIND_RUN_VISUAL_REGRESSION=1` | GUI snapshot gates must be automated but isolated from timing-sensitive main-actor unit suites |
| 2026-07-24 | Exact-SHA CI run `30081767829` | Swift Testing's default same-process parallel execution overloaded the hosted runner: a 50 ms process timeout took 2.09 seconds and several main-actor timers reached roughly four seconds, causing 18 secondary issues while the visual suite was correctly skipped | Run the full unit gate with explicit `swift test --no-parallel`, then run visual regression as its own blocking step | Use explicit global serialization for this timing-heavy integration suite on shared CI runners; do not relax individual deadlines to mask scheduler contention |
| 2026-07-24 | First local `swift test --no-parallel --skip-build` | `AppLaunchContextTests` implicitly relied on another parallel test to initialize the global `NSApplication`; serial order exposed an `NSApp` nil unwrap | Initialize and retain `NSApplication.shared` inside the test before inspecting windows | Tests must create their own process-global AppKit prerequisites instead of relying on incidental parallel execution order |
| 2026-07-24 | Exact-SHA CI run `30082103127` | All three Drive Alive writer checks hit their two-second deadline on the hosted runner before the low-priority file-system work completed; the same three checks passed locally, and serialization removed every unrelated failure | First attempt: use one explicit ten-second Drive Alive deadline in the writer, controller, and semantic tests; the next exact run proved that elapsed time was not the root cause | Do not treat a larger integration-test deadline as a completed fix until the exact hosted environment passes |
| 2026-07-24 | Exact-SHA CI run `30083105936` | The first Drive Alive semantic fixture remained blocked for ten seconds, and the following conflict fixtures plus a later content-index check also failed | First attempt: inject the real `fsync` boundary while preserving the production queue; the next exact run proved the queue itself never received execution time | Isolate both blocking OS calls and their scheduler when a semantic test does not intend to benchmark shared-runner scheduling |
| 2026-07-24 | Exact-SHA CI run `30083811270` | All four Drive Alive checks timed out, including an injected sync function that returns immediately; this proved the shared-process `.utility` queue was starved before any file operation began | Inject an inline scheduler for semantic tests and add a separately gated fresh-process integration test that exercises the real production queue and `fsync` | Keep deterministic semantics and production scheduling as separate blocking gates; never infer syscall latency when an immediate injected operation also times out |
| 2026-07-24 | Tag-triggered Release run `30085637699` | The certificate step left a `security` process without progress for more than six minutes; the run was canceled before any Release or asset was published | Remove user Trust Settings mutation, import the PKCS#12 private key directly, restrict partition updates to signing keys, verify the pinned fingerprint with OpenSSL, and add a bounded existing-tag recovery dispatch | Certificate automation must be non-interactive and time-bounded; recover an unpublished immutable tag by checking it out explicitly rather than moving or recreating it |
| 2026-07-24 | Existing-tag recovery Release run `30086650406` | The PKCS#12 certificate and private key imported non-interactively, but the untrusted self-signed identity was excluded by the code-signing policy and the product builder rejected it | On the ephemeral hosted runner, add the already fingerprint-pinned certificate to Admin Trust with non-interactive root execution, then require the exact identity fingerprint to pass the code-signing policy before building | Replacing interactive user trust must preserve code-signing policy validity; validate both certificate contents and the usable identity |
| 2026-07-25 | Inspect the welcome window with `set rows to {}` in AppleScript | `rows` resolved to an accessibility property instead of a local accumulator | Rename the accumulator to `outputRows` and keep it outside the window scope | Avoid UI terminology for AppleScript accumulator names |
| 2026-07-25 | Set `text field 1 of window "OpenFind"` while recording search | The field is nested inside the window's root group, so the direct accessibility index was invalid (`-1719`) | Raise the window and target `text field 1 of group 1` through Accessibility | Inspect the live accessibility hierarchy before scripting a release capture |
| 2026-07-25 | Quit OpenFind through an unbounded AppleScript command before capture | The app did not finish the scripted quit and the capture workflow stopped making progress | Terminate the disposable capture process with a bounded signal, then relaunch it | Never use an unbounded application-quit step in release capture automation |
| 2026-07-25 | Type the search demo query through synthetic keystrokes | The active Chinese input method converted the query into repeated composition characters | Set the accessibility text-field value prefix by prefix to preserve visible incremental search | Release capture automation must not depend on the operator's active input source |
| 2026-07-25 | Capture the complete screen for a product demo | The frame included an unrelated app error and a phone notification outside OpenFind | Capture the OpenFind window by window ID and inspect representative frames before editing | Public product footage must be window-targeted, not full-screen |
| 2026-07-25 | Accept the first 60-second demo after checking only duration and dimensions | Freeze analysis later found three 18.83-second static spans, so customers could mistake the demo for a still image | Rebuild with real interactions, continuous screenshot motion, and a 1.5-second freeze gate | Presentation media is releasable only after both technical probing and motion regression checks pass |
| 2026-07-25 | Validate the first real-interaction demo encode | The script expected stream metadata and format duration on one CSV row, but `ffprobe` emits them as separate sections | Query the video stream and format duration independently, then compare each exact value | Keep `ffprobe` acceptance checks section-specific instead of depending on multi-section output formatting |
| 2026-07-25 | Run the freeze gate on the first real-interaction cut | Window-only capture omitted pointer movement, leaving several visually static spans while the operator moved between controls | Add restrained continuous camera movement to every captured scene and strengthen the outro motion | Real interaction footage must still pass pixel-level motion analysis; pointer activity alone is not visible proof |
| 2026-08-24 | Assert the packaged CLI smoke result | OpenFind emits canonical absolute paths, while the first check expected a relative path; a temporary-directory template also preserved a trailing slash that differed from the CLI's normalized path | Normalize the temporary root with `pwd -P` and assert the returned marker filename plus the result-count contract | Release smoke checks must compare canonical paths or stable basenames and must not assume the caller's relative-path spelling |
| 2026-08-27 | Plan the optional `v1.1.2` demo upload | The only tracked 60-second video visibly identifies `v1.1.0`, and its four source recordings are not retained; the procedure sounded mandatory while acceptance correctly described the demo as optional | Make the demo step conditional and omit the mismatched video from `v1.1.2` | Inspect the visible version before every upload and never reuse presentation media whose version does not match the Release |
| 2026-08-27 | Update the shared release failure ledger | `apply_patch verification failed` because the initial context omitted the final table column and did not match the exact source row | Re-read the numbered source line and apply the complete row context | Inspect the exact ledger row before patching long Markdown tables |
| 2026-08-27 | Clean the temporary demo inspection frame | The execution harness rejected `/bin/rm -f` with `rm -f style commands are not permitted` even though the path was a disposable file created by this run | Use `/bin/unlink` on the exact temporary file path | Prefer the approved single-file unlink operation for temporary release evidence and avoid `rm` wrappers |
| 2026-08-27 | Poll the completed customer build session | `write_stdin failed: Unknown process id` after the prior poll had already returned the successful build and archive output | Treat the completed output as terminal and continue with artifact verification | Check the session result before issuing another poll and do not interpret a closed session as a build failure |
| 2026-08-27 | Wrap the redirected CI watcher in zsh | The wrapper assigned the exit code to zsh's read-only special variable `status`, so the watcher was not started and zsh exited before tailing its log | Use a task-specific variable such as `watch_exit_code` and query the run directly when a watcher is unnecessary | Avoid zsh special-variable names (`status`, `pipestatus`, and `path`) for release wrapper variables |
| 2026-08-27 | Exact-SHA CI run `33021059075` | Hosted macOS scheduling starved several short MainActor timer assertions (six issues across authorization/panel tests), then the temporary `HOME` cleanup encountered a mounted read-only Metal toolchain | Reproduce locally, replace fixed-delay lifecycle assertions with state polling, and keep the runner's `HOME` while isolating Foundation with `CFFIXED_USER_HOME` | Treat timer-based tests and disposable Xcode homes as hosted-runner boundaries; require a fresh exact-SHA green run after each correction |
| 2026-08-27 | Exact-SHA CI run `33021354294` | The same hosted scheduling race left two panel-release assertions false, and `Scripts/test.sh` again failed while recursively deleting the read-only Metal mount under the temporary `HOME` | Use eventual state waits with a margin between hibernate/release deadlines and stop overriding `HOME` in the test harness | Do not use a single wall-clock sleep as proof that an actor task ran; never put Xcode-owned mounted toolchains under a disposable test root |
| 2026-08-27 | Exact-SHA CI run `33026368321` | A SearchViewModel quiet-period test checked `isSearching` after one 80 ms sleep; the hosted MainActor resumed the test before the scheduled refresh task | Replace the fixed sleep with a bounded state-polling loop that yields to the actor; the same run also confirmed that Xcode mounts require a two-phase build/run harness | Use state-based waits for every asynchronous refresh/timer assertion, even when the nominal delay is short, and keep Xcode build caches outside disposable test homes |
| 2026-08-27 | Exact-SHA CI run `33026565570` | The clamshell-warning suppression test timed out while waiting for a scheduled MainActor callback, and the run also exposed that cleanup can still encounter a read-only Xcode Metal mount | Treat the warning callback as an eventual state transition and keep Xcode-owned build state outside the disposable test root; rerun the exact SHA after both corrections | Do not assert asynchronous callback timing with one fixed wait; isolate build and test user homes and require cleanup evidence on hosted macOS |
| 2026-08-27 | Exact-SHA CI run `33027023777` | The suppression test waited for `volumes.count == 1`, but the 10 ms repeat interval could legitimately produce two or more warnings before the polling loop observed the first one | Assert the lower-bound event contract (`volumes.count >= 1`) while retaining the notification-identity check | For repeating asynchronous events, assert the first required occurrence with a lower bound rather than an exact count |
| 2026-08-27 | Exact-SHA CI run `33027525145` | `Scripts/test.sh`'s two-phase preparation dropped all caller arguments, so `benchmark_name_index.sh` requested `-c release --skip-build` but the preparation built only the debug test bundle; the release test bundle was then absent | Preserve all SwiftPM arguments in the preparation phase except `--skip-build`, so the requested configuration is built before the isolated measurement phase reuses it | When wrapping a command in multiple phases, forward configuration and target selectors explicitly and strip only flags that are unsafe for the preparation phase |
| 2026-08-27 | Local release name-index benchmark after the two-phase wrapper change | Forwarding `--filter` into the `swift test --list-tests` preparation command is rejected by the toolchain's `list` subcommand (`Unknown option '--filter'`) | Strip test-execution selectors (`--filter`, `--skip`, `--specifier`, worker/attachment flags) from preparation while retaining build configuration arguments | Maintain an explicit wrapper-argument allow/deny list whenever a deprecated compatibility command changes subcommand parsing |
| 2026-08-27 | Inspect Swift build help with `rg -n ... -C 1` | The ripgrep context option followed the pattern, so `rg` treated `-C` and `1` as filenames and exited before scanning | Re-run with `rg -C 1 -- <pattern>` | Put all ripgrep options before the pattern in release probes |
| 2026-08-27 | Exact-SHA CI run `33028259025` | Bash 3.2 with `set -u` treats an empty `build_args` array expansion as an unbound variable, so the no-argument `Scripts/test.sh` path exited before SwiftPM started | Branch the preparation command when the array is empty and expand it only when it contains arguments | Test shell wrappers both with no arguments and with benchmark configuration/selector arguments under the target Bash version |
| 2026-08-27 | Inspect CI failure log with `rg -n ... -C 2` | The `rg` option was placed after the pattern, so ripgrep parsed `-C` as a filename and exited before the intended log scan | Re-run with options before the pattern (`rg -C 2 -- <pattern>`) | Put ripgrep options before the pattern in release evidence wrappers and check the exit code separately from the matched output |
| 2026-08-27 | Install the locally verified `v1.1.2` archive with `Scripts/install_local_app.sh` | Two retained read-only verification directories under `/private/tmp` still contained bundles named `OpenFind.app`, so the canonical-app uniqueness gate correctly rejected the install | Verify those diagnostic bundles, rename only their `.app` suffix to `.app.disabled`, and rerun the installer; the canonical `/Applications/OpenFind.app` replacement then passed | After collecting verification evidence, keep diagnostic bundles outside the `.app` namespace or disable their suffix before invoking the uniqueness-gated installer |
| 2026-08-27 | Re-run a focused Swift test with `--skip-build` immediately after editing its source | The test runner reused the previously compiled bundle, so the output reflected stale assertions instead of the current test file | Re-run the first focused test without `--skip-build`, then reuse that newly built bundle for unchanged follow-up filters | Never use `--skip-build` after a source or test edit until one build-backed test command has compiled the new tree |
| 2026-08-27 | Drive the installed clipboard panel through the Computer Use accessibility bridge | The main-window clipboard button was exposed without an actionable frame, and the bridge's accepted `Escape` key did not exercise the panel's custom close path; lowercase `esc` was rejected | Use the freshly captured window screenshot for the button coordinate, close through the standard macOS `Command-W` window path, then reopen and re-read the accessibility tree and Core Graphics bounds | Treat accessibility-bridge delivery as a separate gate from product behavior; refresh state before every action and use a standard window action when a custom key equivalent is not observable |
| 2026-08-27 | Exact-SHA CI run `33038908454` | Two new clipboard geometry tests required an exact `1080×680` frame, but the hosted runner's visible screen was only `1024×674`; the product correctly bounded the panel to the visible frame and the tests reported three false failures | Derive the expected expanded size from the smaller of the product default and `NSScreen.main.visibleFrame`, then rerun the focused and complete gates | Window-size tests must verify the requested default after applying the same visible-screen bound as production; never assume a developer Mac's screen geometry on hosted runners |
