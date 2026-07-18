# OpenFind

OpenFind is a local, real-time, developer-friendly advanced file search tool for macOS 26+. It provides fast file-name and path search with a persistent local path/name index, plus on-demand content matching when requested.

## Key Features

1. **Instant Search:** Stream results in real time as you type, backed by a local path/name index.
2. **Relevant Whole-Mac Defaults:** Search the whole Mac with hidden files, user file locations, and mounted volumes included; cache/log/temp noise stays filtered unless Deep Index is enabled.
3. **Advanced Querying:** Boolean expressions, path globs, regular expressions, Finder tags, content predicates, folder scopes, and Cardinal-style metadata filters.
4. **CLI Mode:** Command-line executable support for headless, scriptable searches.
5. **Privacy First:** Entirely local search operations, with security-scoped bookmark support for user-selected folders.
6. **Native Workflow:** Press Space to Quick Look selected results and `⌘⇧Space` to show or hide OpenFind globally.

## Requirements

- macOS 26 or later
- Apple Silicon or Intel Mac supported by the macOS 26 SDK/toolchain

## Compilation and Build

Due to platform SDK lookup dynamics on macOS terminal environments, always build with the explicit SDK path modifier:

```bash
# Debug build
xcrun --sdk macosx swift build

# Run debug CLI
xcrun --sdk macosx swift run OpenFind --search "query"
```

## Query Examples

```text
*.pdf briefing          # PDF files whose names contain briefing
ext:png;jpg travel      # PNG or JPG files whose names contain travel
type:code openfind      # source/code files whose names contain openfind
doc:invoice             # document files whose names contain invoice
size:empty              # empty files
size:!=0b               # non-empty files
report summary|draft    # report AND (summary OR draft)
src/**/SearchQuery.swift
parent:/Users/me/Documents ext:md
in:/Users/me/Projects dm:pastweek
nosubfolders:/tmp ext:log
dc:>=2026-01-01        # created on or after this date
tag:Project;Important  # either Finder tag
regex:^Report-[0-9]+$
content:"Q4 budget"    # full-file substring search
```

Plain terms match file names, including hidden files by default. Path matching is
explicit: include `/` in the query (`src/**/SearchQuery.swift`) or use `path:` /
`in:` / `parent:` filters.

## Packaging

To package the product into a verified macOS app archive with the single pinned
OpenFind signing identity, execute:

```bash
bash Scripts/build_customer_app.sh
```

This compiles a universal production build by default (`arm64 x86_64`), generates
the application icon, copies localization assets, signs the bundle, and verifies
the executable architectures. The resulting package is `dist/OpenFind.zip`.
The temporary `OpenFind.app` is physically removed after archive verification.

To replace the local installation atomically and validate that the product app is
unique across the filesystem, Spotlight, LaunchServices, the running process, and
any Dock entry, run:

```bash
bash Scripts/install_local_app.sh
```

The installer keeps the previous version only as an atomic replacement staging
bundle while validation runs. It restores that bundle on failure and removes it
after success, so it does not accumulate persistent rollback copies.

Distribution options:

```bash
# Product ZIP for local installation and customer distribution. Both use the
# pinned OpenFind Customer Code Signing identity.
bash Scripts/build_customer_app.sh

# Explicit ad-hoc validation build. This is never the installed product.
SIGN_IDENTITY=- bash Scripts/build_app.sh

# Developer ID signed + notarized direct distribution.
SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
NOTARIZE=1 \
NOTARY_PROFILE="openfind-notary" \
bash Scripts/build_app.sh

# Sandbox entitlement profile for App Store / sandbox validation builds.
DISTRIBUTION=sandbox bash Scripts/build_app.sh
```

Before the first notarized build, store the Apple notary credentials in your
keychain profile so the app-specific password is not passed on the build command
line:

```bash
xcrun notarytool store-credentials openfind-notary \
  --apple-id "developer@example.com" \
  --team-id "TEAMID"
```

For non-interactive CI setup, set `STORE_NOTARY_CREDENTIALS=1` and provide
`APPLE_ID`, `TEAM_ID`, and `APP_SPECIFIC_PASSWORD`; subsequent submission still
uses `--keychain-profile`.

The direct distribution profile intentionally does not enable App Sandbox because
whole-Mac filesystem enumeration requires broad local file access. The sandbox
profile is provided for App Store-style builds that rely on user-selected,
security-scoped folders.

Performance smoke benchmark:

```bash
bash Scripts/benchmark_index.sh
```

## Architecture & Layers

OpenFind is built using Swift 6 / SwiftUI and adheres to a unidirectional architecture:

```
Views -> State (ViewModel) -> Engine -> Models
```

- **Models:** Value types, query match options.
- **Engine:** Persistent path/name indexing plus on-demand content matching using structured concurrency.
- **State:** Persistent settings and state management.
- **Views:** SwiftUI-based minimal and responsive visual components.
- **App:** Entry dispatcher handling both command-line arguments and GUI scenes.

## License and Commercial Use

OpenFind is licensed under the GNU Affero General Public License v3.0 only
(`AGPL-3.0-only`). See [LICENSE](LICENSE).

Organizations that want to embed, redistribute, modify, or provide OpenFind-based
software under proprietary terms can request a separate commercial license. See
[COMMERCIAL_LICENSE.md](COMMERCIAL_LICENSE.md).

External contributions require an accepted contributor license agreement before
merge so the project can keep offering both the AGPL release and separate
commercial licenses. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[CONTRIBUTOR_LICENSE_AGREEMENT.md](CONTRIBUTOR_LICENSE_AGREEMENT.md).

The AGPL grants copyright permissions for covered files, but it does not grant
trademark rights in the OpenFind name, logo, or icon as brand identifiers. See
[TRADEMARKS.md](TRADEMARKS.md).
