# 嵌套迁移、批量管理与管理备份恢复 — 2026-10-24

## 结果

- 营销版本保持 `0.01`；Build `20261024185414`，上海时区日期格式 `yyyyMMddHHmmss`。最低 macOS 26.0，验证主机 macOS 27.0.1；尚未执行 macOS 26 运行验收。
- 最终完整回归：**197 项通过**，160 项 GitCore（254.786 秒）、37 项应用测试（23.311 秒）。见 [最终完整日志](evidence/related-advanced-full-tests.log)。第一轮 189 项通过（152 GitCore、37 应用），扩展后 193 项通过；之后增加 intent-to-add、递归新模块元数据保护、独立冲突索引及丢失目录索引的 GC 恢复保护，再做最终全量回归。见 [第一轮完整记录](evidence/related-advanced-full-tests-initial.log)、[存储边界测试](evidence/related-advanced-storage-tests.log)、[扩展索引与递归保护](evidence/related-advanced-index-guards-tests.log)。完成批次历史查看入口也包含于最终编译中，没有用后台状态测试冒充原生 UI 验收。
- [后台构建](evidence/related-advanced-background-build.log)、[后台运行](evidence/related-advanced-background-verification.json)、[签名](evidence/related-advanced-signature.log)、[部署目标](evidence/related-advanced-deployment-target.log)各自记录。本次进程 `isActive: false`、`visibleWindows: 0`，前台为 Codex；没有拉起测试界面。
- 所有写入和恢复在临时本地仓库完成；递归克隆使用临时本地源并逐次显式允许 file transport。没有写个人仓库、外部服务器或真实设置，没有源码 commit、push、发布或营销版本升级。

## 对照范围

