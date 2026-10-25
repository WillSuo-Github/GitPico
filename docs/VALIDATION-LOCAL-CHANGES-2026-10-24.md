# 丢弃恢复与补丁传输验收 — 2026-10-24

## 结果与环境

- 应用版本 `0.01`，本轮打包 Build `20261024140543`，按 Asia/Shanghai 日期时间生成；没有升级营销版本。
- 最终 `swift test`：**121 项通过**，其中 108 项 GitCore 测试（108.496 秒）、13 项应用交互测试（10.245 秒）。参数化用例包含于测试项中，没有重复计数。完整输出见 [最终测试日志](evidence/local-changes-tests-final.log)。
- `./script/build_and_run.sh --verify` 构建、打包、签名、后台启动通过。记录为 `isActive=false`、`visibleWindows=0`、前台 `com.openai.codex`，见 [后台构建日志](evidence/local-changes-background-build.log)和 [启动状态](evidence/local-changes-background-verification.json)。
- [签名校验](evidence/local-changes-signature.log)通过；[Mach-O 平台信息](evidence/local-changes-deployment-target.log)为最低 macOS 26.0。实际测试机是 macOS 27.0.1，**不代表已在 macOS 26 运行验收**。
- 全部 Git 写入用临时仓库；没有写个人仓库、外部服务器，也没有源码 commit、push、发布或公证。源码仓库仍未有首次提交。

## 对照依据和入口

