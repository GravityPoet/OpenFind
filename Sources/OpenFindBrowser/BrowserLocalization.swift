// Adapted from FinderSearch (MIT), commit 021ad61679fbb1c1f18f9dc57a7d1bbc6883863e.
import Foundation

/// Browser-only localization keeps this standalone target independent from the
/// host application's resource bundle. English remains the source language;
/// Chinese is selected when the user's preferred language is Chinese.
enum BrowserLocalization {
    private static let chinese = [
        "File Browser": "文件浏览器",
        "Searching “": "正在搜索“",
        "Search": "搜索",
        "Search:": "搜索：",
        "Search failed": "搜索失败",
        "Search index is not ready.": "搜索索引尚未就绪。",
        "Back": "后退",
        "Forward": "前进",
        "Sort By": "排序方式",
        "Ascending": "升序",
        "Show Hidden Files": "显示隐藏文件",
        "Sort": "排序",
        "Share": "共享",
        "Tags": "标签",
        "Actions": "操作",
        "View": "显示",
        "Icons": "图标",
        "List": "列表",
        "Columns": "分栏",
        "Gallery": "画廊",
        "Icon Size": "图标大小",
        "This Mac": "此 Mac",
        "Kind": "种类",
        "Any Kind": "任意种类",
        "Folder": "文件夹",
        "Application / Package": "应用程序/程序包",
        "Document": "文稿",
        "Image": "图像",
        "Movie": "影片",
        "Audio": "音频",
        "Name": "名称",
        "Date Modified": "修改日期",
        "Size": "大小",
        "Where": "位置",
        "Relevance": "相关性",
        "No Results": "没有结果",
        "No Items": "没有项目",
        "Try a different name or search location.": "请尝试其他名称或搜索位置。",
        "This folder is empty.": "此文件夹为空。",
        "First 500 matches": "前 500 个匹配项",
        "items": "个项目",
        "Recents": "最近使用",
        "Macintosh HD": "Macintosh HD",
        "Favorites": "个人收藏",
        "Applications": "应用程序",
        "Documents": "文稿",
        "Downloads": "下载",
        "Desktop": "桌面",
        "Pictures": "图片",
        "Music": "音乐",
        "Movies": "影片",
        "Locations": "位置",
        "iCloud Drive": "iCloud 云盘",
        "Remove from Sidebar": "从边栏移除",
        "Enable Full Disk Access…": "启用完全磁盘访问权限…",
        "Red": "红色",
        "Orange": "橙色",
        "Yellow": "黄色",
        "Green": "绿色",
        "Blue": "蓝色",
        "Purple": "紫色",
        "Gray": "灰色",
        "Eject": "推出",
        "New Tab": "新标签页",
        "New Tab (⌘T)": "新标签页（⌘T）",
        "Close Tab": "关闭标签页",
        "Reopen Closed Tab": "重新打开已关闭的标签页",
        "Previous file": "上一个文件",
        "Next file": "下一个文件",
        "Done": "完成",
        "Open": "打开",
        "Open in New Tab": "在新标签页中打开",
        "Open Enclosing Folder": "打开所在文件夹",
        "Open With": "打开方式",
        "Other…": "其他…",
        "Choose Application": "选择应用程序",
        "Get Info": "显示简介",
        "Quick Look": "快速查看",
        "Rename…": "重新命名…",
        "Duplicate": "复制",
        "Copy": "拷贝",
        "Copy Path": "拷贝路径",
        "Paste Items": "粘贴项目",
        "Move Items Here": "将项目移到此处",
        "New Folder": "新建文件夹",
        "New Text File": "新建文本文件",
        "Add Folder to Sidebar": "将文件夹添加到边栏",
        "Refresh": "刷新",
        "Show in Finder": "在访达中显示",
        "Move to Trash": "移到废纸篓",
        "Compress": "压缩",
        "Extract ZIP": "解压 ZIP",
        "Cancel": "取消",
        "Go to Folder": "前往文件夹",
        "Go": "前往",
        "OK": "好",
        "Skip": "跳过",
        "Keep Both": "保留两者",
        "Replace": "替换",
        "Apply to all conflicts in this operation": "应用于此操作中的所有冲突",
        "Format": "格式",
        "Find": "查找",
        "Add after name": "添加到名称后",
        "Replace with": "替换为",
        "Rename": "重新命名",
        "Rename Items": "重新命名项目",
        "Move": "移动",
        "Extract": "解压",
        "Tag": "标签",
        "Replace Text": "替换文本",
        "Add Text": "添加文本",
        "Numbered Names": "编号名称",
        "Loading files": "正在加载文件",
        "Preparing…": "准备中…",
        "Creating item…": "正在创建项目…",
        "Checking names…": "正在检查名称…",
        "Kind:": "种类：",
        "Size:": "大小：",
        "Modified:": "修改日期：",
        "Where:": "位置：",
        "Tags:": "标签：",
        "A folder cannot be moved or copied inside itself.": "不能将文件夹移到或拷贝到自身内部。",
        "This ZIP archive is incomplete.": "此 ZIP 压缩包不完整。",
        "This archive format is not supported. Use a standard ZIP archive.": "不支持此压缩包格式。请使用标准 ZIP 压缩包。",
        "Encrypted or incomplete ZIP archives cannot be extracted.": "无法解压已加密或不完整的 ZIP 压缩包。",
        "The archive contains an unsafe file path.": "压缩包包含不安全的文件路径。",
        "Archives containing symbolic links or special files cannot be extracted.": "无法解压包含符号链接或特殊文件的压缩包。",
        "The archive contains inconsistent file headers.": "压缩包包含不一致的文件头。",
        "The archive contains inconsistent file paths or data.": "压缩包包含不一致的文件路径或数据。",
        "An archive cannot be created inside a folder it contains.": "不能在压缩包包含的文件夹中创建压缩包。",
        "The operation failed.": "操作失败。",
        "Could not open": "无法打开",
        "Choose a valid filename without slashes or colons.": "请输入不含斜线或冒号的有效文件名。",
        "Choose a valid starting number.": "请输入有效的起始编号。",
        "Names cannot be empty or contain /, : or a null character.": "名称不能为空，也不能包含 /、: 或空字符。",
        "Each item needs a different name.": "每个项目都需要使用不同的名称。",
        "already exists": "已存在",
        "Replace moves the existing item to Trash so Undo can restore it.": "替换会将现有项目移到废纸篓，以便撤销时恢复。",
    ]

