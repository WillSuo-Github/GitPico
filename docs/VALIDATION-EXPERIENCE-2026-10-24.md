# 导航、菜单和历史列表打磨 — 2026-10-24

本轮继续使用已保存的本地 Tower 对照图 `tower-history-reference.png`、`parity-tower-overview.png`。没有激活 Tower、GitPico、Xcode 或浏览器，也没有把“继续对照”解释为恢复前台测试授权。

## 改动

- 工具栏的分支按钮改为分支菜单：显示当前分支、预览本地分支、创建分支、切换当前预览分支。预览菜单最多列出 200 个本地分支，并保留完整 Branches Review 入口。
- 历史标题栏明确显示 Preview 和 Check Out，窗口副标题只描述正在看的历史，底部 HEAD 描述实际检出的分支。单击侧栏分支始终只预览；实际切换保留自动 Stash 提示。切换时重新验证捕获引用 tip、当前 Git 操作和其他 Worktree 占用；不使用 force。远程跟踪分支的创建继续沿用已有管理表单。
- 菜单栏拆出 Repository、Branch、Commit；同步、远程、Worktree/Submodule、管理恢复、扩展、选中提交操作和导出分别分组。相同入口共享仓库/忙碌/HEAD/操作状态判定，Git 读取不因存在 Merge/Rebase 状态而一概禁用。原有功能保留于相应菜单。
- 新增会话内导航书签，保存每个目标的搜索、历史选项/分页大小和选中提交；返回、前进及再次点击侧栏时恢复并滚动揭示选中行。32 个书签、100 个返回记录，打开仓库重置。不是精确像素滚动位置或跨启动恢复；工作文件的选中集合也不在本轮恢复范围。
- 缓存页后台核对 tip 时保留用户刚选中的行；捕获尚未开始防抖搜索的最新文本。分支历史重写后原提交消失时回到新 tip，并滚动揭示，避免指向不存在的行。
- 历史行移除内嵌 Button，交给原生 List 处理选择/键盘语义；紧凑/普通行高保留，隐藏行分隔线，修正关闭图时的左边距。引用显示主标签和溢出数量，完整名称留在 tooltip；上下文菜单按历史操作、导出和复制分组。
- 选中文字区分 key/inactive 窗口，使用 AppKit emphasized/unemphasized 内容颜色。离屏浅色检查曾发现控件选中文字颜色不适合强调背景，已替换成对应的内容颜色。
- Cmd-F 请求原生 NSSearchField 的编辑焦点；导航会取消未消费的搜索焦点请求。输入仍由 SwiftUI Binding 持有，桥接更新 enabled 状态。Back/Forward 提供 Cmd-[ / Cmd-]。

## 后台验证

- [定向交互和 checkout 测试](evidence/experience-focused-tests.log)：查询/选项/提交恢复，缓存核对中的新选择保护，预览与实际 checkout 分离，busy 入口，导航书签边界，外部移动引用、进行中的 Git 操作、其他 Worktree 占用及保留本地编辑。
- [搜索桥接和行组件检查](evidence/experience-component-tests.log)：绑定更新、过期焦点取消、无可见窗口/无激活。
- [最新离屏和导航边缘检查](evidence/experience-render-and-edges.log)：渲染无窗口通过；防抖前离开再返回、历史重写后 fallback/reveal 通过。
- 离屏图片为 380 点宽、2 倍缩放，从上到下为普通行、强调选中行、失焦选中行、紧凑行、无图行：[浅色](evidence/history-rows-light.png)、[深色](evidence/history-rows-dark.png)。使用实际 CommitRow / CommitReferenceBadge / GraphCell，未创建可见窗口。图片不是完整应用或工具栏截图。

```sh
GITPICO_RENDER_COMPONENTS=1 \
GITPICO_COMPONENT_OUTPUT=/tmp/gitpico-components \
swift test --filter renderHistoryRowsWithoutWindows
```

