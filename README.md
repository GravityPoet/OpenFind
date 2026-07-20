## 🌐 [点击这里切换到：中文版 (Chinese Version)](README-zh.md)

# 🚀 OpenFind

---

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS_14+-black.svg)](https://apple.com)
[![Swift: 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)

**Stop waiting for Spotlight. Find anything, anywhere, instantly.**

OpenFind is a lightning-fast, local, developer-first search engine for macOS (14+). By replacing CPU-heavy indexers with a persistent memory-mapped (`mmap`) directory structure and macOS-native `FSEvents` API, it brings near-zero startup latency and microsecond query times directly to your status bar and command line.

---

## 🎯 Slogan

A zero-latency, local-first search engine for macOS that lets developers query files and content using Regex, Glob, and Metadata without breaking a sweat or killing your SSD.

---

## 🔥 The Why

### The Spotlight Nightmare
1. **Unpredictable Lag & CPU Spikes**: `mds` and `mds_stores` frequently consume 100% CPU, draining your MacBook battery while rebuilding corrupted indexes.
2. **Deaf to Developer Needs**: Try searching for a `.env` file, a hidden configuration file, or checking if a variable exists inside a nested `.zip` or a PDF. Spotlight will leave you empty-handed.
3. **No Regex, No Globs**: You can't search for `src/**/*.swift` or use regex matching like `^Report-[0-9]+$`.
4. **CLI Hostile**: Spotlight's metadata CLI (`mdfind`) is sluggish and painful to pipe into shell scripts.

### The OpenFind Relief
- **Instantaneous Load (`mmap`)**: The index loads in microseconds by mapping directory nodes directly into memory space, avoiding Swift heap allocations even with millions of items.
- **FSEvents-Powered Real-time Watcher**: Instantly indexes terminal changes (like `touch` or `git pull`) as they happen.
- **Full-Text "Deep Space" Extraction**: Crawl text streams inside code, PDFs, Office files (`docx`, `xlsx`), Apple iWork files (`pages`, `numbers`), and even nested compressed archives (`.zip`, `.tar.gz`) without extracting them to disk.
- **Native Quick Look Flow**: Press `Space` to immediately preview results in a native UI without opening heavy IDEs.

---

## 🆚 Before vs. After

| Scenario / Feature | The Old Way (Spotlight / `find` / `grep`) | The OpenFind Way 🚀 |
| :--- | :--- | :--- |
| **Search Speed** | ⏱️ 5~10+ seconds of scanning, freezing your disk. | ⚡ **Instant (Milliseconds)** using `mmap` binary index. |
| **Regex & Glob Support** | ❌ No built-in Regex. Complex `find -regextype` commands. | ✅ **Out of the box**. Just type `regex:^Report-[0-9]+$` or `src/**/*.swift`. |
| **Content in Zips & PDFs** | ❌ Extract ZIP manually, open PDF tool, then search. | 🔍 **Seamless stream matching**. PDF, docx, numbers, zipped sources. |
| **System Resource Impact** | 🥵 `mds` / `mds_stores` spikes CPU, battery drains. | 🍃 **Near-Zero footprint**. Idle FSEvents syncing + mmap RAM safety. |
| **Developer Noise Filter** | ❌ Floods search with `node_modules`, `build` junk. | 🛡️ **Smart ignore-list**. Focus on your code, filter out noise dynamically. |
| **Interface** | 🎛️ Heavy UI or CLI-only, difficult to preview files. | 💻 **Dual-mode**: Global Shortcut Menu Bar app + Scriptable CLI with native `Quick Look`! |

---

## ✨ Killer Features & AHA Moments

### 1. ⚡ Memory-Mapped Instant Indexing & Real-Time Sync
Loads millions of file paths in micro-seconds. Through macOS `FSEvents`, it seamlessly tracks every file system addition, rename, or deletion in the background, keeping index freshness in sync with your terminal without CPU spikes.
* **AHA Moment:** Create a file in terminal and watch it pop up in your OpenFind search before you can release the Enter key.

### 2. 🔍 Deep Content Extraction & Zero-Disk Archive Traversal
Deeply indexes not only plain text but also PDFs, Microsoft Office, iWork formats, and compressed archives (`.zip`, `.tar.gz`, `.7z`). It streams archive members in memory without writing temp files to disk, isolating decompression for bulletproof security.
* **AHA Moment:** Locate that one config key hidden deep inside a nested zipped release bundle, without ever clicking "Extract".

### 3. 🛠️ Power-User Queries with GUI + CLI Flexibility
Perform advanced boolean querying, metadata checks (`size`, `creation date`), globs, regex, and Finder tags. Summon the minimalist window globally using `⌘⇧Space` and press `Space` to Quick Look files on the spot, or pipe command-line output straight into your development workflows.
* **AHA Moment:** Quickly check the structure of an indexed PDF by pressing `⌘⇧Space`, typing your query, and tapping `Space` to preview it instantly.

### 4. Native Utility Modules
OpenFind also replaces three separate menu-bar utilities without embedding or launching their app bundles:

- **Keep Awake:** timed and conditional sessions, all 14 Amphetamine-style Trigger criteria, screen-saver/display policy, closed-display mode with transactional recovery, optional Power Protect, notifications, hot keys, AppleScript, statistics, and Drive Alive.
- **Clipboard History:** bounded local history for text, rich text, URLs, files, and images, with search, preview, pinning, duplicate handling, ignore rules, encrypted persistence, and paste-without-formatting.
- **Keyboard Cleaning:** Accessibility-gated keyboard/media-key suppression, pointer-only unlock, countdown, emergency auto-unlock, and lifecycle cleanup.

Privileged closed-display changes are opt-in. Drive Alive writes one bounded marker per selected target and never overwrites an unrelated file.

---

## ⚡ Quick Start (60 Seconds)

You can build the CLI and see it in action in under a minute!

### Run the CLI
```bash
# 1. Clone the repository
git clone https://github.com/GravityPoet/OpenFind.git && cd OpenFind

# 2. Build with macOS 14+ SDK
xcrun --sdk macosx swift build

# 3. Search instantly for a Markdown file containing "OpenFind"
xcrun --sdk macosx swift run OpenFind --search "ext:md content:OpenFind"
```

### Install the GUI (Status Bar App)
Run this single script to package the universal binary, register system shortcuts, and launch the menu bar app:
```bash
# Package the production build
bash Scripts/build_customer_app.sh

# Install atomically & register Spotlight/LaunchServices
bash Scripts/install_local_app.sh
```
*Press **`⌘⇧Space`** to toggle the search window from anywhere!*

---

## 👥 Who Needs This

* 💻 **Developers & SREs:** Locate specific logs, configurations, and API definitions across massive codebases without freezing your editor.
* 📦 **Release Managers:** Search for symbols and configuration values inside nested archives and distribution packages without unpacking them.
* 🔍 **Power Users & Geeks:** Replace Spotlight with a clean, privacy-first interface that handles Regex, Finder tags, and native Quick Look previews seamlessly.

---

## ⚙️ Advanced Query Examples

OpenFind supports a rich query syntax out of the box:

```text
*.pdf briefing          # PDF files whose names contain briefing
ext:png;jpg travel      # PNG or JPG files whose names contain travel
type:code openfind      # source/code files whose names contain openfind
doc:invoice             # document files whose names contain invoice
size:empty              # empty files
size:!=0b               # non-empty files
report summary|draft    # report AND (summary OR draft)
src/**/SearchQuery.swift
parent:/Users/me/Docs   # search within direct parent directory
in:/Users/me/Projects   # search recursively inside folder scope
dm:pastweek             # modified in the last week
dc:>=2026-01-01        # created on or after this date
tag:Project;Important  # either Finder tag
regex:^Report-[0-9]+$   # Regex name matching
content:"Q4 budget"    # Full-file substring search (PDF/Office/Code)
```

---

## 🏗️ Architecture & Layers

OpenFind is built using **Swift 6 / SwiftUI** and follows a unidirectional state flow:

```
Views ──> State (ViewModel) ──> Engine ──> Models
```

- **Models:** Value types, query match options.
- **Engine:** Persistent path/name indexing plus on-demand content matching using SQLite-based FTS block structures.
- **DocumentTextExtractor:** Isolates text extraction from plain text, PDF, Microsoft Office, Apple iWork formats, and compressed archives.
- **App Entry:** Entry dispatcher handling both command-line arguments and GUI scenes.

---

## 📦 Packaging & Code Signing

The build scripts automate the code signing and verification process:

```bash
# Product ZIP for local installation and customer distribution. 
# Both use the pinned OpenFind Customer Code Signing identity.
bash Scripts/build_customer_app.sh

# Explicit ad-hoc validation build.
SIGN_IDENTITY=- bash Scripts/build_app.sh

# Developer ID signed + notarized direct distribution.
SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
  NOTARIZE=1 \
  NOTARY_PROFILE="openfind-notary" \
  bash Scripts/build_app.sh
```

Before running a notarized build, make sure you store your Apple notary credentials:
```bash
xcrun notarytool store-credentials openfind-notary \
  --apple-id "developer@example.com" \
  --team-id "TEAMID"
```

---

## ⚖️ License and Commercial Use

OpenFind is licensed under the **GNU Affero General Public License v3.0** (`AGPL-3.0-only`). See [LICENSE](LICENSE).

* **Commercial Licensing:** Organizations looking to embed, redistribute, or modify OpenFind under proprietary terms can request a commercial license. See [COMMERCIAL_LICENSE.md](COMMERCIAL_LICENSE.md).
* **Contributor Agreement:** External contributions require an accepted Contributor License Agreement (CLA) to maintain the dual-licensing structure. See [CONTRIBUTING.md](CONTRIBUTING.md).
* **Trademarks:** AGPL grants software copyright permissions but does not grant trademark rights. See [TRADEMARKS.md](TRADEMARKS.md).
