# Worktree 与子模块管理验收 — 2026-10-24

## 结果与证据

- 营销版本固定 `0.01`，本轮 Build `20261024175436`，最低 macOS 26.0。实际验证主机为 macOS 27.0.1；没有完成 macOS 26 运行验收。
- 最终完整 `swift test`：**177 项通过**，143 项 GitCore（145.821 秒）、34 项应用测试（14.169 秒）。见 [完整日志](evidence/worktrees-submodules-full-tests.log)。先前 176 项完整回归通过后，修正关联 Worktree 子模块的独立存储路径，新增该组合用例，再执行最终完整回归；先前结果在 [初次完整日志](evidence/worktrees-submodules-full-tests-initial.log)。
- [后台构建](evidence/worktrees-submodules-background-build.log)、[运行状态](evidence/worktrees-submodules-background-verification.json)、[签名](evidence/worktrees-submodules-signature.log)、[部署目标](evidence/worktrees-submodules-deployment-target.log)分别记录。本次运行 `isActive: false`、`visibleWindows: 0`，前台仍是 Codex。打包只更新上海时区 `yyyyMMddHHmmss` Build Number。
- 所有 Git 写入均在临时仓库，包括递归克隆的本地源仓库。没有个人仓库、外部服务器写入，没有源码提交、推送或发布。应用测试注入临时仓库库和偏好文件。
- 全部验证在后台进行。没有激活 Tower、GitPico、浏览器，也没有调用 Finder、文件面板或默认编辑器。后台验证走禁止激活、零窗口的入口；这只证明该入口与构建状态，不等于新的 SwiftUI 页面已经完成原生 UI 验收。

## Tower 对照与界面

