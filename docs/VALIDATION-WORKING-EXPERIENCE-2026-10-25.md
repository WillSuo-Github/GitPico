# 工作区文件、差异与暂存提交打磨 — 2026-10-25

沿用已保存的本地 Tower `tower-working-reference.png` 作为对照：左侧分支/提交输入/紧凑文件行，右侧 Staged/Unstaged、分块及逐行操作。没有激活 Tower、GitPico、Xcode 或浏览器，也没有恢复前台鼠标测试。

## 文件列表和选择

- 原筛选、自然排序和浏览条目合并在 View body 中随选择重算；现在通过 `WorkingFilesInput` / `WorkingFilesPresentation` 在 detached task 中准备，按仓库会话和最新代次发布。显示条目、排序/筛选和选择集合由同一模型协调。
- 多选新增项成为当前差异文件；减少选择时保留仍在集合中的当前文件，否则选择可见顺序中的剩余项。清空选择或过滤掉全部选中项会取消差异读取并清空右侧。没有声称恢复精确像素滚动或所有原生 Shift/Command 手势语义。
- 列表选中操作栏提供 Stage / Unstage；文件右键入口作用于包含该行的整个多选集合，右键行不在集合中时仅作用于该行。未修改/忽略条目不隐式加入暂存，冲突条目由现有冲突解决流程处理。
- 部分暂存显示 mixed 标记，点击表示 Stage Remaining Changes；完整暂存点击取消暂存。右键和选择栏始终保留显式 Unstage。文件行有完整路径/双重状态提示、可访问的暂存状态及选中文字颜色；列头显示当前排序，底部显示可见数量和仓库暂存数量。
- Stage All 保留全仓变更范围，包含被搜索隐藏的普通变更，tooltip 明确说明；它不是“Stage Visible”。忽略文件仍需已有的显式 Force Add 审核。

## 差异查看和逐行操作

- 相同文件、side、context、whitespace 的当前请求会复用；切换或刷新取消旧读取并校验请求 token，迟到结果不能覆盖当前文件。改变 context/side 会重新读取；显式 Refresh 和写后 reload 使当前请求失效。没有加入跨文件或长期工作区内容缓存，外部文件修改仍需 Refresh。
- changed-file 的读取错误在右侧显示并提供 Retry；不清空当前文件选择。历史提交文件读取错误继续使用原有全局错误处理。
- `PreparedPatch` 在后台一次准备 hunks、最多 8,000 行预览、可选择行顺序和两栏对齐。选行不会重新解析整份 patch；Shift 范围只覆盖可见、可完整操作的变更行，不含上下文或截断部分。布局偏好变化保留同一源的行集合；换源清空行选择。
- 去掉把整份 diff 字符串拼入 View identity 的做法，保持仓库/文件/side 身份。ignore-whitespace、未完成读取、读取失败及空行集合不能发起部分暂存；core 继续核对完整当前 diff，防止把过时补丁写入索引。重命名/模式变化/截断等原有限制保持。
- 差异底栏明确 HEAD → Index 或 Index → Working Copy。统一/并排仍使用既有共享行模型；本轮没有新增语法高亮、图片 diff 或 in-file Find。

## 提交

- 提交按钮旁显示不可用原因（未暂存、缺少标题、冲突或进行中的操作），可提交时显示将提交的暂存文件数量。Amend 的按钮名称明确，已有 Sign Off/说明输入保留。
- Cmd-Return 只由 Working Copy 菜单命令注册，离开工作区不执行提交；移除 composer 中重复的快捷键定义。
- Git commit 成功后清空本次说明并显示成功反馈；开始下一次说明或写操作时清除旧反馈。Git 拒绝提交时保留完整说明；测试使用仅退出 1、不自行修改仓库的隔离 pre-commit hook，验证暂存区和 HEAD 也保持。任意钩子自身的写入不属于回滚事务。
- 核对发现原 `GitRepository.commit` 在 Git 已创建提交后仍会因为 Undo 日志错误而抛出同一种失败。新增 `CommitOutcome` 区分 Git 失败与本地 Undo 记录失败：Git 接受后清空草稿、保留成功反馈，并单独显示 Undo/刷新提示和 Reflog 入口。刷新失败不把已创建的提交重新当成待重试提交，旧 Undo 入口也会禁用。
- [故障检查](evidence/working-experience-commit-outcome-tests.log)：故意把临时仓库的 `undo.json` 变成目录，core 返回成功并附带 Undo 提示；App 不显示提交失败、草稿清空、暂存区清空且提交已存在。正常部分提交和真正拒绝提交同时重跑通过。
- 成功提交后，仍有未暂存内容的当前文件和所选集合保留，差异自动回到有效 side；完全干净且不可见的文件移出选择。未自动选择原来未选中的其他文件。