### 原生回归和重跑

- 首次完整 scheme 运行共 264 项：261 通过、1 失败、2 项按条件跳过。GitCore 的 **203 项全部通过**；App 失败为已有 `nativeHeadDropPinsDestinationAndRejectsExternalBranchSwitch` 中等待辅助函数的 `!store.isBusy`。其 10 秒轮询期限在并发负载下先到期，结果内 HEAD 已变化/操作拒绝/目标分支未被覆盖等断言均无失败。见 [完整原生日志](evidence/experience-native-tests.log)、[原生摘要及失败断言](evidence/experience-native-summary.json)、[按 target 的原生树](evidence/experience-native-test-tree.json)。原始失败证据保留，不把它写成完整通过。
- 相同用例 [SwiftPM 单独重跑](evidence/experience-head-drop-recheck.log) 8.2 秒通过。随后保留操作/拖放计划准备的实际 Task 句柄，测试辅助函数等待任务完成，再保留全部 Git/HEAD 安全断言；没有删断言或只延长超时。
- 最终源码重新 [原生构建](evidence/experience-final-native-build.log)，重跑**完整 App target：59 项通过、0 失败、2 项按条件跳过**。原失败用例通过，原生测试宿主仍为 prohibited、未激活且零可见窗口。见 [最终 App 日志](evidence/experience-final-app-tests.log)、[最终摘要](evidence/experience-final-app-summary.json)。Core 最终源码在完整回归后未改变；本轮按目标合计 203 项 Core + 59 项 App，两个运行存在 App 重叠，不能累加两个摘要当作独立用例数。本机结果包为 `.build/xcode/ExperiencePolishTests.xcresult` 和 `.build/xcode/ExperienceFinalAppTests.xcresult`。
- 常规跳过的是显式性能基准和离屏组件捕获；二者已经针对最终源码 [单独启用并通过](evidence/experience-final-artifact-tests.log)，不是功能缺失的跳过。
- 最终 [预览基准](evidence/experience-preview-benchmark.json)：同样的 600 提交 / 120 分支 / 2,000 未跟踪文件，首次三个预览约 0.220–0.268 秒，再访缓存页的模型发布低于 1 ms；HEAD 未改变。该指标到首条选中且不 busy，仍不是实际帧率、详情就绪或鼠标到屏幕延迟。新版没有回到导航全仓扫描路径。

### 最终开发包

- `dist/GitPico.app`：**0.01 / 20261024233619**，最低系统 26.0。Native product 与暂存包全部文件及符号链接一致，见 [bundle 元数据](evidence/experience-bundle-metadata.json)。
- [后台构建和验证](evidence/experience-background-build.log)、[独立运行报告](evidence/experience-background-verification.json)：isActive false、visibleWindows 0，前台为 Codex；验证进程写入报告后自行退出，未终止用户已运行的 GitPico。
- [签名](evidence/experience-signature.log)及 [Mach-O 最低版本](evidence/experience-deployment-target.log)通过；SDK 27.0 / minos 26.0。[19 个本轮源码/测试文件的空白检查](evidence/experience-static-checks.log)通过，并保存 [最终源码指纹](evidence/experience-source-hashes.json)。
- 隔离测试仓库之外没有执行验收 Git 写入，没有提交、推送或发布源码。

## 验收边界

离屏组件、代码路径和窗口抑制检查不能代替实际窗口的菜单溢出、系统菜单焦点、Cmd-F/IME、方向键/滚动及 VoiceOver 验收。原生 List 语义和滚动揭示已接入，真实鼠标/键盘验收按用户要求保持未执行。缓存仍为当前仓库会话内缓存；外部 HEAD/仓库元数据全面更新仍需 Refresh。

版本保持 0.01、最低系统 26.0；本机 macOS 27.0.1 / Xcode 27.1 的运行结果不代替 macOS 26 运行验收。完整 Tower 一致性仍未达成。
