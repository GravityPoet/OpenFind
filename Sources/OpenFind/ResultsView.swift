import SwiftUI

/// 结果表格：可排序列、行图标、内容命中预览、右键菜单、双击/回车打开。
struct ResultsView: View {
    let results: [SearchResult]
    @Binding var selection: Set<SearchResult.ID>
    @Binding var sortOrder: [KeyPathComparator<SearchResult>]

    var body: some View {
        Table(results, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcon.icon(for: row.url))
                        .resizable()
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).lineLimit(1)
                        if let preview = row.contentPreview {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .width(min: 180, ideal: 260)

            TableColumn("位置", value: \.path) { row in
                Text(row.url.deletingLastPathComponent().path(percentEncoded: false))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.path)
            }
            .width(min: 160, ideal: 320)

            TableColumn("大小", value: \.size) { row in
                Text(row.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("修改日期", value: \.modified) { row in
                Text(row.modified, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 160)
        }
        .contextMenu(forSelectionType: SearchResult.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            // 双击行或回车：打开首个选中项。
            if let first = ids.first { FileActions.open(first) }
        }
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<SearchResult.ID>) -> some View {
        let urls = Array(ids)
        if !urls.isEmpty {
            Button("打开") { urls.forEach(FileActions.open) }
            Button("在访达中显示") { FileActions.revealInFinder(urls) }
            Divider()
            Button("拷贝路径") { FileActions.copyPaths(urls) }
        }
    }
}

/// 文件图标缓存，避免每次重绘都问系统要图标。
enum FileIcon {
    private static let cache = NSCache<NSString, NSImage>()

    @MainActor
    static func icon(for url: URL) -> NSImage {
        let key = url.pathExtension.isEmpty ? url.path as NSString : url.pathExtension as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        cache.setObject(image, forKey: key)
        return image
    }
}