## 已有定向证据

- [6 项首轮用例](evidence/working-experience-focused-tests.log)：多选暂存/取消、混合复选框、部分提交余留内容、拒绝提交保留草稿/索引/HEAD、文件过滤/忽略保护、差异去重/迟到结果和可见行范围。
- [逐行暂存与取消的端到端检查](evidence/working-experience-line-flow.log)：由真实差异生成行 ID，从未暂存侧暂存删除/首条新增，再从已暂存侧取消；索引回到原文，工作区两条新文本保持。
- [失败读取 Retry 和离屏捕获](evidence/working-experience-render-tests.log)：临时失败不丢选择，重试成功；窗口保持不可见且应用未激活。
- [浅色组件](evidence/working-components-light.png)、[深色组件](evidence/working-components-dark.png)：实际 WorkingFileRow、StatusBadge、DiffLineView 和逐行选择按钮；640 点宽、2 倍缩放。展示普通、部分暂存、完整暂存、新文件、冲突行和统一 diff 行。不是完整 List、composer 或完整应用截图。

```sh
GITPICO_RENDER_WORKING_COMPONENTS=1 \
GITPICO_WORKING_COMPONENT_OUTPUT=/tmp/gitpico-working-components \
swift test --filter renderWorkingFileAndDiffRowsWithoutWindows
```

## 最终原生回归和开发包

- 首轮完整回归 270 项通过、0 失败、3 项显式检查按条件跳过，见 [首轮摘要](evidence/working-experience-native-summary.json)。之后补充提交成功/Undo 故障结果分离，最终重新原生 `build-for-testing` 和完整 `test-without-building`。
- **最终 272 项通过、0 失败、3 项按条件跳过**：204 项 GitCore、68 项 App。原生宿主测试确认 prohibited activation、未激活、零可见窗口、0.01/日期 Build/26.0 bundle 值。见 [最终测试构建](evidence/working-experience-outcome-test-build.log)、[完整日志](evidence/working-experience-final-native-tests.log)、[xcresult 摘要](evidence/working-experience-final-native-summary.json)、[按 target 的结果](evidence/working-experience-final-test-tree.json)。本机结果包 `.build/xcode/WorkingCopyFinalTests.xcresult`。首轮与最终轮用例大量重复，不将两轮总数相加。
- 常规跳过的是分支预览性能基准、历史行离屏捕获、工作区行离屏捕获。三项针对最终源码 [单独启用并全部通过](evidence/working-experience-outcome-artifacts.log)，不是缺少运行证据的 skip。最终工作区浅/深色图片已重新检查并保存到上述组件链接；[分支预览基准](evidence/working-experience-final-preview-benchmark.json)仍保持 HEAD 不变，指标是模型可用时间，不是帧率。
- 最终开发包 `dist/GitPico.app`：**0.01 / 20261025002448**，最低系统 26.0。Native 产品与暂存包全部文件和符号链接一致，最终 16 个本轮源码/测试文件指纹与已测试文件一致。见 [bundle 元数据](evidence/working-experience-bundle-metadata.json)、[源码指纹](evidence/working-experience-source-hashes.json)、[空白检查](evidence/working-experience-static-checks.log)。
- [最终构建/后台验证](evidence/working-experience-final-background-build.log)、[运行报告](evidence/working-experience-background-verification.json)：isActive false、visibleWindows 0，前台为 Codex。新验证进程写入报告后自身退出，没有终止或重启用户已运行的实例。
- [签名验证](evidence/working-experience-signature.log)和 [Mach-O 部署目标](evidence/working-experience-deployment-target.log)通过，minos 26.0 / SDK 27.0。没有 Archive、分发、公证或前台运行验收。
- 本轮 Git 写入仅在可销毁的临时仓库中执行；没有提交、推送或发布项目源码。


## 验收边界

没有前台鼠标、键盘、IME 或系统剪贴板/拖放验收。离屏行组件不能代替真实 List 的多选/焦点、composer 动态高度、逐行快捷键及两栏滚动/水平布局验收。后台准备和有界预览不等于大型真实仓库/巨型差异的帧率证明。暂存、取消暂存和提交后仍等待完整仓库 metadata 刷新；本轮未拆分写后的增量刷新，这部分等待时间仍需继续优化。

版本保持 0.01，最低系统保持 macOS 26.0；实际测试主机 macOS 27.0.1 / Xcode 27.1。macOS 26 运行和完整 Tower 体验一致性仍未验收。
