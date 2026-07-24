## 🌐 [点击这里切换到：中文版 (Chinese Version)](README-zh.md)

# 🚀 OpenFind

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS_14+-black.svg)](https://apple.com)
[![Swift: 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)

**The All-in-One Power Utility for macOS Developers & Power Users.**  
*Replaces 5 separate background apps with one ultra-fast, lightweight native Swift engine.*

OpenFind unifies **Hyper-Fast File & Content Search**, **Encrypted Smart Clipboard with OCR**, **Automated Keep-Awake with Clamshell Mode**, **External Drive Keep-Alive**, and **Instant Keyboard Lock** into a single status-bar app and CLI tool.

---

## 🎯 Slogan

Stop cluttering your Mac with 5 single-purpose utility apps. OpenFind delivers zero-latency search, OCR clipboard history, smart sleep prevention, and system maintenance—all powered by a lightweight native Swift engine.

---

## 🔥 The Why: Why You Need OpenFind

### The Bloated Utility Nightmare
To get a decent workflow on macOS, developers usually end up installing:
1. **Spotlight Alternatives / Search tools**: Heavy, slow indexing that burns CPU cycles.
2. **Clipboard Managers**: Unencrypted clipboard history tools that accidentally leak passwords.
3. **Keep-Awake Utilities (Caffeine/Amphetamine)**: Basic menu bar toggles without smart automation or clamshell support.
4. **Drive Keep-Alive Utilities**: Separate scripts to stop external drives from spinning down.
5. **Keyboard Cleaner Tools**: Single-function utility apps just to wipe off keycaps.

### The OpenFind Solution
OpenFind combines all 5 essential power-tools into a single, unified, privacy-first native macOS application that consumes minimal system RAM and CPU.

---

## 🆚 Before vs. After

| Scenario / Feature | 5 Separate Apps (Spotlight + Paste + Amphetamine + etc.) | OpenFind Way 🚀 |
| :--- | :--- | :--- |
| **System Resource Impact** | 🥵 5 background processes eating 1GB+ RAM and battery. | 🍃 **One lightweight native engine** with `mmap` binary index & zero-lag. |
| **File & Content Search** | ⏱️ 5~10s disk scans; no regex, no deep search in ZIPs. | ⚡ **Instant millisecond search** across code, PDFs, Office & inside ZIPs without extracting. |
| **Clipboard History** | 🔓 Plaintext storage, security risk for API keys. | 🔐 **Encrypted SQLite storage**, Vision OCR text recognition, Paste Stack & auto-privacy masking. |
| **Sleep Prevention** | ☕ Manual toggles; breaks when you close the MacBook lid. | ☕ **Smart Keep-Awake**, Clamshell (Lid-Closed) Mode, and condition-based automation (App/Download). |
| **External Drive Health** | 🛑 Hard drives sleep, disconnect, or freeze Finder. | 💾 **DriveAlive Heartbeat**: Prevents external SSDs/HDDs/NAS from spinning down or disconnecting. |
| **Keyboard Maintenance** | 🧼 Download another 3rd-party app to lock keyboard. | 🔒 **Instant Keyboard Lock** via shortcut to clean keycaps or block pet accidents. |

---

## ✨ 5 Killer Toolkits in One Package

### 1. ⚡ Hyper-Fast Local Engine (File & Content Search)
* **Instant `mmap` Indexing**: Loads millions of file paths in microseconds without heap memory overhead.
* **Real-time FSEvents Sync**: Instantly indexes terminal changes (`git pull`, `touch`) as they happen.
* **Deep Space Extraction**: Search inside PDFs, Word/Excel, Apple iWork, and stream inside `.zip` / `.tar.gz` compressed archives without disk extraction.
* **Regex, Globs & Quick Look**: Complete support for `src/**/*.swift`, `regex:^Report-[0-9]+$`, and instant `Space` key Quick Look preview.

### 2. 📋 Encrypted Clipboard Manager & OCR Tool
* **Encrypted Storage**: Secured by hardware-level AES encryption to protect your sensitive history.
* **Vision Framework OCR**: Copy any screenshot or image, and OpenFind automatically extracts and lets you search text inside images.
* **Sequential Paste Stack**: Copy 10 items in order, then paste them sequentially with a single shortcut.
* **Snippet Expansion & Auto-Privacy**: Pin frequent snippets and automatically ignore 1Password, Keychain, and sensitive app data.

### 3. ☕ Smart Keep-Awake & Clamshell (Lid-Closed) Mode
* **Sleep Prevention**: Keep your Mac display or system awake for custom durations or indefinitely.
* **Clamshell Mode**: Keep your MacBook running complex scripts or servers even when the lid is closed.
* **Automated Condition Triggers**: Automatically activate keep-awake when specific Apps run, active downloads occur, or high network/CPU activity is detected.
* **Low-Battery Guard**: Automatically restores normal sleep rules when battery drops below safety thresholds.

### 4. 💾 DriveAlive External Storage Protector
* **Prevents Disconnections**: Keeps external HDDs, SSDs, and NAS volumes active using background micro-heartbeats.
* **No Finder Freezes**: Eliminates the 5-second spin-up lag when accessing external storage.

### 5. 🔒 Instant Keyboard Lock
* **One-Click Cleaning**: Instantly lock all keyboard inputs with a customizable hotkey to safely wipe your MacBook keyboard or protect against accidental pet typing.

---

## ⚡ Quick Start (60 Seconds)

### Run CLI Mode
```bash
# 1. Clone & Navigate
git clone https://github.com/GravityPoet/OpenFind.git && cd OpenFind

# 2. Build with macOS 14+ SDK
xcrun --sdk macosx swift build

# 3. Perform a instant search for code containing "OpenFind"
xcrun --sdk macosx swift run OpenFind --search "ext:swift content:OpenFind"
```

### Install status bar GUI App
Run our unified build script to package and install the complete app:
```bash
# Package production build
bash Scripts/build_customer_app.sh

# Install atomically to /Applications
bash Scripts/install_local_app.sh
```

---

## ⚙️ Power Commands & Syntax Examples

```text
# --- SEARCH SYNTAX ---
*.pdf briefing          # PDF files containing briefing in name
type:code openfind      # Source code files containing openfind
regex:^Report-[0-9]+$   # Match names using regex
content:"API_SECRET"    # Deep text search in files, PDFs & Zipped sources
in:/Users/me/Projects   # Search recursively inside specific directory
tag:Project;Important  # Finder tag filtering

# --- SHORTCUT CHEAT SHEET ---
⌘⇧Space                 # Toggle OpenFind Search Bar
Space (on result)       # Native Quick Look preview
```

---

## 🏗️ Architecture & Security First

OpenFind is built using **Swift 6 & SwiftUI** with strict privacy guarantees:
* **100% Local Execution**: No telemetry, no cloud analytics, zero external network requests.
* **Unidirectional State Architecture**: Clean separation between `Views -> State -> Engine -> Models`.
* **Process-Isolated Extraction**: Safe sandboxed decompression and text extraction for untrusted archives.

---

## 📦 Packaging & Code Signing

```bash
# Production release build
bash Scripts/build_customer_app.sh

# Developer ID signed & notarized build
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  NOTARIZE=1 \
  NOTARY_PROFILE="openfind-notary" \
  bash Scripts/build_app.sh
```

---

## ⚖️ Licensing & Commercial Terms

OpenFind Community Edition is open source under the **[AGPL-3.0 License](./LICENSE)**.

- **Open Source Free Use**: Any individual or enterprise may use and distribute OpenFind for free in accordance with AGPL-3.0 license terms.
- **Commercial Dual-License**: If you or your organization need closed-source integration, exemption from AGPL-3.0 copyleft obligations, or proprietary redistribution rights, please contact us for a [Commercial License](mailto:moonlitpoet@proton.me). See [COMMERCIAL_LICENSE.md](./COMMERCIAL_LICENSE.md) for details.
- **Contributor Agreement (CLA)**: External contributions are covered by our CLA to maintain dual-licensing clean rights. See [CONTRIBUTING.md](./CONTRIBUTING.md).
- **Trademarks**: See [TRADEMARKS.md](./TRADEMARKS.md).
