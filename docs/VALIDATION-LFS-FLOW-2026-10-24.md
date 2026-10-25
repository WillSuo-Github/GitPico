# Git LFS 与经典 Git Flow — 2026-10-24

## 对照与环境

本轮延续已有本地 Tower 设置页、分支/文件右键菜单和审阅表单风格，交叉核对官方 [Git LFS](https://www.git-tower.com/help/guides/integration/git-lfs/mac)、[Git-Flow](https://www.git-tower.com/help/guides/integration/git-flow/mac)、[Workflows](https://www.git-tower.com/help/guides/workflows/overview/mac)，以及 Git LFS 的 [track](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-track.adoc)、[install](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-install.adoc)、[fetch](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-fetch.adoc)、[push](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-push.adoc)、[configuration/progress](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-config.adoc) 契约。

没有激活 Tower、GitPico、浏览器或其他测试窗口，没有新的原生截图、焦点、键鼠或像素一致性验收。所有 Git 写操作、克隆、对象传输均使用临时本地仓库和本地 bare 仓库；未写个人仓库、外部服务器、用户全局 Git 设置或真实签名密钥。没有源码 commit、push、发布或 CLI 安装。

本机实际 Git LFS 为 `git-lfs/3.8.1`，Git Flow CLI 未安装。GitPico 使用已安装的 Git LFS；Git Flow 使用原生 Git 命令实现经典分支模型，不依赖额外 git-flow 脚本，不复制 Tower 的程序或资源。现代 Tower 的自定义工作流/Graphite 与经典 Git Flow 分开记录，未在本轮混算覆盖。

## Git LFS

### 启用、规则与 hooks

- Repository Settings 新增 Git LFS 页，展示实际扩展版本、有效 filter 状态、pre-push hook 检测、跟踪规则的来源、当前索引的 LFS 文件/OID/大小/缓存与检出状态及原生 LFS status。
- 启用只修改仓库本地 filters；安装 pre-push hook 是显式选项。现有自定义脚本、外置 hooksPath 不被覆盖，可选择只启用 filters，再手工整合现有 hook。禁用 hooks 的 `/dev/null` 路径不会令状态页报错。
- 默认 hook 内容由本机 Git LFS 在临时 bare 仓库生成，审阅后再通过内容核对和文件锁安装；新 hook 具备执行权限。即使现有自定义脚本含有 `git lfs pre-push`，也不能因而覆盖它。
- 禁用本地 filters 保留历史、规则、缓存和 hooks，不冒充将历史 LFS 文件转回普通 Git 对象。
- 创建/删除模式、按文件名精确跟踪、按扩展名跟踪均先在临时仓库生成目标 `.gitattributes`，不在预览时改变实际文件、暂存或权限。嵌套规则使用其来源目录的相对模式，保留手工规则/注释；实际属性文件必须仍与审阅时一致。
- 规则变化不自动暂存或提交属性文件，不重写已提交历史。带命令选项前缀的模式、换行模式、越界路径与符号链接路径会被拒绝。

### 旧文件转换与索引恢复

仅增加规则不会自动将已有提交中的普通 Git blob 改成 LFS 指针，因此另提供 Stage Existing Files with LFS 与文件右键 Stage LFS Conversion：

- 自动选择匹配有效 LFS 属性的已跟踪文件，或选择明确文件；审阅文件清单与暂存后的统计，再应用。
- 在临时索引运行真实 `git add --renormalize`，并通过原生 `lfs ls-files` 验证生成了 LFS 指针。未启用有效 filters 时拒绝伪造“转换成功”。
- 预览生成本地 LFS 缓存对象，不改真实索引或工作文件。应用再次核对 HEAD、文件内容/权限、有效属性、filters 和真实索引；只安装审阅过的索引。
- 暂存所选文件的当前工作内容；工作字节与其他文件的暂存保持，原索引与新索引对象均保留恢复引用。Settings / Pattern Recovery 可恢复此前索引，HEAD 或新暂存变化会阻止覆盖。
- 文件内容使用流式 SHA-256 校验，最多 128 个文件、每个 2 GB；自动枚举最多 50,000 个已跟踪路径。split-index、sparse checkout、冲突索引、assume-unchanged/skip-worktree、链接和 gitlink 不在此转换入口支持范围。

### 对象传输与克隆

- 原生 Fetch、Pull、Push、Checkout Cached Objects；选择远程和解析后的不可变 revision。Fetch/Push 可显式包含该版本所有可达历史对象，便于备份或补传远端已有引用却丢失的对象；审阅说明当前版本文件列表不是全部历史对象计数。
- Fetch 不改变工作副本，Push 只传 LFS 对象，不推送 Git 分支；Pull 只面向当前 HEAD，先 fetch 再重新核对分支/索引/配置，最后 checkout 缓存。其他版本使用 Fetch。
- Checkout 使用原生 Git LFS 的修改保护，不覆盖已修改工作文件；索引与分支保持。当前索引/端点配置在审阅后改变则拒绝运行。
- 进度来自 `GIT_LFS_PROGRESS`，以原生文本显示，不虚构字节或完成百分比。成功/失败报告和诊断保存在仓库管理目录。单次原生命令超时 600 秒；本轮没有实现运行中立即取消的控件。
- 克隆表单新增 Enable Git LFS 和 Download LFS Objects Now，可本地启用 filters 并克隆实际对象，或先克隆指针、稍后 Fetch/Pull。保持现代标准 clone/filter 路径，不调用已弃用的 `git lfs clone`。
- GUI 进程的 Git 子进程补充 Homebrew 标准路径以定位 git-lfs；移除相对/空 PATH 项，不从工作目录寻找扩展。

不是 Tower 的内置 LFS 二进制分发：其他机器仍需安装兼容 Git LFS。结构化状态以本机 3.8.1 验证；更旧版本不支持 JSON 子命令时会显示原生命令错误。LFS 服务端认证、配额、锁/解锁、服务端并发、历史 migrate、prune、真实托管服务及大规模性能未验收，不冒充已实现。

## 经典 Git Flow

### 配置与入口

- Settings 新增 Git Flow 页；Repository 菜单、工具栏、Quick Actions、分支右键提供配置、Start Feature/Release/Hotfix/Support、Finish、Continue/Stop，主题分支可复用现有审阅式 Publish 与 History。
- 兼容 `gitflow.branch.master/develop` 与 feature/release/hotfix/support/versiontag 前缀设置。生产/开发分支不同，前缀须以 `/` 结束且互不重叠；不修改用户全局设置。
- 生产分支须为已有本地分支，开发分支缺失时从生产创建，存在则保留。不隐式切换初始分支；未出生仓库须先建立首个提交。
- 创建 feature/release 默认从 development，hotfix/support 默认从 production；可明确选择其他起点或已有 remote-tracking branch。跟踪远端分支时核对其不可变提交并设置 upstream，不在创建时拉取远端。
- 不显示尚未配置的“启动主题”Quick Action；旧仓库会话的审阅请求不能写入另一个仓库。

### 完成、暂停与恢复

- Feature 合入 development；Release/Hotfix 合入 production、创建带说明的 annotated version tag，再将生产结果合回 development。默认保留 no-fast-forward 合并结构；可选择保留主题分支。
- 所需步骤全部成功后才按旧 hash 删除主题引用；源/目标历史已由恢复引用保留。Support 为长期维护分支，仅支持启动，不提供伪造 Finish。
- 签名标签使用现有仓库签名设置。无实际密钥验收；测试使用显式失败的本地 signer 验证错误路径：生产合并与主题被保留，tag 不假成功，流程暂停。
- 每个步骤执行前保存进度及预期 refs、HEAD、index、config；已完成步骤重新打开后可见。Git 级冲突可在现有 Working Copy 解决、暂存，再 Continue；外部手动完成的 merge 必须包含两个审阅过的历史。
- 继续/终止前核对实际 `MERGE_HEAD`，外部 Git 替换当前 merge 时不能误提交或中止那场合并。其他分支、配置、暂存或 HEAD 改动也会阻止无意续写。
- Stop 只中止仍归属当前流程的未完成 merge，并停止后续步骤；此前完成的生产合并/标签、主题和备份引用保留。不会把“Stop”伪装成跨多个分支的整体回滚。
- 对可识别的 checkout/tag/delete 中断状态做保守续接；未知结果不盲目重放。活跃流程属于开始它的工作目录，另一个 linked Worktree 不能冒领；目标被其他 Worktree 检出时不能修改。
- 不自动推送、远端删分支或重置共享历史。Git Flow AVH 扩展参数、bugfix 类型、自定义 CLI hooks、release 分支额外策略、自定义/GitHub/GitLab Flow 和 Graphite 仍属于后续范围。

Flow 不是多引用原子事务：中间冲突/签名/锁错误可暂停，先前完成历史保留。所有暂停与继续使用仓库协作锁和状态核对；外部 Git CLI 仍能独立运行，因此不承诺排斥所有外部并发操作。

## 持久化与界面验收边界

LFS 设置/索引恢复、传输报告、Flow 配置副本、活跃步骤与历史使用仓库内单独目录。写入前拒绝符号链接祖先；记录目录 0700、文件 0600，JSON 记录最多 128 MB，索引/配置原始读取沿用 32 MB 上限。对象缓存与恢复记录不自动清理。LFS 配置/属性恢复比较记录前后内容，索引恢复仍要求同一 HEAD，新的编辑不会被覆盖。

本轮增加的 SwiftUI 原生菜单、紧凑行、表单、错误文本、状态与审阅流程已编译并覆盖路由。没有前台 UI/鼠标/键盘/VoiceOver、亮色布局、真实远程授权或 macOS 26 运行验收。最低部署目标仍为 26.0；较新主机执行不代表 26.0 运行接受。

## 验证与构建

新增核心 19 项、应用 3 项专项均通过，见 [专项日志](evidence/lfs-flow-focused-tests-final.log)。包括真实 1 MiB LFS blob 的标准 Git 指针、实际本地 bare 对象上传、删除远端对象后的显式补传、完整/指针克隆、Fetch/Pull/Checkout、dirty 文件保护、旧文件转换与索引恢复；以及配置、三类生命周期、支持分支、远端跟踪、版本标签、签名失败、原生 merge 继续/终止与替换 merge 保护。

初期测试发现并修正：禁用/自定义 hooksPath 的状态读取、嵌套规则的相对模式删除、远端已有引用时默认 LFS push 不补传对象（增加显式 All Reachable History 选项）、索引恢复路径别名，以及入口测试未等待设置页刷新完成的时序。历史失败日志保留，没有当成最终通过记录。

- 最终全量回归 **238 项通过**：196 项 GitCore（320.233 秒）、42 项应用测试（26.823 秒）。见 [完整测试日志](evidence/lfs-flow-full-tests.log)。新增 19 项核心和 3 项应用测试均包含在这份最终全量中；专项与全量间的额外变化为同一功能的私有持久化权限与大小/路径检查，全量已覆盖最终源码。
- 最终开发包 **0.01 / 20261024213716**，Build 使用上海时区 `yyyyMMddHHmmss`。见 [后台构建](evidence/lfs-flow-background-build.log)、[实际 bundle/依赖与二进制指纹](evidence/lfs-flow-bundle-metadata.json)。已打包与当前编译产物在临时副本去除签名后的 SHA-256 一致；实际包保留签名。
- [后台运行](evidence/lfs-flow-background-verification.json)：`isActive: false`、`visibleWindows: 0`、前台 `com.openai.codex`，没有拉起测试界面。
- [签名验证](evidence/lfs-flow-signature.log)为有效本地 ad-hoc 开发签名；没有发布、公证或分发签名验收。[部署目标](evidence/lfs-flow-deployment-target.log)为 macOS 26.0，实际主机 27.0.1；macOS 26 运行未验收。
- 清单保持 98 项，更新为 40 covered、26 partial、29 missing、3 unverified。TP-083、TP-084 仅代表本文范围内的功能覆盖，不是整体 Tower 完成率或视觉一致性验收。

