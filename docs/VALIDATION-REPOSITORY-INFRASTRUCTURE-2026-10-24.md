# 主仓库迁移、指针修复、强制清理与目录复用 — 2026-10-24

## 验证范围

营销版本固定为 `0.01`，Build 使用上海时区 `yyyyMMddHHmmss`，最低 macOS 26.0。本轮继续后台验证，没有激活 Tower、GitPico、浏览器或其他窗口，没有新的截图、键鼠、焦点或像素一致性验收。验证主机 macOS 27.0.1；不代表 macOS 26 运行验收。

继续沿用已记录的本地 Tower 紧凑列表、右键操作、详情与审阅表单，并核对官方 [Worktrees](https://www.git-tower.com/help/guides/worktrees/overview/mac)、[Submodule Configuration](https://www.git-tower.com/help/guides/submodules/configuration/mac)、[Git Worktree](https://git-scm.com/docs/git-worktree)、[Git Submodule](https://git-scm.com/docs/git-submodule)。没有复制第三方二进制实现或资源。

所有 Git 写操作均使用可删除的临时本地仓库；本地传输显式开启。没有写个人仓库、连接外部 Git 服务器、提交源码、push 或发布。

## 主仓库迁移

`MainRepositoryMigration.swift` 提供主工作目录与内嵌共享 `.git` 一起迁移的预览与执行。目标必须为现有父目录下的新路径，不能覆盖或嵌套现有工作树/存储；裸仓库和外置主 Git 目录不属于此入口。

- 迁移前核对全部可用 Worktree 的操作状态、自动 Stash 状态、目录内容与关联 Git 元数据。主工作目录中的暂存、未暂存、未跟踪和忽略文件一起保留，不自动暂存或提交。
- 完整原始副本保存于目标父目录的 `.gitpico-migrations/<UUID>/original-repository`，在迁移源和目标之外。移动后修复 linked Worktree、嵌套模块的 `.git`、`gitdir`、`core.worktree`、绝对 `commondir` 与已有 `config.worktree`，再核对模块 HEAD。
- 仓库库按目录前缀更新主目录及其下已收藏的模块路径，保留注册 ID、收藏、组和自定义名称；外部 linked Worktree 的路径不变。名称碰撞原子拒绝，不覆盖另一个注册。
- 原地恢复只允许保存的迁移后状态未改变，原位置未被其他数据占用。当前迁移仓库先保存到隔离区，原始副本重新安装，外部指针再恢复；锁阻塞后保留 `restoring` 状态，可从原位置历史继续。原始与迁移后副本都保留。
- 新文件、索引、配置或外部指针变化阻止原地恢复。此时可将原始副本恢复到全新目录：副本中的外部 Worktree 注册移入私有归档，不接管实时外部 Worktree；本地模块指针重接，实时仓库不变。
- 迁移中断且正常打开失败时，Welcome 的 Repair Repository Pointers 可选择主目录；Migration / Repair History 可指定原始/目标路径并加载错误中给出的 journal 目录，再恢复保存副本。

子模块自身额外创建的外部 linked Worktree 不属于主仓库的 Worktree 注册表，本轮没有自动迁移这类额外注册；需要先处理其注册与位置。不会自动改写任意 hook、include、alternates 或用户自定义配置中的绝对路径。新目录恢复隔离工作目录与复制的 Git 存储；自定义外部对象 alternate 依赖仍保留，不承诺这类仓库离线自包含。历史管理记录仍按原仓库位置绑定，不把迁移前旧记录静默重定向到新位置；需要时从原始保存副本恢复查看。

## 批量指针修复

`PointerRepairBuilder.swift` 从主目录内的 `.git` 元数据离线扫描，允许 Git 尚不能正常打开时预览。主仓库、linked Worktree 和每级模块分别列出已验证 Git 存储与预期工作目录；用户可填写已移动目录并再次 Review。

- 在所属主仓库/Worktree 的模块存储、或已验证 embedded `.git` 内重接。拒绝路径符号链接、两个目标争用同一存储、其他实时仓库以及不明确的旧根路径。
- 主目录的外部移动可由 linked 指针推断旧路径；不明确时需要显式填写。模块单独移动仍必须在其父仓库内，路径映射更新并暂存父 `.gitmodules` 与 gitlink，不提交父仓库。修改前要求对应 `.gitmodules` 工作副本与索引一致，避免覆盖手工编辑。
- 缺失/未初始化项保留注册和路径信息，不凭空重建工作文件。存在的外来 Git 指针不能通过勾选 Replace 选项接管。
- 保存 before/after 元数据，先获得每个受影响文件的锁，再执行内容核对和写入。原有锁由创建者保留。中断可从历史审阅继续，或恢复原始元数据；只接受已知 before/after 状态，不覆盖后来编辑。

这是一批受保护的文件过渡步骤，不是文件系统跨路径原子事务。恢复原指针可能使此前手动搬动的目录再次断开；审阅页明确说明这一点。

## 强制清理

Worktree 的 Force Remove、Unlock and Force Remove 与 Prune Missing Registrations 接入原有多选批次、逐项报告和恢复入口。主/当前 Worktree 仍不允许移除；锁定树需要明确选择解锁并强制移除。Prune 只处理已选缺失目录，执行时路径重新出现则停止，不调用全仓库无条件 prune。

子模块增加 Force Deinitialize、Force Remove 和 Archive Retained Git Storage。强制清理前保存完整工作目录与 Git 存储，包含忽略/未跟踪文件、冲突各阶段索引和操作状态。父仓库仍须操作空闲，`.gitmodules` 的冲突/未暂存编辑仍需先处理；不会承诺自动处理任意损坏的模块图。

- 强制清理保存 HEAD/每个已索引对象，索引中的非 gitlink 对象包括冲突各阶段使用独立引用保活；不将冲突索引错误转换成单一树。
- 清理 embedded 模块时先完成备份再吸收 Git 目录。保留存储的归档或重新克隆会检查本层及嵌套 Git 存储是否仍被其他工作目录/linked Worktree 使用，有实时使用者则拒绝清理。
- Management Backups 可恢复原地状态，也能把含完整对象存储的子模块备份恢复成全新独立仓库。保留文件、暂存和 merge 状态，嵌套标记重接；外部 Worktree 注册只归档在副本中。仅有索引的旧备份仍走原有独立 Worktree 恢复，不冒充完整仓库。

批次顺序运行，遇到失败停止，已完成项保留结果；不是跨仓库原子操作。未知原生命令中断结果仍需提取或独立恢复，不能盲目覆盖当前状态。

## 目录复用

Worktree 创建可以显式复用现有空目录，预览和执行都检查没有新文件。分支占用、路径重叠和版本保护继续生效。

子模块添加明确区分五种模式：

| 模式 | 行为 |
| --- | --- |
| New Directory | 原有新目录克隆；发现保留存储时要求明确选择模式。 |
| Existing Empty Directory | 验证空目录后原子移除空壳，再克隆；若目录变为非空则保留并停止。 |
| Existing Repository | 接入已有嵌套仓库的当前 HEAD，保留其索引、文件和分支，不强制切换/重克隆。 |
| Retained Git Repository | 用保留的对象与索引填充新目录或空目录，不联网；冲突索引需要先恢复到独立目录解决。 |
| Back Up Retained Repository and Clone Fresh | 完整保存旧 Git 数据，再从明确 URL 克隆；可恢复旧历史和暂存到新独立目录。 |

复用当前仓库/保留仓库时，已有 origin 必须匹配审阅 URL，分支字段须空或为当前分支。目录、存储、父 HEAD/index/配置变化会使预览失效。不会覆盖非空普通目录，也不把父仓库中的其他文件擅自变成子模块。

## 界面入口与限制

Repository 菜单、Worktree 页标题菜单和 Quick Actions 提供 Move Main Repository、Repair Repository Pointers、Migration / Repair History。Welcome 提供原始修复入口。强制清理沿用列表右键/Selected 菜单与批次审阅；目录复用在原创建/添加表单中明确选择。

每份目录备份/迁移指纹最多 2 GB、100,000 项；元数据沿用 32 MB 读取上限，递归扫描有深度与仓库数量限制。备份、隔离目录和对象引用不自动删除，会占用磁盘。GitPico 的 advisory lease 不阻止外部 Git CLI，因此执行和恢复均重新校验状态。没有伪造超限支持、任意腐坏重建、外部配置重写或界面完全一致的结论。

## 回归覆盖

本轮新增 17 项 GitCore 测试与 2 项应用层测试：

- 主仓库、两层模块与 linked Worktree 迁移，暂存/未暂存/忽略文件保持、外部 main/config.worktree 指针修复、原位恢复。
- 旧预览、新文件、原位置占用、主/linked index.lock 防护；恢复被外部锁中断后重开继续；原始副本独立恢复。
- 手动搬动主目录、linked Worktree 和模块后的批量修复、路径映射暂存、恢复原始元数据、锁后继续、拒绝外来 Git 存储。
- 保留/已有仓库复用不联网并保留当前索引和文件；备份旧存储后从不同源克隆，旧历史和暂存仍可恢复。
- Worktree 与子模块空目录复用；预览后新文件不被覆盖；强制处理锁定树与仅缺失注册清理，执行时目录重现停止。
- 子模块 merge 冲突各阶段、操作状态、未跟踪文件在强制清理后可完整恢复，保存仓库可恢复到新目录；未初始化空壳从保存索引重建文件。
- 本层及嵌套模块的外部 linked Worktree 阻止保留存储删除；替换为符号链接不能让强制清理接管另一个工作树。
- 库的主/子目录前缀迁移保留 ID/收藏/组/名称，碰撞不落盘；Welcome 修复入口和旧会话迁移请求拒绝写入。

开发测试曾发现并修复：Git 不接受已有空目录的 submodule add、复制的 Git 配置仍指向旧工作目录、递归清理检查误拦截合法指针修复。首次新增批次测试将“返回 stopped 报告”误断言成抛错，已按实际批次 API 检查每项失败状态。历史失败日志保留，未冒充最终通过记录。

## 最终证据

- 最终源码专项回归：新增的 17 项 GitCore 测试全部通过，64.698 秒。见 [专项日志](evidence/infrastructure-focused-final-tests.log)。空目录/存储边界及应用入口额外 5 项通过，见 [边界日志](evidence/infrastructure-final-edge-tests.log)。
- 最终完整回归 **216 项通过**：177 项 GitCore（275.348 秒）、39 项应用测试（23.617 秒）。见 [完整日志](evidence/infrastructure-full-tests.log)。最终专项与完整测试覆盖同一份源码；初始断言问题及递归扫描修复前的失败分别保留于 [初轮日志](evidence/infrastructure-full-tests-initial.log)、[中间回归](evidence/infrastructure-full-tests-before-lock-guard.log)、[扫描修复前日志](evidence/infrastructure-full-tests-before-scan-fix.log)。
- 最终开发包 **0.01 / 20261024203417**。见 [后台构建](evidence/infrastructure-background-build.log)、[实际 bundle 元数据与二进制指纹](evidence/infrastructure-bundle-metadata.json)。签名会改变 Mach-O 的签名数据；只在临时副本中移除签名后，已打包程序与当前编译产物 SHA-256 一致，实际包未被移除签名。
- [后台运行证据](evidence/infrastructure-background-verification.json)：`isActive: false`、`visibleWindows: 0`、前台 `com.openai.codex`。没有激活或展示测试窗口。
- [签名验证](evidence/infrastructure-signature.log)通过，为本地 ad-hoc 开发签名，不是发布/公证验收。[实际部署目标](evidence/infrastructure-deployment-target.log)为 macOS 26.0；主机 27.0.1，macOS 26 运行仍未验收。
- 98 项功能清单更新为 38 covered、26 partial、31 missing、3 unverified。TP-073、TP-076 标记为上述有边界的功能覆盖，不代表所有 Tower 功能、原生界面或特殊 Git 布局均已对齐。
