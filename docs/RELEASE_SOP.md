# OpenFind Release SOP

This is the canonical release runbook for OpenFind. `RELEASING.md` is only a
compatibility entry point and must not contain an independent procedure.

## Release contract

- Repository: `GravityPoet/OpenFind`
- Default and release branch: `main`
- Public version format: semantic tags such as `v1.1.0`
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
   swift test --no-parallel
   OPENFIND_RUN_DRIVE_ALIVE_INTEGRATION=1 \
     swift test --no-parallel --filter DriveAliveIntegrationTests
   OPENFIND_RUN_VISUAL_REGRESSION=1 \
     swift test --filter VisualRegressionTests
   FILES=8000 BODY_KB=16 COPIES=4 bash Scripts/benchmark_content_index.sh
   FILES=600 MATCH_EVERY=60 bash Scripts/benchmark_index.sh
   NODES=250000 bash Scripts/benchmark_name_index.sh
   ```

3. Build the exact customer artifact. For `v1.1.0`, use:

   ```bash
   APP_VERSION=1.1.0 BUILD_NUMBER=1001000 \
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
   git commit -m "release: prepare v1.1.0"
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
   exact tag SHA before uploading any presentation assets.

8. Upload the 60-second demo and product screenshots without overwriting
   existing assets:

   ```bash
   gh release upload "${TAG}" \
     docs/assets/OpenFind-60s-demo.mp4 \
     docs/assets/openfind-welcome.png \
     docs/assets/openfind-search.png \
     docs/assets/openfind-interface-size.png
   ```

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
  checksum, signed appcast, presentation assets, and generated notes.
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
