# 🚀 OpenFind

<p align="center">
  <a href="README.md">
    <img src="https://img.shields.io/badge/Language-English-blue?style=for-the-badge" alt="English" />
  </a>
</p>

---

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS_14+-black.svg)](https://apple.com)
[![Swift: 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)

**告别 Spotlight 的迟钝与局限。让任何文件、内容、甚至是未解压的代码归档，瞬间直达。**

OpenFind 是一款专为开发者打造的 macOS 极速本地搜索引擎。它抛弃了臃肿且容易死锁的传统索引服务，使用轻量化的内存映射（`mmap`）二进制索引与原生 `FSEvents` 实时文件监控。不管是全局快捷键呼出，还是在 Shell 中编排脚本，它都能在微秒间为您提供流式结果。

---

## 🎯 一句话定位

零延迟、本地优先的 macOS 搜索引擎。无需反复读写 SSD，通过正则、Glob 与自定义元数据，瞬间搜遍文件和内容。

---

## 🔥 为什么我们需要它？

### Spotlight 的噩梦
1. **CPU 飙升与无预警卡顿**: `mds` 和 `mds_stores` 经常强占 100% CPU，在后台疯狂重建损坏的索引，大幅缩短 MacBook 的电池寿命。
2. **不懂开发者的痛点**: 想要查找一个 `.env` 配置文件，或者搜索一个嵌套在 `.zip` 压缩包或 PDF 里的变量？Spotlight 对此无能为力。
3. **不支持正则与 Glob**: 你无法使用 `src/**/*.swift` 这样的通配符，也无法使用类似 `^Report-[0-9]+$` 的正则表达式进行匹配。
4. **命令行极度不友好**: Spotlight 的命令行工具 `mdfind` 响应迟缓，极难优雅地通过管道接入 Shell 脚本。

### OpenFind 的解脱
- **瞬时加载 (`mmap`)**: 通过将目录节点直接映射到虚拟内存空间，即使包含数百万个文件，也无需在 Swift 堆区分配空间，实现微秒级启动。
- **基于 FSEvents 的实时监控**: 自动在后台监听文件系统事件，你在终端里刚 `touch` 或 `git pull`，变动就已经被瞬间同步到索引中。
- **全文本“深空”提取器**: 深度检索纯文本、PDF、Office 文档（`docx`, `xlsx`）、Apple iWork 格式（`pages`, `numbers`），甚至能在内存中直接流式遍历压缩包（`.zip`, `.tar.gz`），无需解压到磁盘。
- **原生 Quick Look 快速预览**: 选中文件按下 `Space` 键，即可直接调起系统级原生 `Quick Look` 面板进行预览，无需点开任何笨重的编辑器。

---

## 🆚 痛点对比

| 场景 / 特性 | 传统方式 (Spotlight / `find` / `grep`) | OpenFind 方式 🚀 |
| :--- | :--- | :--- |
| **搜索速度** | ⏱️ 5~10+ 秒的磁盘扫描，让 SSD 持续高负荷运转。 | ⚡ **瞬时 (毫秒级)**，采用 `mmap` 二进制索引。 |
| **正则与 Glob 支持** | ❌ 无内置正则，需写极其复杂的 `find` 命令行。 | ✅ **开箱即用**。只需输入 `regex:^Report-[0-9]+$` 或 `src/**/*.swift`。 |
| **压缩包与 PDF 内容检索** | ❌ 必须手动解包，用专用阅读器检索。 | 🔍 **内存流式匹配**。完美支持 PDF、Word、ZIP 包内源码。 |
| **系统资源占用** | 🥵 `mds` 进程导致 CPU 暴走，风扇狂转。 | 🍃 **极低占用**。后台 FSEvents 零碎监听 + 内存映射。 |
| **开发者噪音过滤** | ❌ 搜出大量 `node_modules` 或 `build` 等无用缓存。 | 🛡️ **智能忽略列表**。专注核心代码，动态过滤噪音。 |
| **使用界面** | 🎛️ 笨重的 UI 或纯命令行，预览文件极不方便。 | 💻 **双栖模式**: 全局快捷键状态栏 App + 脚本化 CLI，支持原生 `Quick Look` 预览！ |

---

## ✨ 杀手级特性与高光时刻

### 1. ⚡ 内存映射瞬时索引与实时同步
微秒级加载数百万条文件路径。利用 macOS 的 `FSEvents` API，在后台无感追踪文件系统的新增、重命名和删除，保持索引鲜活性，且绝不占用额外 CPU 资源。
* **高光时刻:** 在终端中运行命令创建文件，还没松开 Enter 键，该文件就已经出现在你的 OpenFind 搜索框中了。

### 2. 🔍 深空内容提取与免解压压缩包流式匹配
不仅支持纯文本，还能深度检索 PDF、Microsoft Office、Apple iWork 格式和压缩归档（`.zip`, `.tar.gz`, `.7z`）。在内存中直接流式解压并遍历成员，不对磁盘进行临时写入，同时采用进程级沙盒隔离确保数据安全。
* **高光时刻:** 无需解压，瞬间定位嵌套在好几层 zip 发包文件锁死深处的某个配置项。

### 3. 🛠️ 强大的高级查询语法与 GUI + CLI 双栖体验
支持高级布尔逻辑、元数据过滤（文件大小、创建日期）、Glob、正则以及 Finder 标签。通过全局快捷键 `⌘⇧Space` 唤起极简搜索窗口，按下 `Space` 即可快速预览文件；或将 CLI 命令无缝拼入你的自动化工作流。
* **高光时刻:** 唤起窗口，搜到 PDF 后，只需按一下空格键就能立即阅读里面的结构，行云流水。

---

## ⚡ 极简上手 (60 秒)

你可以在一分钟内编译并体验 CLI 命令行搜索！

### 运行 CLI 命令行
```bash
# 1. 克隆仓库
git clone https://github.com/GravityPoet/OpenFind.git && cd OpenFind

# 2. 使用 macOS 14+ SDK 编译
xcrun --sdk macosx swift build

# 3. 瞬时搜索包含 "OpenFind" 的 Markdown 文件
xcrun --sdk macosx swift run OpenFind --search "ext:md content:OpenFind"
```

### 安装 GUI 客户端（状态栏 App）
运行打包脚本自动生成通用包并注册 LaunchServices，即可安装常驻状态栏：
```bash
# 构建 Universal 生产发布包
bash Scripts/build_customer_app.sh

# 原子替换并注册 Spotlight / LaunchServices
bash Scripts/install_local_app.sh
```
*使用全局快捷键 **`⌘⇧Space`** 即可在任意位置唤起或隐藏 OpenFind！*

---

## 👥 典型场景

* 💻 **软件开发与 SRE**: 在海量代码或挂载盘中瞬间定位特定日志、配置和 API 定义，避免卡死编辑器。
* 📦 **发版与包管理**: 无需解压，在各种分发压缩包和嵌套归档中搜索符号及配置值。
* 🔍 **效率极客与 Power User**: 用一个隐私安全、支持正则和原生 Quick Look 的极简搜索面板完全替代经常损坏索引的 Spotlight。

---

## ⚙️ 常用查询示例

OpenFind 支持开箱即用的高级查询语法：

```text
*.pdf briefing          # 文件名包含 briefing 的 PDF 文件
ext:png;jpg travel      # 文件名包含 travel 的 PNG 或 JPG 图片
type:code openfind      # 文件名包含 openfind 的源码/代码文件
doc:invoice             # 文件名包含 invoice 的文档文件
size:empty              # 空文件
size:!=0b               # 非空文件
report summary|draft    # report 并且包含 (summary 或者 draft)
src/**/SearchQuery.swift
parent:/Users/me/Docs   # 在指定的父目录下进行单层搜索
in:/Users/me/Projects   # 递归在指定的文件夹范围内搜索
dm:pastweek             # 最近一周内修改的文件
dc:>=2026-01-01        # 创建时间在此日期之后的文件
tag:Project;Important  # 包含任一 Finder 标签
regex:^Report-[0-9]+$   # 基于正则表达式匹配文件名
content:"Q4 budget"    # 全文内容子串搜索（支持 PDF/Office/代码）
```

---

## 🏗️ 系统架构

OpenFind 基于 **Swift 6 / SwiftUI** 构建，严格遵循单向数据流架构：

```
Views ──> State (ViewModel) ──> Engine ──> Models
```

- **Models:** 值类型，管理查询匹配规则。
- **Engine:** 维护高效的 mmap 内存映射路径索引，并调度 SQLite-FTS 全文搜索引擎进行精确分块匹配。
- **DocumentTextExtractor:** 负责纯文本、PDF、微软 Office、苹果 iWork 格式及压缩包在内存中的提取。
- **App Entry:** 分发命令行参数（CLI）或注册状态栏（GUI）处理事件。

---

## 📦 打包与签名

构建脚本内置了代码签名与公证（Notarization）流程：

```bash
# 构建用于本地安装或分发的发布版 ZIP 压缩包（使用 OpenFind Customer 签名标识）
bash Scripts/build_customer_app.sh

# 执行 Ad-hoc 本地临时验证构建
SIGN_IDENTITY=- bash Scripts/build_app.sh

# 进行 Developer ID 签名并公证的直接分发构建
SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
  NOTARIZE=1 \
  NOTARY_PROFILE="openfind-notary" \
  bash Scripts/build_app.sh
```

在首次进行公证构建之前，请在 macOS Keychain 中存储你的 Apple 开发者公证凭证：
```bash
xcrun notarytool store-credentials openfind-notary \
  --apple-id "developer@example.com" \
  --team-id "TEAMID"
```

---

## ⚖️ 许可与商业化

OpenFind 基于 **GNU Affero General Public License v3.0** 协议开源（仅限 `AGPL-3.0-only`）。详见 [LICENSE](LICENSE).

* **商业授权:** 凡是希望将 OpenFind 代码整合进闭源软件、重新分发或在商业化场景中受专有条款约束的组织，可申请独立商业许可证。详见 [COMMERCIAL_LICENSE.md](COMMERCIAL_LICENSE.md)。
* **贡献者协议 (CLA):** 为保持双重许可结构，合并任何外部 PR 前均需签署 CLA。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。
* **商标声明:** 许可协议不授权任何关于 OpenFind 品牌、Logo 或图标的商标使用权。详见 [TRADEMARKS.md](TRADEMARKS.md)。
