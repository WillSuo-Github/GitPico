# 历史文件恢复、原文件与 ZIP 导出验收 — 2026-10-24

## 结果

- 应用版本 `0.01`，Build `20261024142257`，按 Asia/Shanghai 日期时间生成；最低 macOS 26.0。
- 完整 `swift test` **135 项全部通过**：120 项 GitCore（122.002 秒）、15 项应用交互测试（11.183 秒）。本轮新增 12 项核心测试和 2 项应用路由/导出测试。见 [完整日志](evidence/historical-files-tests-full.log)及 [14 项集中验收](evidence/historical-files-focused-tests-final.log)。
- `./script/build_and_run.sh --verify` 成功；记录为 `isActive=false`、`visibleWindows=0`、前台 `com.openai.codex`。见 [后台构建](evidence/historical-files-background-build.log)与 [启动记录](evidence/historical-files-background-verification.json)。
- [签名检查](evidence/historical-files-signature.log)通过，[Mach-O](evidence/historical-files-deployment-target.log)最低系统为 26.0；实际测试机 macOS 27.0.1，**未在 macOS 26 运行验收**。
- Git 写验收全部使用新临时仓库，没有改个人仓库、写远程服务器、提交源码、push 或发布。源码仓库仍未有首次提交。

## Tower 对照与入口

