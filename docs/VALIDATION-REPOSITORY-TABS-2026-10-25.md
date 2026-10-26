# 仓库标签页与选择页 — 2026-10-25

本轮把已确认的交互提案实现为原生 SwiftUI 工作区。仓库选择是空标签页的内容，打开后同一个标签显示仓库。不是网页原型或嵌入浏览器。

## 行为

- Command-T / 顶部加号创建独立选择页；左上角文件夹为普通 Repositories 按钮，切到已有空闲选择页或新建一个，不再显示原来的多级下拉菜单。
- 选择页平铺 Open Local、Clone、New，展示全部、最近、收藏和已有分组，支持名称/路径/分组搜索、列表双击/Return 和行尾直接打开。Manage Library 保留已有组织管理，Repair Pointers 保留原欢迎页修复入口。
- 一个标签持有一个 RepositoryStore。切换不调用 open/reload，分别保留仓库、当前导航、搜索、选中文件/提交、提交草稿、侧边栏过滤和历史缓存。活动 SwiftUI 内容视图会重建，不保证所有局部展开状态和任意列表的精确像素滚动位置；历史列表会按已有选择 reveal 机制恢复选中提交。
- Open、Open Recent、Quick Open、仓库库、Worktree 和子模块打开均经过工作区路由；从仓库打开另一个仓库使用新标签，选择页打开则填入本页。Git 解析后的规范根路径用于去重；子目录/符号链接会聚焦已有仓库，真正不同的 Worktree 根目录分别处理。并发打开也不会产生重复仓库工作区。
- Command-W 关闭当前标签；既有仓库内快捷键不变，Control-Tab / Control-Shift-Tab 切换标签，Command-1/2 等继续导航仓库内页面。关闭最后一个标签回到选择页，不终止 app。
- 操作中/正在打开的标签禁止关闭，其他标签仍可选择或创建；关闭空闲标签只取消只读预览/后台管理读取，不丢弃 Git 修改。菜单 Close Tab 保持接收 Command-W，由模型拒绝 busy close，避免落到系统 Close Window 快捷键。
- 持久化的是每个根路径的提交主题与正文，300 ms 合并写入，关标签和正常退出时同步落盘；成功提交会清掉已保存草稿。存储损坏/不可写时保留有草稿的仓库标签并报告错误，修复存储后可 Retry，未静默覆盖损坏数据。草稿不自动恢复 Amend 开关。
- 本轮没有实现跨重启恢复全部标签；常规启动进入仓库选择页，`--repository` 启动参数仍可直接打开指定仓库。新建/克隆继续使用原生审核表单和现有 GitCore 实现。
- 主仓库迁移更新原标签；修复同一仓库会重新载入该标签，打开仍存在的另一仓库或恢复新副本则保留旧标签。没有扩展为任意外部 Git 写入的跨进程事务。

## 源码范围

新增 RepositoryWorkspace / RepositoryTab 管理标签身份、路由、去重及关闭；RepositoryDraftStore 保存提交草稿；RepositoryWorkspaceView / RepositoryPickerView 提供标签栏和选择界面。原 RepositoryStore 在没有工作区时保留独立使用行为，兼容既有测试与内部入口。共享仓库库和工具设置，不在标签切换时重读完整仓库。

## 验证

[首轮定向测试](evidence/repository-tabs-focused-tests.log) 8 项通过。最终增加迁移路由后，共 9 项覆盖：独立草稿/历史缓存与选择、选择页复用及重复仓库、并发/子目录/符号链接去重、关闭最后一页与跨实例读取草稿、busy 关闭保护和独立操作、无效路径保护原仓库、损坏草稿存储保护及修复后重试、成功提交清除持久化草稿、迁移后更新原标签及另一仓库另开页。

- 最终原生 App target：**95 项通过、0 失败、5 项条件跳过**，包含上述 9 项新回归和全部原有 App 回归。[结果摘要](evidence/repository-tabs-acceptance-summary.json)、[测试日志](evidence/repository-tabs-acceptance-tests.log)、[最终测试构建](evidence/repository-tabs-final-native-build.log)。本机结果包 `.build/xcode/RepositoryTabsAcceptance.xcresult`。
- 中间回归曾发现迁移用例对目录 URL 尾斜杠的比较差异，产品路由和用例改为比较规范根路径；[修复后的迁移/并发定向测试](evidence/repository-tabs-migration-fix-tests.log)通过。另有旧 Worktree 打开用例固定等待 10 秒，在高并行负载下提前检查；现在记录并等待实际打开任务，保留原断言并增加 busy 结束断言。两项在上述最终原生运行均通过。
- 5 个 skip 为显式 opt-in 的旧基准和离屏组件捕获，本轮未启用。原生结果仍记录既有 `com.willsuo.GitPico.drag` 未导出警告，本轮未改动拖放类型声明。
- `./script/build_and_run.sh --verify` 后台构建/暂存/验证通过：[日志](evidence/repository-tabs-background-build.log)、[后台报告](evidence/repository-tabs-background-verification.json)：未激活、可见窗口 0。15 个相关源码/测试文件的 [指纹](evidence/repository-tabs-source-hashes.json)与最终源码一致。
- 开发包 **0.01 / 20261025140116**，最低系统 26.0；按用户请求使用 `/usr/bin/open -n` 正常启动 `dist/GitPico.app`，新 PID **6756**。没有强制停止其他实例。[启动记录](evidence/repository-tabs-launch.json)与 [运行日志](evidence/repository-tabs-launch-runtime.log)记录该版本和窗口启动。
- 原生自动界面读取两次超时，因此没有声称截图、真实 Command-T/Command-W、鼠标双击或完整视觉验收通过。[进程采样](evidence/repository-tabs-launch-sample.txt)确认版本、正常 App 入口及空闲 AppKit 主事件循环，不是崩溃或阻塞栈。新进程仍在运行，供用户本轮手动试用。
- 本轮未改 GitCore 源码，未重跑 Core 全套；上述 95 项特指 App target。

## 边界

本轮测试使用隔离临时 Git 仓库。构建和回归默认后台；用户在本轮明确要求“改完运行起来让我试试”，因此完成后正常启动新版本的前台运行属于本次授权。不会把正常启动等同于所有鼠标、快捷键、焦点或性能细节均通过人工验收。

最低系统 macOS 26.0，开发营销版本固定 0.01。实际测试主机 macOS 27.0.1 / Xcode 27.1，不能代替 macOS 26 runtime 验收。未推送、发布或创建 GitHub 仓库。
