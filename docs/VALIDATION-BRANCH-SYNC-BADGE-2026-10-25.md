# Current branch sync badge · 2026-10-25

## 行为

当前分支显示 HEAD，已配置上游时显示非零的 ↑ahead / ↓behind，例如 HEAD | ↑3 ↓5。数字比较本地 HEAD 和已有上游历史，使用 RepositorySnapshot 现有统计，不新增 Git 查询。没有上游时仅显示 HEAD，悬停解释需要配置 tracking branch；两边均为零也仅保留 HEAD。悬停说明具体上游及统计基于本地已有 refs，Fetch 用于更新远端状态。

Fetch 获取对象并更新 remote-tracking refs，是获取操作，不另造一个待 Fetch 的提交数量。未获取的服务器变化不能从当前本地快照准确计数。依据： https://git-scm.com/docs/git-fetch 和 https://git-scm.com/docs/git-rev-list 的 --left-right / --count。

徽标只绑定真实当前分支：同时核对 Reference.isCurrent、snapshot.head.branch 和 snapshot.references 当前引用；旧侧边栏轮廓、其他分支预览及 detached HEAD 不显示错误的 HEAD/计数。原来的侧边栏筛选状态改动保留。

## 验证

- 2 项后台测试通过，0 failed。隔离本地 bare origin 和 peer 验证：未配置上游、领先 2、远端有 3 个新提交但尚未 Fetch 时旧统计保持、通过 Store Fetch 后显示 ↑2 ↓3、预览其他分支时 HEAD 归属不变、合并后领先 3、Store Push 后归零、再次 Fetch 显示 ↓1、Store Pull 后归零，以及 detached HEAD 拒绝旧 HEAD 徽标。
- opt-in 原生 SwiftUI 组件捕获覆盖浅/深色、同步、仅领先、仅落后、双向分叉、四位数及没有上游；数字固定宽度显示，避免被名称挤掉。PNG 位于 evidence/branch-sync-badge/，280 点宽、2×。这不是前台鼠标或 VoiceOver 验收。
- 最终 --verify 基础启动与真实 App / 菜单启动通过，isActive=false、visibleWindows=0；单/多标签和菜单上下文验证保持通过。没有触碰个人仓库或外部服务器，未重复全量 App / Core 回归。
- 版本 0.01，Build 20261025210328，最低部署 26.0；完整 staged app 为 dist/GitPico.app，codesign deep / strict 通过。
- 主机为 macOS 27.0.1，未宣称 macOS 26 运行验收。未提交或推送。