本轮没有激活 Tower 或 GitPico 的交互窗口，也没有控制鼠标或键盘。沿用之前已抓取的本地 Tower 菜单证据，并核对官方 macOS 的 [Undoing Changes](https://www.git-tower.com/help/guides/working-copy/undo-changes/mac) 和 [Creating & Applying Patches](https://www.git-tower.com/help/guides/working-copy/patches/mac)。官方入口包括工作区文件右键丢弃、差异块/选中行丢弃、Working Copy 右键应用补丁、历史提交右键保存补丁。这里对齐了动作位置和确认流程，**没有新的像素或真实鼠标验收**。

GitPico 新入口：

- 工作区文件右键 `Discard Local Changes…`，支持当前多选；菜单或侧栏 Working Copy 右键也可丢弃全部文件。
- 未暂存差异的块标题 `Discard Chunk…`；统一或并排差异中选中行后 `Discard Lines…`。保留原来的暂存动作；选中行的更多菜单可以保存补丁或清除选择。
- Working Copy 菜单与 Undo 工具栏菜单中的 `Recover Local Changes…`，按时间展示备份、文件列表和状态。
- Working Copy 菜单、侧栏右键中的 `Apply Patch…`；文件右键分别导出暂存/未暂存内容，历史提交右键 `Save Patch as File…`。也有全范围导出入口。
- 丢弃所选文件快捷键 `⌘⇧Delete`。确认表单显示作用范围、文件与本地备份说明；执行前重新核对仓库会话。

## 丢弃和恢复实现

`LocalChangeRecovery.swift` 为选择范围保存修改前/预期修改后的文件字节、权限、完整索引及分支/HEAD。整文件丢弃有两种明确范围：

1. `Unstaged Changes Only`：文件恢复到索引，暂存内容不变；未跟踪文件会被移除。
2. `Staged and Unstaged Changes`：文件及对应索引条目恢复到 HEAD；包含新增文件删除、暂存删除及重命名的源/目标。未创建首次提交的仓库也支持恢复新增条目。

未暂存块/逐行丢弃先核对完整渲染差异，再由已有逐行补丁算法生成逆补丁，在隔离目录预演，确认后才更改真实文件。暂存差异上的逐行动作仍是取消暂存，不混入丢弃。

真正写文件前，备份会写入每个 worktree 的 Git 目录 `gitpico/local-changes/`。目录权限 0700、记录 0600；文件写入会同步到磁盘，原子替换记录。隐藏树引用 `refs/gitpico/local-changes/<id>/before|after` 保持索引对象可达，通过实际 GC 后恢复的用例验证。

写入时独占 Git 的 `index.lock`，重新核对索引和受影响文件，然后以预先写好的临时文件替换目标，最后原子安装新索引。出现写入失败时尽量回滚已写入的文件；若检测到新的外部编辑，不再用旧内容回滚覆盖它，原始恢复记录仍保留。

恢复要求原分支/HEAD，并检查受影响文件和完整索引的内容及标记。索引的时间、inode 缓存刷新不会误判为暂存修改；对象、模式、stage、名称或 entry flags 的变化仍会拦截。`prepared` 记录允许每个文件处于保存前或预期保存后状态，覆盖进程中断在多文件写入中间的情况。已恢复记录会标记 `restored`，重复恢复被拒绝。

## 补丁导入导出实现

`PatchTransfer.swift` 用 Git 解析补丁、NUL 分隔的路径和重命名扩展头。先验证相对路径、符号链接、索引状态、容量等，再在隔离工作区和显式临时索引中执行 `git apply --check` 及预演。预演不改真实文件、真实索引或 HEAD；准备索引结果可能向 Git 对象库写入内容对象。

导入表单提供 `Working Copy`、`Index Only`、`Working Copy and Index` 及逆向应用。两者一起应用时要求索引与工作文件基线一致；在临时索引刷新 stat 缓存，避免编辑器原子保存后的误拒绝。任一文件补丁不能应用时，整个预览失败，不会先落下一部分修改，也不会产生 `.rej` 文件。确认后的写入同样有持久化恢复备份。

导出覆盖暂存/未暂存范围、选择文件、选择行，以及单个非 merge 提交的 mailbox 补丁（包括 root 提交和二进制内容）。未跟踪文件包含于未暂存导出；文件内容使用 Data，不通过 UTF-8 替换写回。原生保存面板写出准确字节，并拒绝替换现有文件。选择行导出会再次核对差异。

## 新增用例与回归

本轮新增 21 项测试：19 项 GitCore、2 项应用测试，覆盖：

- 部分暂存文件只丢弃后续编辑，重开后恢复同样的暂存和工作文件内容；备份文件权限。
- 全范围丢弃及恢复重命名、删除、未跟踪二进制、异常/Unicode/换行文件名、可执行权限、未提交仓库的新增暂存条目。
- 单块和逐行丢弃只影响所选内容，其他修改与索引保留。
- 外部新编辑、真正的新暂存、分支切换、索引锁、符号链接、外部父目录链接、Gitlink 和越界路径保护。
- 模拟 prepared 记录的中途多文件写入；切回原分支后的 stat 刷新；GC 后仍可恢复未提交索引对象。
- 三种补丁目标的真实 Git 读回与恢复；二进制创建、删除、重命名、CRLF、无结尾换行、执行位、逆向应用、行导出、root/普通提交导出。
- 多文件补丁中一项冲突不写入其他文件；已存在或 ignored 目标保护；行政路径和恶意链接补丁拒绝；内容转换属性提示与 Index Only 路线。
- 实际 Store 多选路由、旧仓库会话拒绝、busy 状态；导出字节准确且不覆盖已有目标。

此前自动 Stash、拖放、三方冲突、Rebase、Reflog、分支/标签/远程管理等测试也全部通过。应用测试没有创建窗口或弹出文件面板。

## 明确边界

- 当前只支持普通文件；符号链接、硬链接、submodule/Gitlink、稀疏 checkout、split index 会明确拒绝。文件内容及 POSIX 权限被保留，不是包含所有 xattr/文件元数据的系统备份。
- 每个文件最多 16 MB，每次选择最多 32 MB / 512 个路径，补丁最多 16 MB，索引最多 32 MB；补丁文本预览最多 256 KB，导出文件包含完整字节。
- 对工作区应用补丁（也包含块/行丢弃）时，已有 text/eol、encoding、clean/smudge 属性或 `core.autocrlf=true` 会明确要求改用 Index Only/命令行 Git。原始 CRLF 字节本身支持且有测试。整文件丢弃通过 Git 内容过滤读取目标，独立于这项补丁限制。
- Mailbox 导入应用文件改动，不创建提交或保留作者/提交说明；没有 git-am 序列、三方补丁冲突编辑或部分成功模式。Merge 提交导出、历史原文件/ZIP 导出仍待补。
- 这是专门的本地恢复入口；checkout、stage、stash 等全部动作统一进系统式 Undo/Redo 的模型还没完成。
- 备份和隐藏引用没有自动清理，不随普通 clone 迁移；它们占用本地空间。没有测试掉电、磁盘损坏或绕过索引锁的其他进程在最终写入瞬间并发替换目录。
- 没有前台菜单、面板、焦点、真实鼠标、VoiceOver、亮色和全部 SwiftUI 布局验收。后台启动绕过交互场景，只证明签名、进程、版本及零窗口/不激活约束。

清单更新为 98 项：30 covered、24 partial、41 missing、3 unverified；不同清单项大小不同，这不是产品完成百分比。