没有激活 Tower、GitPico、浏览器或其他前台窗口。对照此前保存的 [本地 Tower 历史文件菜单](evidence/parity-tower-file-menu.txt)，并核对官方 [File History](https://www.git-tower.com/help/guides/commit-history/file-history/mac) 和 [Exporting Commits & Files](https://www.git-tower.com/help/guides/commit-history/export-commits/mac)。本地菜单中已有恢复到工作区、原文件导出和 Archive 动作；官方说明提交菜单可以导出该版本的完整文件树。

本轮接入：

- Changeset 文件右键：恢复、原文件导出、ZIP；删除条目明确使用删除前的第一个父提交。
- Tree 文件/目录右键：恢复、导出、ZIP。树支持多选，目录展开为该版本下的文件；保留文件历史入口。
- File History 行右键和 Actions 菜单：所选历史版本的恢复、原文件和 ZIP；跨重命名的恢复默认填入当前历史页面的路径，可在表单修改。
- 历史提交右键及详情工具栏：完整文件树导出与 ZIP。
- 分支、远程分支、标签右键：该引用当前捕获提交的文件导出与 ZIP。
- Repository → Export Historical Files：所选提交的原文件/ZIP。

恢复表单显示不可变源提交、路径、模式、体积和内容预览；单文件可指定工作区目标，选择只恢复工作区或同时暂存。导出表单支持文件选择预览、二进制说明、目录名称与子模块范围提示。文本预览最多 64 KB。原文件/ZIP 使用原生保存面板，目录导出选择父目录并新建命名目录。源快照准备后，引用再移动也不会改变待导出内容。

这里只证明这些入口已连接、编译及后端/路由行为。**没有实际前台菜单、原生面板、焦点、多选手势、布局和像素一致性验收。**

## 恢复与保护

`HistoricalFiles.swift` 用完整提交哈希固定版本，用 `ls-tree -r -l -z` 读取模式、对象、大小和 UTF-8 路径，用 `cat-file --batch` 读取 blob，按输出长度及对象元数据校验边界。路径参数使用字面 pathspec，不把冒号、方括号、空格和换行当成匹配表达式。选择中任一不存在的路径会报错，不会仅恢复其中有效部分。

恢复支持普通文件，包括二进制、空文件、可执行模式、已删除文件的早期版本，以及恢复到新路径。工作区内容使用当前仓库针对目标路径的 Git 过滤规则；例如索引保持 LF，工作文件按现有配置得到 CRLF。同时暂存时写入所选原始历史 blob 和模式，不使用文本编码替换。

真正执行复用上轮 `LocalChangePlan`：

- 默认保留暂存内容；选择同时暂存才替换对应索引条目。
- 替换现有已跟踪文件前，保存原文件字节、权限和索引，可从 Recover Local Changes 在重启后恢复。
- 受影响文件、索引、分支/HEAD 或仓库会话在预览后发生变化，拒绝写入。
- 不替换已有未跟踪/ignored 文件，不穿过符号链接或非目录父路径。
- 执行时取得 Git 索引锁；预览/备份、原子写入和中断恢复沿用 [本地修改恢复](VALIDATION-LOCAL-CHANGES-2026-10-24.md) 的约束。

恢复不会移动 HEAD、创建提交或自动删除重命名前后的另一路径。跨重命名的单文件映射在确认表单中明确显示目标。

## 原文件与 ZIP

`HistoricalExport.swift` 从快照直接写原始 blob 字节，不使用文本 diff 或 UTF-8 解码写回，也不应用 `export-ignore`、`export-subst` 或下载 LFS 对象。即使文件无法在 Raw 文本视图展示，仍可导出其原始二进制数据。

- 单个普通文件导出为指定的新文件，保留执行位。
- 目录/多项/完整树导出为新目录，保留仓库相对路径、普通文件和安全相对链接。
- ZIP 是标准 ZIP32 store 格式，含 CRC32、UTF-8 文件名和 Unix 文件类型/权限。目录结构保留仓库相对路径，不做文本转换；当前不压缩数据。
- 空项目可导出空目录或有效空 ZIP。
- 子模块作为空目录，并在确认表单提示其独立仓库内容没有包含；不发起外部下载。
- 会逃出导出根目录、指向 Git 行政路径或使用绝对目标的链接被拒绝；不会跟随链接读取外部文件。原文件单项导出要求普通文件，链接可选择 ZIP/目录导出。
- 在目标父目录的私有临时目录完成写入，以系统排他 rename 安装结果。目标文件、目录或链接已存在时失败，保留原目标；不会将部分新文件混入现有目录。

## 后台验收覆盖

新增核心测试实际验证：

1. 二进制、空文件、执行位、Unicode/空格/换行/字面匹配字符的原文件导出。
2. 恢复早期版本，保留部分暂存；不移动 HEAD；关闭重开仓库后恢复原工作文件和暂存内容。
3. 重命名后的目标映射、二进制执行文件、同时暂存，以及已删除文件从早期提交恢复到新目录。
4. 外部新编辑、未跟踪/ignored 目标、链接与越界路径拒绝；预览失败不写入真实文件。
5. main 前进后，已捕获快照仍是原提交；选择中有不存在文件时整组选项失败。
6. 原文件/目录导出忽略 Git archive 的替换/排除属性，保留真实 blob 和空文件；已有目标不被覆盖。
7. 独立系统 `/usr/bin/unzip` 解包，逐文件核对二进制/文本字节、空文件、执行位和相对链接。特殊换行文件名使用该工具已有的 `-^` 选项保留控制字符；ZIP 本身保留原名称。
8. 外逃链接拒绝；子模块提示和空目录行为；其恢复明确拒绝。
9. 两个 9 MB 文件的 18 MB 批量读取成功，超出单文件上限的选择在读取对象前被拒绝。普通 Git 调用仍默认限制 16 MB；历史批读取在验证总大小后显式放宽到 66 MB。
10. 当前 text/eol 配置下，恢复工作区使用 CRLF，索引和导出源仍是历史 LF 字节。
11. 空目录导出，并用独立 Python `zipfile` 检查空 ZIP。

新增应用测试核对真实 Store 的历史版本/路径/目标路由、忙碌状态、旧仓库会话拒绝，以及后台异步原文件导出写出的字节。测试不弹面板、不创建或激活窗口。旧自动 Stash、拖放、丢弃恢复、补丁、分支/远程、冲突与 Rebase 等完整回归也通过。

## 边界与清单

- 导出最多 10,000 条目、每文件 16 MB、总文件内容 64 MB；恢复仍受 512 路径 / 32 MB 总内容限制。
- 恢复只支持普通文件；符号链接、硬链接、Gitlink、sparse checkout 和 split index 沿用明确拒绝。导出支持安全相对链接，子模块只代表为空目录。
- 原文件指 Git 保存的原始 blob；LFS 指针仍是指针，没有下载资源的功能。没有保留所有文件系统 xattr、ACL 或任意元数据的承诺。
- ZIP64、压缩选项、任意大仓库/大文件、导出至现有目录并合并、覆盖现有导出目标均未提供。
- 删除条目自动取第一父提交；没有 merge 删除场景的多父版本选择器。Merge 提交的完整树导出正常可用，但 merge-commit patch 的父选择/导出仍未提供。
- 全引用 File History、外部打开历史文件、图片差异、完整键盘/VoiceOver 和新 UI 的前台验收继续在清单中。
- 98 项清单数量保持 30 covered、24 partial、41 missing、3 unverified；TP-029 更新恢复/导出已实现范围，TP-036 的原文件/ZIP 已补上，仍因 merge patch 变体保留 partial。没有把清单数量写成产品完成百分比。