本轮继续使用既有本地 Tower 源列表/紧凑列表与详情/右键与操作表单布局，核对官方 [Worktrees Overview](https://www.git-tower.com/help/guides/worktrees/overview/mac)、[Submodule Configuration](https://www.git-tower.com/help/guides/submodules/configuration/mac)，以及 [Git ls-files](https://git-scm.com/docs/git-ls-files)、[Git Worktree](https://git-scm.com/docs/git-worktree)、[Git Submodule](https://git-scm.com/docs/git-submodule)。没有激活 Tower、GitPico、浏览器或其他应用，没有新的前台截图/鼠标/键盘验收。

采用原生多选列表，工具栏 Selected 菜单和多选右键菜单进入批量操作；Review 表单列出每个目标、解析后的版本或目的地。运行时逐项显示 pending/running/completed/failed，允许 Stop After Current Item。批次历史保留结果；中断批次必须再次 Review Remaining，完成批次可查看。

Worktrees/Submodules 页面、Repository 菜单和 Quick Actions 均有 Management Backups 入口。列表包含操作、时间、路径、状态和诊断；恢复前展示完整影响路径。旧备份、新目录文件提取使用独立的审阅页，避免将旧记录当成可安全覆盖当前仓库的事务记录。

界面与 Tower 的像素、焦点、原生多选/快捷键、面板、亮色与 VoiceOver 验收仍未进行。与 Tower 完全一致的交互不能由这轮后台检查证明。

## 嵌套迁移

`RepositoryRelocation.swift` 在迁移前逐层解析仓库及其 `.git` 标记、实际 Git 目录、HEAD 和嵌套模块。Git 存储须属于已验证的公共存储、当前工作树的模块区域或本地 embedded `.git` 目录。

- 子模块 Move 先通过 Git mv 更新父仓库 gitlink/.gitmodules，再重接所有已初始化层级的 `.git` 文件和 `core.worktree`，最后暂存父 `.gitmodules`。未初始化的模块仍走 Git 的目录/gitlink 移动。
- Linked Worktree Move 保留工作目录，移动后原生 worktree repair 重接顶层，再逐个修复嵌套指针。该路径支持 Git 原生 worktree move 会拒绝的已初始化模块树，不通过 force 删除数据。
- Linked Worktree Remove 在完整备份后保留实际目录到私有恢复区，再对已不存在的原路径执行无 force 的 worktree remove。含模块的 administrative directory 与对象数据也先复制保留。
- 目标必须新建且不与现有工作树/存储重叠。当前/主工作树及锁定树仍不能移除/移动。递归检查操作状态、本地修改、未跟踪和忽略文件；删除/取消初始化还要求子模块实际版本已记录于父 gitlink。
- 初始化层级最多 16 层/512 个仓库；每个直接模块列表仍限 256 项。迁移不自动提交父仓库，也不下载远程数据。

## 批量操作

`RelatedRepositoryBatch.swift` 支持 1–128 个不同目标：Worktree Lock/Unlock/Move/Remove，以及所有现有子模块操作，包括递归 Init/Update/Sync、Fetch、固定版本 Checkout、URL/路径、Repair、Deinitialize 和 Remove。

批量 Move 以目的父目录加目标末级文件夹名生成路径，预览时拒绝名称碰撞和无效目标。批量 Checkout 在每个子仓库分别解析不可变提交；URL/版本/递归和本地传输选择明确显示在审阅页。

- 写入前预检所有目标，保留父 HEAD/index/config/.gitmodules 和 Worktree 注册状态。每项执行前再次核对预期父状态与该目标身份；前一项导致的预期元数据变化允许进入下一项。
- 顺序执行，不是跨仓库原子事务。每项开始/完成/失败都写入私有报告；首次失败停止，已完成项不自动反向执行，不吞掉 Git 错误。
- Stop 在当前项返回后停止。再次打开报告会重新预检剩余项，再明确 Run；已记录 completed 的项不重放。
- 若进程恰在 Git 已改变目标、但完成状态尚未写入报告时退出，不会凭空断言该项已完成。目标消失/迁移后无法按旧身份重试时，需要先恢复对应备份或重新选择目标。
- 批次及管理写入使用描述符级 advisory leases；进程退出会释放锁。Git 自己的 index/config 锁不会被当作过期锁删除。该协作锁不阻止其他 Git CLI 写入，因此各项和恢复仍做状态检查。

## 管理备份与恢复

`RelatedManagementRecovery.swift` 为 Worktree Move/Remove，以及除 Fetch 外的现有子模块管理动作保存新的 before/after 记录。Fetch 只下载对象，不虚构工作目录 Undo。Worktree Lock/Unlock 与原生外部迁移 Repair 仍是原生命令，没有添加通用的反向事务恢复承诺。

新的私有记录包括：

- 操作前目录内容副本、相关 Git 元数据及父索引/`.gitmodules`/本地配置。
- 操作后的目录内容指纹、文件内容、父 HEAD 和子仓库版本，作为恢复保护。
- HEAD/index 对象的隐藏引用，防止清理后丢失恢复所需对象。
- 应用/失败/恢复中/已恢复状态和诊断；属于另一个关联工作树的记录不会混进当前工作树列表。

目录 SHA-256 指纹覆盖路径、文件类型、权限、内容及链接目标；不跟随符号链接。每个目录最多 2 GB/100,000 项，配置/索引文件读取保持 32 MB 上限。目录按原权限复制到私有恢复区，记录文件为 0600、记录目录为 0700。备份和隔离副本不自动清理，会占用磁盘空间。

原地恢复要求：

- 记录和保存的数据仍一致，Git 操作空闲；新文件、忽略文件、新暂存、配置或子仓库版本变化会阻止恢复。
- 子模块恢复时父分支/HEAD 仍是保存时的状态，防止旧索引跨提交覆盖。Worktree 恢复不阻止主工作树独立推进，但原分支版本须未改变、未被另一个 Worktree 占用。
- 索引比较涵盖 stage/mode/object/path 和 assume-unchanged/skip-worktree/intent-to-add 等标记；Git 的纯 stat-cache 刷新不会误判为新暂存。扩展标记来自严格识别的 ls-files debug 记录；官方说明此格式可能变化，遇到未知格式时退回索引原始字节的严格比较，不放松暂存保护。
- 递归动作本次新初始化的模块也在 after-state 中记录 HEAD、索引和配置保护。恢复前若这些新模块发生空提交、新暂存或配置变化，同样拒绝覆盖；恢复取消初始化后仍保留已下载的模块 Git 数据。
- 恢复预览后再次修改内容或篡改保存的目录，会在 Apply 被拦住。

恢复先隔离当前受影响目录，再安装验证过的副本；不会递归删除实时工作目录。相关 Git 元数据文件使用它们各自的锁，重新比较后才安装。被 Git 锁或中断阻止的恢复保留 `restoring` 状态，重启后可重新审阅、继续已知的 before/after 过渡步骤；中途新增的文件或配置仍会拦截继续执行。恢复不自动提交，不静默重试不明结果，也不触碰未列出的文件。

## 中断及旧版记录

已完成/可捕获失败的原生操作有 after-state，可按保护恢复。进程在原生命令中途退出、来不及保存可信 after-state 时，自动原地恢复保守拒绝未知状态。

`ManagementBackupExtraction.swift` 允许在新目录提取保存的工作文件。提取前和 Apply 都验证备份，保留内容/执行权限/链接，移除副本中的所有 `.git` 管理标记，形成可检查的普通文件夹；当前目录、索引、配置不变，不自动重建注册或初始化模块。

`LegacyManagementRecovery.swift` 识别早期 raw Worktree administrative 备份、旧 submodule JSON，以及新备份中原目录已丢失的 Worktree 索引快照。旧格式没有可信 after-state；目录丢失时也不能凭空声称保存了工作文件。这些索引快照不会用于覆盖当前 index/config。它们的已保存索引可恢复到新 detached Worktree：创建明确标记的 recovery commit 和隐藏引用，但不改变当前分支/HEAD/index/config。gitlink 为未初始化目录；没有自动下载或假称旧备份包含未保存的工作文件。

## 新增验证

核心新增 17 项（原 143 项，最终 160 项），应用新增 3 项（原 34 项，最终 37 项）：

1. 两层模块的特殊路径/Unicode 迁移、原路径/索引/config/各层 HEAD 恢复，重开仓库可恢复。
2. 带嵌套模块的 Linked Worktree 迁移、迁移恢复、移除、注册及完整 Git 存储恢复。
3. 新暂存/新文件/旧预览拦截、其他进程 index.lock 保留、重启继续 restore、新修改阻止续写。
4. 移除后出现新路径时不覆盖；保存目录篡改在预览和 Apply 都被拒绝。
5. 多模块顺序移除允许预期的 `.gitmodules`/索引变化；逐份逆序恢复。
6. 第一项成功后第二项出现文件，批次停止；重开进程只继续未完成项。
7. Worktree 批量锁/解锁/移动、旧全局状态拦截、取消后的状态和恢复。
8. 两类旧格式恢复新树，父元数据不变，已有目的地拒绝。
9. 原分支被其他 Worktree 占用时拒绝恢复；主分支独立推进可恢复其他 Worktree；路径穿越记录拒绝。
10. Embedded `.git` 和外部 Git 目录混合的嵌套迁移及恢复。
11. 尚无 HEAD 的父仓库中，带暂存 gitlink 的配置备份/恢复。
12. 不同 Repository 实例争用管理 lease，被拒绝的一方不写入；释放后可执行。
13. 未知中断记录/新修改不能被原地覆盖，但可在新目录提取已保存文件，且无 Git 标记、拒绝覆盖目的地。

14. 空文件从 add -N 转为正式暂存，即使 stage/mode/object/path 不变也拦截旧恢复计划；含 v4 索引。
15. 递归初始化本次新增模块的 index 标记与空提交分别拦截恢复；撤回新增操作后可恢复到原先未初始化状态。
16. 主工作树存在合并冲突时，另一个干净工作树仍可迁移/移除；主树的未合并索引保持不变。
17. 工作目录丢失前的未提交暂存 blob 在移除注册及 GC 后仍被固定；保存索引可在新 detached Worktree 中恢复。

应用层覆盖新入口与审阅前无写入、旧仓库 token 拒绝、后台进度与完整结果持久化/刷新，以及恢复后的 Worktree 列表。没有调用真实文件面板或激活窗口。

清单仍为 **36 covered、28 partial、31 missing、3 unverified**。TP-073/076 的嵌套迁移、批量及备份恢复范围已更新；主仓库外部迁移后的批量指针修复、任意损坏指针重定位、force/prune/reuse 变体仍保留 partial。计数不是完成百分比。
