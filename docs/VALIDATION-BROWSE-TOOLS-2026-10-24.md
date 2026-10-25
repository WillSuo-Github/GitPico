# 全部/忽略文件、Quick Actions、外部工具验收 — 2026-10-24

## 结果

- 版本保持 `0.01`，Build `20261024171620`。最低 macOS 26.0；实际检查运行于 macOS 27.0.1，未完成 macOS 26 运行验收。
- 完整 `swift test`：**161 项通过**，130 项 GitCore（119.604 秒）、31 项应用测试（12.514 秒）。本轮新增 9 项核心、4 项应用用例。见 [完整日志](evidence/browse-tools-tests-full.log)。
- 收尾集中回归再次通过 13 项，并编译了文本截断展示修正，见 [最终集中日志](evidence/browse-tools-focused-tests-final.log)。之后的会话空状态/加载代次及无用绑定修正以最终构建验证；未重复整个测试集，也未将其当成前台 UI 验收。
- [后台构建](evidence/browse-tools-background-build.log)、[运行记录](evidence/browse-tools-background-verification.json)、[签名](evidence/browse-tools-signature.log)、[部署目标](evidence/browse-tools-deployment-target.log)分开保留。最终进程未激活、零可见窗口，没有启动真实 diff/merge GUI。
- Git 写入全部用临时仓库；工具运行测试只启动临时无界面脚本。设置测试注入临时路径，没有改用户真实工具偏好，也没有源码 commit、push、发布或外部服务器写入。

## Tower 对照