    static let usesChinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true

    static func text(_ key: String) -> String {
        guard usesChinese else { return key }
        if let value = chinese[key] { return value }
        if key.hasSuffix(" items") {
            let count = key.dropLast(" items".count)
            if !count.isEmpty, Int(count) != nil { return "\(count) 个项目" }
        }
        if key.hasSuffix(" selected") {
            let count = key.dropLast(" selected".count)
            if !count.isEmpty, Int(count) != nil { return "已选择 \(count) 项" }
        }
        if key.hasSuffix(" names will change. File extensions are preserved.") {
            let count = key.dropLast(" names will change. File extensions are preserved.".count)
            if !count.isEmpty, Int(count) != nil {
                return "将更改 \(count) 个名称。文件扩展名会保留。"
            }
        }
        if let separator = key.range(of: " · ") {
            let operation = String(key[..<separator.lowerBound])
            let item = String(key[separator.upperBound...])
            return text(operation) + " · " + item
        }
        if key.hasPrefix("“"), key.hasSuffix("” already exists") {
            let name = key.dropFirst().dropLast("” already exists".count)
            return "“\(name)”已存在"
        }
        if key.hasPrefix("Choose what to do in "),
            let separator = key.range(of: ". Replace moves")
        {
            let path = key[key.index(key.startIndex, offsetBy: "Choose what to do in ".count)..<separator.lowerBound]
            return "请选择如何处理 \(path)。替换会将现有项目移到废纸篓，以便撤销时恢复。"
        }
        if key.hasPrefix("Eject ") { return "推出 " + String(key.dropFirst("Eject ".count)) }
        if key.hasPrefix("Close "), key.hasSuffix(" tab") {
            let title = key.dropFirst("Close ".count).dropLast(" tab".count)
            return "关闭 \(title) 标签页"
        }
        if key.hasPrefix("Rename "), key.hasSuffix(" Items") {
            let count = key.dropFirst("Rename ".count).dropLast(" Items".count)
            return "重新命名 \(count) 个项目"
        }
        if key.hasPrefix("Searching “") {
            return "正在搜索“" + String(key.dropFirst("Searching “".count))
        }
        if key.hasSuffix(" (default)") {
            return String(key.dropLast(" (default)".count)) + "（默认）"
        }
        if key.hasPrefix("Could not open ‘") {
            let value = String(key.dropFirst("Could not open ‘".count))
            return "无法打开“" + value.replacingOccurrences(of: "’.", with: "”。")
        }
        if key.hasPrefix("Could not restore ") {
            return "无法恢复 " + String(key.dropFirst("Could not restore ".count))
        }
        if key.hasPrefix("An item named ‘") {
            let value = String(key.dropFirst("An item named ‘".count))
            return "名为“" + value.replacingOccurrences(of: "’ already exists.", with: "”已存在。")
        }
        if key.hasPrefix("Wait for the file operation") {
            return "请等待文件操作完成后再推出“" +
                (key.split(separator: "‘").dropFirst().first.map(String.init) ?? "") + "”。"
        }
        if key.hasPrefix("Could not eject ‘") {
            let value = String(key.dropFirst("Could not eject ‘".count))
            return "无法推出“" + value.replacingOccurrences(of: "’: ", with: "”：")
        }
        return key
    }
}

@inline(__always)
func BL(_ key: String) -> String { BrowserLocalization.text(key) }