沿用此前本地 Tower 的紧凑源列表、左右列表/详情、分支右键及操作表单组织，并阅读官方 [Worktrees Overview](https://www.git-tower.com/help/guides/worktrees/overview/mac)、[Add Worktree](https://www.git-tower.com/help/guides/worktrees/add/mac)、[Submodules Overview](https://www.git-tower.com/help/guides/submodules/overview/mac)、[Configuration](https://www.git-tower.com/help/guides/submodules/configuration/mac)、[Delete](https://www.git-tower.com/help/guides/submodules/delete/mac)。原生命令语义核对 [Git Worktree](https://git-scm.com/docs/git-worktree) 和 [Git Submodule](https://git-scm.com/docs/git-submodule)。没有复制 Tower 的代码、资产或修改其配置。

- 侧栏 Related Repositories 下显示 Worktrees/Submodules 数量和条目。专属页面支持工具栏搜索、列表选择、双击打开、右键管理、状态/路径/哈希详情。
- Worktree 显示主工作树、当前工作树、分支或 detached HEAD、锁原因及失效状态。添加入口包括 Repository 菜单、侧栏加号和分支右键 Checkout Branch in New Worktree。
- 子模块显示路径、名称、版本化与本地 URL、跟踪分支、父仓库 gitlink、实际 HEAD、初始化/本地修改/冲突/配置诊断及 Git 存储位置。
- 创建和管理操作先 Review；涉及提交的目标固定为解析后的哈希。返回编辑会清除旧预览；仓库切换、HEAD/index/config/模块状态变化阻止旧计划应用。
- Quick Actions 提供创建入口，以及 Worktree 打开、子模块打开/初始化。写入仍走审阅表单；打开复用当前 Store/窗口，不主动创建或激活窗口。
- Clone 表单增加递归初始化和显式本地 file transport 选项。

本轮不做前台窗口检查。像素、焦点、键盘、面板布局、鼠标、VoiceOver、亮色和大仓库性能仍未验收；不得以编译或状态测试宣称已和 Tower 完全一致。

## Worktree 行为

`WorktreeManagement.swift` 解析 NUL 分隔的 `worktree list --porcelain -z`，保留分支、HEAD、bare、locked/prunable 信息。缺失路径按已存在的父目录规范化，避免 macOS `/var`/`/private/var` 别名在外部迁移后导致条目失配。

- Add 支持已有本地分支、新分支、指定版本 detached。预览不创建目录；目的地必须新建、父目录存在、位于全部现有工作树及 Git 存储之外。不使用 force；已占用分支、重名新分支、变化后的已有分支和被占用的目的地拒绝执行。
- Open 验证当前注册、目录类型、真实仓库根和公共 Git 目录。Lock/Unlock 使用原生命令，主工作树不能锁定。
- Move 仅允许非当前、非主、已解锁的关联树；拒绝 Git 操作进行中及任何已跟踪、未跟踪、忽略文件修改。
- Repair 验证选中目录的原始 `.git` 文件确实指向该条目的 administrative directory，再执行原生 repair，避免错误重接另一工作树。
- Remove 仅允许非当前、非主、未锁定关联树。先备份 administrative metadata、固定索引对象和 HEAD 提交引用，再无 force 移除。分支保留；失效注册也可定向移除，不调用全局 prune。新出现的脏目录由原生命令继续拦截。

没有强制清理、全局 prune、主仓库搬家后的批量 repair 或一键恢复管理备份。包含已初始化子模块的 Worktree 迁移/移除继续服从 Git 的拒绝，不绕过其限制。

## 子模块行为

`SubmoduleManagement.swift` 以 NUL 分隔解析 `.gitmodules` 和 stage-zero gitlink，校验重复键/名称/路径及链接。每次最多 256 个直接模块；嵌套模块可打开其父模块后管理。干净性递归检查限 16 层，递归 init/update/clone 由 Git 自身完成。

- Add 预览固定父仓库 HEAD/index/config，新路径和名称不得冲突；克隆后暂存 `.gitmodules` 与 gitlink，不自动提交。可指定跟踪分支。
- Initialize/Update 显式指定 `--checkout`，检出父仓库索引记录的精确版本，不执行模块自定义 update 命令。可递归；不会自动更新父仓库 gitlink 或创建父仓库提交。
- Fetch 只下载对象及更新引用；支持 on-demand 递归。Checkout 在子仓库解析不可变提交后 detached 检出，不递归改写嵌套工作文件，用户在父仓库显式暂存 gitlink。
- 修改 URL 使用 set-url 并暂存 `.gitmodules`；Sync 将版本化 URL 同步到本地配置，支持递归。Move 使用 Git mv 更新路径和 gitlink/.gitmodules，并暂存元数据。
- Repair 吸收 embedded `.git` 目录，或在 metadata 的 core.worktree 精确匹配当前路径时恢复丢失的 `.git` 文件。错误/未知指针不猜测修复。
- Deinitialize/Remove 递归检查本地、未跟踪、忽略文件与嵌套模块；当前子模块版本须已记录在父仓库。Remove 另拒绝尚未提交的父 gitlink 暂存变化，保留模块 Git 历史，不使用 force 或删除 `.git/modules`。
- Git 存储通过当前工作树的 `git rev-parse --git-path modules` 获取。关联 Worktree 使用其专属 modules 区域；不会假定所有模块都位于主仓库 `.git/modules`。
- 可能改变配置/路径/注册的操作保存私有 JSON 管理备份，包含原 `.gitmodules`、父索引和原本地配置，固定索引对象。变更子仓库 HEAD 前保留隐藏提交引用。管理备份与已有本地文件恢复 UI 是不同机制，尚无一键恢复管理备份入口。

## 传输与失败边界

每条网络 Git 命令单独设置允许的 HTTP/HTTPS/SSH/Git 协议，禁用自定义 transport helper。file transport 默认禁用，用户只能为当前操作/递归克隆显式启用。相对子模块 URL 由 Git 按父仓库 remote 解析；即使解析成本地源，没有启用 file transport 仍会被协议策略拒绝。没有修改用户全局 Git 配置。

递归 clone/update、sync 或多步骤 remove 可能部分完成后失败。保留已产生数据、输出实际 Git 错误，刷新后重试；不伪装原子事务，不静默 force、不自动回滚或删除部分克隆目录。实际远程认证/SSH、慢网和自定义 GUI 没有验收。

含嵌套声明的子模块路径 Move 明确拒绝，避免错误的嵌套 .git/core.worktree 指针。任意损坏指针重定位、自动更新跟踪分支到远程最新版本、批量操作、冲突 gitlink 选择器、强制删除、重用已保留 Git 目录及可视化恢复管理备份仍需后续补齐。保留的 Git metadata/config 可能包含用户 URL；备份按私有目录/文件权限写入，无自动清理。

## 测试覆盖

新增核心 13 项和应用 3 项：

- Worktree 三种创建模式、占用分支/内部路径/目的地/旧分支提示，保留主树修改；锁/解锁/移动/外部移动修复；脏/未跟踪/忽略/当前树/旧条目保护；错误 repair 目标、缺失条目移除。
- 子模块添加、状态、打开、取消初始化/恢复初始化；特殊名称路径/Unicode Move、丢失指针修复、URL/Sync/移除、保留历史；Fetch/固定 checkout/回到父仓库记录版本且父 HEAD 不变。
- 父索引或 .gitmodules 改变后的旧预览拒绝，unsafe transport/path 拒绝，file transport 显式启用，相对 URL 预览，忽略文件和本地内容保护。
- 嵌套本地源递归 clone、嵌套修改阻止 update/deinitialize；关联 Worktree 内子模块独立 Git 存储的 init/repair/deinit/remove，并确认主工作树的模块仍可用。
- Store 审阅先于写入、旧仓库 token 拒绝、列表/Quick Actions 同窗口打开、仓库库注册、导航返回，以及坏 .gitmodules 错误隔离与修复后清除诊断。

清单变为 **36 covered、28 partial、31 missing、3 unverified**。TP-072/074/075 为有边界覆盖；TP-073/076 保留 partial。不是产品完成百分比。