本轮没有拉起 Tower、GitPico 或浏览器窗口。核对官方 [Quick Actions](https://www.git-tower.com/help/guides/manage-repositories/quick-actions/mac)、[Inspecting Changes](https://www.git-tower.com/help/guides/working-copy/inspect-changes/mac)、[Diff & Merge Tools](https://www.git-tower.com/help/guides/integration/diff-tools/mac)，并沿用之前本地菜单证据。

对齐了工作区列表过滤、`⌃⌘M/I/U`、`⌘⇧A` 调色板入口，以及从文件/冲突位置调用外部工具、在设置中选择助手程序的路径。实现使用自己的参数数组和独立副本协议，没有写入 Tower 的 Git 配置或复制其脚本/素材。真实工具 GUI、像素、焦点及鼠标验收仍未执行。

## 全部与忽略文件

`WorkingFileBrowser.swift` 使用 NUL 分隔的 Git status/ls-files，合并已跟踪、未跟踪、删除条目及可选忽略条目，保留空格、冒号、方括号、Unicode、换行等字面路径。识别 assume-unchanged、skip-worktree 标记，不将这些文件虚构成有暂存改动。

- 工作区默认只显示修改；列表菜单与 Working Copy 菜单提供 Show All Files、Show Ignored Files、Show Assume-Unchanged Files。
- 忽略文件可独立显示，不要求先开启全部文件。assume-unchanged 也可独立显示；skip-worktree 在全部文件中标记。
- 未修改/忽略文件进入原文件预览；文本最多展示 256 KB，不在 UTF-8 字符截断处误判为二进制。二进制显示体积说明。普通文本选择和复制可用。
- 文件名过滤、状态排序、多选、文件历史、默认编辑器、Finder 和复制路径保留。隐藏当前条目时清理失效选择和差异状态。
- 忽略文件没有普通暂存复选框，不加入 Stage All。右键 Force Add Ignored Files 打开单独路径预览，再用临时索引准备，并复用持久化本地恢复备份；预览后的文件/索引变化拦截应用。
- 默认最多 50,000 个路径。Git 输出保持既有默认 16 MB 限制；没有大仓库性能承诺。

符号链接、硬链接和目录不能作为普通文件预览/强制添加快照读入；submodule/嵌套仓库的内部浏览和管理仍是独立缺项。

## Quick Actions

`QuickActionsSheet.swift` 为紧凑搜索/选择列表，工具栏与 Navigate 菜单支持 `⌘⇧A`。搜索名称、路径和类型说明，按词及大小写/重音折叠匹配，结果最多 150 条。

提供：视图导航、文件/文件历史、分支与远程分支 checkout、标签/引用历史、远程设置、Stash 应用、已加载提交的消息/作者/哈希，以及输入 7–64 位十六进制时按需解析提交。显示与当前上下文可用性相符的 Stage/Unstage、Stash、丢弃、恢复、补丁、分支/标签、Merge/Rebase、比较、Git Undo/Redo 和工具设置/会话入口。

上下箭头、Return、Escape 和双击路由接通。运行前核对仓库会话；文件跳转开启全部文件并刷新选择；本地分支走已有自动 Stash 保护，远程分支走跟踪分支创建表单。丢弃、Stash、历史改写等保留已有预览/确认流程，不把查询文本解释为 shell 命令。

当前是平铺动作列表；Tower 的 Tab 分层选项和 submodule 动作尚未提供。原生键盘/IME/焦点没有真实前台验收，搜索与选择/派发逻辑有后台证据。

## 外部 diff/merge

### 配置与启动

Settings → External Tools 及独立工具设置表单提供两个命令配置：diff 和 merge 的绝对可执行路径、JSON 参数数组。含 FileMerge/opendiff 预设，也可选择其他工具的 CLI helper。读取程序是否存在不会启动它；只有 Launch Tool 才创建进程。

支持 `{local}`、`{remote}`、`{base}`、`{merged}`。模板只解析一次，原文件名中的花括号、空格、换行或 `$()` 保持字面值，不进行 shell 插值。diff 必须指定 local/remote；merge 还必须指定 merged。无效占位符和 NUL 拒绝。设置保留期望值及磁盘内容检查，拒绝旧编辑覆盖新设置；损坏/不支持版本保留原文，需修复并 Reload。

### 独立会话

每个 worktree 的 Git 目录下建立私有 `gitpico/external-tools/<UUID>/`，保存 local/remote/base/merged 文件、原冲突快照、HEAD、路径、时间及状态。侧文件为只读副本，输出可写；不会把真实工作文件作为 merged 参数传入。启动前重新检查会话文件。

工作区、索引、历史 Changeset 和任意版本比较提供外部比较入口。支持二进制副本、根提交空侧、删除空侧和重命名旧路径。未暂存比较使用当前 Git 过滤规则生成索引侧内容；历史比较保留不可变版本对象。比较副本的编辑不会写回真实工作区。

冲突编辑器提供 External Merge。当前要求普通 UTF-8 current/incoming 文件，base 缺失时用空文件；binary、modify/delete、symlink、submodule 合并仍需内部整文件动作或其他 Git 工具。

### 结果确认与生命周期

工具只编辑独立 merged 结果。先保存并关闭外部应用，Reload Saved Result 查看，再 Apply Result。应用前检查：

- 结果等于实际预览过的字节；新保存版本要求重新加载确认。
- 原分支/HEAD、Git 操作、原冲突索引、工作文件字节和权限仍一致。
- 输出是普通 UTF-8 文本、无 NUL/冲突标记且不超过 1 MB；路径和侧目录不经过被替换的链接。

通过后才写回并暂存，不自动完成 Merge/Rebase 或创建提交。Git filter/add 失败时沿用内部冲突保存规则：已编辑结果可能留在工作区，会话里的原数据和输出仍保留，不自动重放。

会话可重启后在 External Tool Sessions 继续选择。显示进程状态、退出码和最多 64 KB 诊断预览；失败不删除结果。Delete Session Files 需要确认，只删私有副本；进程仍运行时禁止删除/应用。部分 CLI helper 可能先于 GUI 退出，界面明确要求关闭外部应用再删除文件。重启后不能推断旧 GUI 是否仍打开，没有伪造完成状态。

当前没有目录 diff、第三方工具自动扫描/全套预设、系统级进程隔离或真实厂商 GUI 兼容性验收。自定义工具是用户选择的本地程序；不是不可信代码沙盒。会话无自动清理，不随普通 clone 迁移。

## 新增后台证据

核心 9 项覆盖：

1. 全部/忽略/特殊标记/删除/异常文件名、忽略规则否定和条目上限。
2. Force Add 只影响显式选择的忽略文件，预览不改索引，内容变化拒绝，之后可恢复索引。
3. 预览不跟随链接，不读取行政路径/越界路径/缺失对象。
4. 外部工作区/暂存区快照及自动重命名旧侧。
5. 根提交和二进制比较副本。
6. 无界面 helper 的准确 argv、特殊文件名字面行为、无 shell 注入、缺失程序及非零退出诊断。
7. 合并输出尚未应用时源文件/索引不变，重启后显式应用并暂存，重复应用拒绝。
8. 标记、新编辑、新操作、被替换链接拒绝。
9. 真实无界面 merge helper 只写副本，重复启动拒绝；预览后新输出拦截，再明确应用。

应用 4 项覆盖：可见文件状态/标记/选择、忽略文件不混入 Stage All、Quick Actions 搜索及保留丢弃确认、旧仓库会话拒绝、干净文件跳转，以及工具偏好持久化/旧稿/损坏/无效参数保护。测试未调用原生打开面板、Finder、默认编辑器或真实 FileMerge。

## 清单边界

98 项更新为 **33 covered、26 partial、36 missing、3 unverified**，不是完成百分比。TP-010 覆盖本轮有边界的浏览/强制添加；TP-005 和 TP-018 保留 partial，分别注明分层/子模块动作和真实 GUI/目录比较/非文本合并的剩余范围。

macOS 26 运行、完整原生键盘/VoiceOver、亮色/像素、大仓库、Worktree/子模块、托管账号/PR 等仍在 [完整清单](TOWER-PARITY-2026-10-24.md) 中，没有因这轮增加入口就标成全部完成。
