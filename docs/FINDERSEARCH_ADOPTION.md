# FinderSearch adoption

Browser source adapted from https://github.com/zeusinsight/FinderSearch at
`021ad61679fbb1c1f18f9dc57a7d1bbc6883863e` (MIT). Copyright 2026 zeusinsight.
The license is shipped in `ThirdPartyNotices/FinderSearch.txt`.

The native browsing views, tabs, file operations, conflict handling, undo,
background icon/thumbnail loading, bounded navigation caches and directory
metadata implementation are reused in the separate `OpenFindBrowser` module.
Search requests are supplied by OpenFind; fsearch is not installed or spawned.
OpenFind retains its full search and document/archive content search.

Durable base snapshots keep the existing `OFZ1`/`OFIX` envelope for compatibility,
while the node and string-pool section is written to a checksummed `nodes-v1.bin`
sidecar and read through `mmap`. A loaded `SearchIndex` therefore uses the mapped
node store directly instead of materializing `[IndexedFileNode]`; invalid or absent
sidecars fall back to the validated heap decoder.

## 2026-10-13 复核与补齐

- 浏览器动态提示改用固定翻译模板，覆盖起始编号、同名冲突、恢复路径、推出错误和无障碍名称；文件名及应用名称作为参数保留原文。语言选择与主应用一致。
- 浏览器操作菜单补齐撤销、重做和前往文件夹。`⌘Z` / `⇧⌘Z` 操作文件历史时避开文本编辑器；`⇧⌘G` 打开前往文件夹。
- 打包及归档验收均检查 `ThirdPartyNotices/FinderSearch.txt` 与源码中的完整许可一致。
- 构建及安装阶段使用 macOS Trash API 回收所属目录，输出恢复位置并检查父目录的 device/inode；清理独立临时夹具后已核对内容和旁系路径。
- 映射节点读取统一在有界字节缓冲区内解码，加载时验证父索引、名称索引并统计目录标志，避免仅统计文件数量时解码所有名称。

### 实测范围

测试使用本机冻结缓存的独立副本（167,059 个节点），两侧使用同一份已校验的名称加速索引。Release 模式，各 3 个独立进程；以下为中位数。查询测试不进行文件遍历或文件内容提取。

| 指标 | 普通节点加载 | 映射节点加载 |
| --- | ---: | ---: |
| 加载耗时 | 14 ms | 14 ms |
| 加载产生的 physical footprint 增量 | 20.2 MiB | 11.8 MiB |
| `测试` 查询 | 465 ms | 454 ms |
| `sidx` 模糊查询 | 67 ms | 72 ms |

`swift`、`readme`、`测试`、`sidx` 四组查询的结果数量与顺序 SHA-256 在所有样本中一致。`swift`、`readme` 的本轮耗时低于日志的 1 ms 精度。逐节点核对了全部字段；同一进程交替执行 5 次，单独的节点解码中位耗时由 11.18 ms 降为 5.16 ms。校验和、父索引、名称索引损坏均被拒绝。

本轮另运行了 9 项浏览器翻译/菜单/模拟卷回归和 4 项模糊搜索回归，均通过。前一轮的 655 项主测试、108 项浏览器测试属于历史结果，本轮未重跑涉及文件删除的旧测试。性能样本存在系统负载波动，上述结果不代表全机所有规模或跨产品性能结论。
