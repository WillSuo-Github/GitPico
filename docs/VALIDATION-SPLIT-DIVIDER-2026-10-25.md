# 内容分割线拖拽坐标修正 — 2026-10-25

用户提供工作区提交面板和差异面板之间的竖向分割线截图，并报告左右拖拽剧烈抖动。[原始截图](evidence/split-divider-user-reference.png)已查看；静态截图本身不能提供运动轨迹或帧率证据。

## 改动

唯一产品源码改动为 `Sources/GitPico/Views/PersistentSplitView.swift`：

- 原手势挂在跟随左栏宽度移动的 divider overlay 上，使用默认局部坐标；`dragStart + translation.width` 的基准可能随自身布局更新而移动。
- 在固定的整个 split 容器上定义唯一命名坐标空间，`DragGesture` 显式使用该空间。拖拽起点不再依附会横向移动的分割线，宽度计算仍使用开始时的实际宽度和累计位移。
- `GestureState` 在拖拽结束或取消后清理起点，避免下一次拖拽继承旧起点。既有列宽上下限、9 点命中范围、辅助功能调整和结束时才保存宽度的逻辑保留。
- 工作区、历史、Stash、Reflog、文件历史、比较和分支审阅均复用此组件，统一采用此修正。没有改动 Git 读取、暂存、提交或刷新逻辑。

这是基于实际截图定位和代码检查的修复，没有把该坐标问题宣称为已经通过屏幕轨迹证明的唯一抖动来源。

## 后台验证方法与边界

尝试过仅供诊断的隐藏 `NSWindow` + 实际 `NSHostingView`，从不显示、不允许成为 key/main，通过 `window.sendEvent` 发送本进程合成鼠标事件；初始布局为 310 点，但连续事件没有触发 SwiftUI 的拖拽状态，宽度一直保持 310。该探针不能验证修复前后的拖拽行为，失败输出保留在 [诊断日志](evidence/split-divider-gesture-probe.log)，临时测试代码已移除，不纳入产品回归结果。

没有激活窗口、移动系统鼠标或向其他应用投递事件。真实前台左右拖动、临界宽度反向拖动、Escape/切页取消、拖拽时焦点和实际帧率仍未验收；不会以构建成功或原生单元测试替代这些结论。

## 最终结果

- 原生 `build-for-testing` 成功，App target **86 项通过、0 失败、5 项条件跳过**。这些是既有功能/宿主回归，不包含有效的鼠标拖拽测试。见 [构建](evidence/split-divider-test-build.log)、[原生日志](evidence/split-divider-app-tests.log)、[结果摘要](evidence/split-divider-app-summary.json)。5 项 opt-in 基准/离屏组件捕获本轮未开启。
- 原生结果仍记录既有 `com.willsuo.GitPico.drag` 未导出的宿主警告，与本次 resize 手势不同；本轮没有修改拖放类型声明。
- `./script/build_and_run.sh --verify` 完成构建和后台运行。[构建/验证日志](evidence/split-divider-background-build.log)、[运行报告](evidence/split-divider-background-verification.json)：未激活、可见窗口 0，验证进程已退出，保留用户已有实例。
- `dist/GitPico.app`：**0.01 / 20261025123722**，最低系统 26.0；[bundle 元数据](evidence/split-divider-bundle-metadata.json)、[签名](evidence/split-divider-signature.log)、[已测试源码指纹](evidence/split-divider-source-hashes.json)。没有改源 plist 或工程版本设置。
- 实际测试主机为 macOS 27.0.1，不能代替 macOS 26 runtime 验收。没有源代码提交、推送、发布或公证。
