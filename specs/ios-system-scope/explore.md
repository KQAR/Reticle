# Explore: iOS 真机 system scope

**Workspace**: `ios-system-scope` | **Date**: 2026-08-11

> 探索方式说明：本次探索由主 agent 自己完成，未启动只读探索 subagent（用户环境明确约束不使用 subagent）。

---

## 一、设备侧机制（本次会话实测，iPhone 13 Pro Max / iOS 26.0 / Xcode 26.3）

- **[事实] out-of-process runner 能驱动进程内够不到的 UI。** 三探针全绿：点系统权限弹窗「允许」（以目标 app 自身 label 变为 `Prompt granted` 作为副作用证据）、`XCUIDevice.press(.home)` 把 app 踢到后台且 SpringBoard 树可读、SpringBoard 上的跨进程坐标 tap。参考实现在工作区未提交的 `sample-app-ios/Tests/SampleAppUITests/OutOfProcessSpikeTests.swift`。
- **[事实] runner 拿到 backboardd 的 HID 连接。** 设备 syslog：`backboardd(BackBoardHIDEventFoundation): HID connection vpid:19257 bundleID:dev.reticle.sampleios.uitests.xctrunner successful`。这是本能力输入权限的来源，也是与 `docs/ios.md` 记录的「进程内 IOHIDEvent 被接受但路由到无处」形成对比的关键事实。
- **[事实] runner 可用 `xcrun devicectl device process launch` 独立启动，无需 xcodebuild。** 设备 syslog 依次出现 `Found most recent test bundle at NSBundle ...` → `Synthesizing a test configuration for the test bundle` → `Running with configuration <XCTestConfiguration>` → `Running tests...`。这使「一次准备、多次会话复用」成立（对应 NFR-001）。
- **[事实] 在 iOS 26 上不要删 runner 内嵌的 `Frameworks/XC*`。** Appium 文档要求删除以支持 devicectl 启动，但实测删除后 test bundle 加载失败：`Library not loaded: @rpath/XCTestCore.framework/XCTestCore`；不删则独立启动正常。
- **[事实] 常驻靠 never-ending test body。** WebDriverAgent 的 `testRunner` 方法内启动 HTTP server 且不返回，注释为 "Never ending test used to start WebDriverAgent"。
- **[事实] 设备端必须开启 Settings → 开发者 → Enable UI Automation。** 未开启时的报错会伪装：先表现为 runner `exit code 74 before establishing connection` + 设备 syslog `Connection peer refused channel request for "dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface"` → `Exiting due to IDE disconnection.`；清干净重装后才报出真实原因 `Timed out while enabling automation mode.`。这直接支撑 NFR-006。
- **[事实] 锁屏/熄屏不是上述失败的原因。** 已用 `devicectl device info lockState` 与 `devicectl device info displays` 交叉验证：backlight on 时同样失败。
- **[事实] 观测面落差（逐项对 `ReticleProtocol.Node` 实测）**：runner 只有 `axElement` 一层；`typeName` 只有 `XCUIElement.ElementType` 数字枚举，无真实类名；零样式通道；无 `regions` / `suspectedMultiRegion` / `suspectedWheel` / `checked` 三态 / `expanded` / `isFocusable`；无 `isVisible`（只有语义不同的 `isHittable`）；`testId` 有来源（`accessibilityIdentifier` 可见）。支撑 NFR-002/003。
- **[事实] 显示级截图可用**：`XCUIScreen.main.screenshot()` 得到 182KB / 428×926 pt，含系统弹窗。
- **[事实] 遍历开销是分钟级**：含网页内容的一次遍历耗时 126s（每次属性访问都是一次跨进程 AX 查询）。支撑 NFR-004。
- **[事实] `hasFocus` 在整棵 web 内容树上恒为 `true`**，不可作为 `Node.isFocused` 的来源。
- **[事实] WebView 内容可见但 DOM 不可见**：159 节点 / `webViews=3`，可读输入框、按钮、link、`enabled=false`（含 aria-disabled）、value；但 HTML `id`/`class`/CSS selector 全空、无 computed style。支撑 Out of Scope 中「不通过 system 通道读网页结构」。
- **[事实] 本机签名可用组合**：Xcode 未登录任何账号（`defaults read com.apple.dt.Xcode IDEProvisioningTeams` 不存在），但 team `UFSFCXQ5HZ` 的通配 profile `iOS Team Provisioning Profile: *` 已缓存在本地且其 ProvisionedDevices 含本设备，对应 keychain 证书 `10D5101C4619CFAF9AAB963461EFAAFB43687BAD`（`Apple Development: 瑞 金 (D66CSW78K2)`）。必须用 `CODE_SIGN_STYLE=Automatic`；`Manual` 会被拒（"is Xcode managed, but signing settings require a manually managed profile"）。
- **[事实] `xcodebuild -destination` 要 UDID（`00008110-...`），`devicectl --device` 要 coredevice UUID（`807E091D-...`）**，两者不可互换。与 `scripts/e2e-ios-device.sh:26` 的既有注释一致。
- **[事实] xcodebuild 不会自动装 target app**，需先 `devicectl device install app`。
- **[待确认] runner 常驻时能否稳定被系统保留**，以及被回收的典型触发条件。已知它会因内存压力/长时间后台被回收，这是 NFR-011 存在的原因，但回收的具体阈值未测。

---

## 一之补：2026-08-11 实现阶段的证伪（推翻上面一条结论）

- **[事实] 上面「runner 可用 `devicectl process launch` 独立启动」这条结论下得太早，已被证伪。** 那三行 syslog（`Found most recent test bundle` / `Synthesizing a test configuration` / `Running tests...`）只证明 XCTest **开始**跑，不证明 test 方法真的执行、更不证明能常驻。用真正的 never-ending test（`reticle-runner-ios`，见 T001/T002）实测：进程启动、拿到 HID 连接、打印 `Running tests...`，然后在约 18 秒后退出。
- **[事实] 三种启动方式全部失败在同一处**，且失败形态与「设备端 UI Automation 开关未开」完全相同（开关此时是**开着**的，同一台设备上 spike 的三个探针刚刚全绿）：
  1. `xcrun devicectl device process launch`
  2. `xcodebuild test-without-building -xctestrun <…>.xctestrun`
  3. `xcodebuild test -scheme ReticleRunner`

  统一报错：`Connection peer refused channel request for "dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface"` → `Exiting due to IDE disconnection.`
- **[推断] 根因是 UI test bundle 没有 test host。** 唯一的结构差异：能跑通的 spike target 设了 `TEST_TARGET_NAME: SampleApp`，而 `reticle-runner-ios/project.yml` 刻意不设（为了让 runner 独立于任何 app）。iOS/Xcode 26 上，无 target application 的 UI test bundle 似乎建不起 automation session。WebDriverAgentRunner 同样没有 host app 却能工作，所以这更可能是工程配置的某个键（而非结构上不可能）——需要比对 WDA 的 target 配置或它生成的 xctestrun 键。
- **[事实] runner 侧代码本身是好的**：真机 `build-for-testing` 成功（修掉一个 `NSObject.version()` 选择器冲突后），装机成功，进程能起并拿到 backboardd HID 连接。卡的是 automation session，不是编译或签名。
- **[事实] 加 test host 不解决**（2026-08-11 实测）。给 runner 配了一个占位 host app（`ReticleRunnerHost`，`TEST_TARGET_NAME` 指向它），`xcodebuild test` 仍然是同一句 `channel refused` → `Exiting due to IDE disconnection`。上面那条「根因是没有 test host」的推断因此被证伪；host target 保留在工程里（无害，且排除了这个变量）。
- **[事实] 日志里从来没有出现 `Test Case '-[…]' started`。** 能跑通的 spike 日志里有这一行。这把问题定位到 **test discovery / bundle 加载阶段**，而不是 never-ending 的 RunLoop 阻塞——test 方法根本没被执行过，所以「阻塞主线程导致握手失败」这个方向也可以排除。
- **[推断] 下一步最干净的二分法**：往**已知能跑通**的 spike target（`sample-app-ios` 的 `SampleAppUITests`，它有 host、能建 automation session、三个探针全绿）里加一个 never-ending test。
  - 若它也退出 → 问题在 never-ending 模式本身（XCTest 不允许 test 方法不返回），需要换常驻机制。
  - 若它能常驻并应答 → 问题在 `reticle-runner-ios` 的工程配置，逐项对比两个 target 的构建设置即可收敛。

  这一步把「工程配置」和「常驻模式」两个变量分开，比继续在 runner 工程上试错便宜得多。
- **[事实] 二分实验的结果推翻了本节前面几条证伪结论。** 把 never-ending test 放进**早上刚刚三探针全绿**的 `SampleAppUITests` target（`NeverEndingProbeTests.swift`，除阻塞循环外与已跑通路径完全一致），当晚 20:57 运行——**同样** `channel refused` → `Exiting due to IDE disconnection`。

  也就是说：不是 never-ending 模式的问题，也不是 `reticle-runner-ios` 的工程配置问题，而是**设备/环境状态在这几小时内变了**（早上 09:54–10:04 全绿，20:42 起全部失败）。

  **因此本节前面这两条结论都不可信，必须在环境恢复后重测**：「devicectl 独立 launch 不能常驻」「加 test host 无效」。当时的失败很可能全部来自同一个环境原因，而不是各自的技术原因。
- **[事实] 排除了锁屏**：失败时 `devicectl device info lockState` 报 `passcodeRequired: false` / `unlockedSinceBoot: true`，`displays` 报 `backlight is on and active`。
- **[推断] 最可能是设备端 Enable UI Automation 开关被关闭，或设备侧 automation 状态需要重启才能恢复。** 这与本仓库 `IosRunnerFailure` 判别器对该形态的归类一致——`channel refused` + `IDE disconnection` 正是它被设计去识别的伪装形态，这次它的判断是对的。
- **[教训] 长时间真机排障必须先跑一个已知能过的基准用例。** 本轮浪费了三次真机往返去「证伪」一个其实没被证伪的东西，原因是把环境当成了常量。基准用例先跑，能立刻区分「代码坏了」和「环境坏了」。
### 环境恢复后的定论（2026-08-12，设备重启后重测）

重启设备后基准立刻通过（`PROBE-ALIVE` + `Test Case … started`），确认此前所有失败均为环境所致。在**已知良好**的环境下逐条重测，最终事实如下：

- **[事实] never-ending test 模式成立。** 基准探针常驻并通过 USB 隧道应答。
- **[事实] `reticle-runner-ios` 工程可用。** `xcodebuild test` 启动后 `/health` 返回真实数据：`{"screenWidth":428,"screenHeight":926,"pointScale":3,"version":"0.1.0"}`。
- **[事实] `xcodebuild test-without-building -xctestrun <…>` 能让 runner 常驻，且不重新构建。** 这是本能力最终采用的启动方式，NFR-001 由此成立：构建只发生在 `prepare`，之后每次会话只是启动。
- **[事实] `xcrun devicectl device process launch` 独立启动确实不能常驻**（这一条在坏环境下测过，在好环境下复测结论不变）：runner 起来、拿到 backboardd HID 连接、打印 `Running tests...`，然后数秒内退出，从未执行 test 方法。
- **[结论] plan 的 Decision 3 选错了分支**，已订正为 `build-for-testing`（一次）+ `test-without-building`（每次会话）。代价是宿主要持有一个 xcodebuild 子进程作为通道的生命周期句柄。
- **[事实] 设备只有一个 automation session。** 基准探针不停掉，runner 就起不来。宿主的 `stop()` 因此必须同时终止那个 xcodebuild 子进程，否则它会占住会话，导致下一次启动以一个看起来毫不相干的原因失败。

## 一之三：Phase 2 实现期在真机上暴露的事实（2026-08-12）

以下五条都是真机跑出来的，不是推演出来的，且每一条都会造成静默的错误证据：

- **[事实] 系统弹窗的 `XCUIElement.ElementType` 是 7**（不是 47）。修正前它以 `unrecognized:7` 出现——这正好验证了 `SystemRole` 那条「未知类型不丢弃、不误映射」的设计：错误是可诊断的，而不是被悄悄折叠成 `other`。5 / 7 / 8（sheet / alert / dialog）现在都映射为 `.alert`。
- **[事实] XCUIElement 查询必须在 test 自己的线程上发起。** 在 `NWListener` 的后台 queue 上调用会直接杀死整个 test；宿主侧只看到 `The network connection was lost`，完全指不到病因。修法：HTTP handler 用 `DispatchQueue.main.sync` 派发回主线程——never-ending test 正停在主线程 run loop 上，能排空 main queue。
- **[事实] `devicectl device info processes` 打印的是可执行文件路径，不含 bundle id。** 用 bundle id 去匹配存活状态永远返回 false，于是 `stop()` 认定「无可停止实例」并报告成功，实际 runner 仍在跑。只会答「否」的存活检查比没有更糟，因为下游全都信它。改用可执行名 `ReticleRunner-Runner`。
- **[事实] CLI 每条命令是独立进程，进程内的子进程引用活不过命令边界。** 上一条命令启动的 `xcodebuild test-without-building` 成为孤儿，占住设备唯一的 automation session，下一条命令以 `health-timed-out` 失败——症状离病因十万八千里。`stop()` 与 `ensureConnected()` 都改为按命令行特征（`test-without-building.*<udid>`）回收孤儿。
- **[事实] `ensureConnected()` 里发生的启动同样打断前台，必须计入证据。** 原实现只有 `IosRunnerSession` 的「请求中途重启」会被标注，而通道停掉后的首次启动不会——但对被测流程的干扰完全相同。现统一标注为 `runner-started-mid-command`。
- **[事实] 宿主的 `shell()` 原本存在管道死锁风险**：先把 stdout 读到 EOF、再读 stderr，只要子进程先写满 stderr 的 64KB 缓冲就双向阻塞，而 `xcodebuild` 正是会向两个流写大量数据的子进程。已改为并发排空两个管道。
- **[事实] `--target` 在本 CLI 中已固定表示平台（ios/android）**，不可复用为读取目标。`system tree --target home` 会被解析成「平台=home」并以「非 iOS」被拒。读取目标改为位置参数：`system tree home`。

- **[事实] 读取与探活必须用不同的超时。** 统一 20s 会让一次 home 树读取超时（200 节点 × 跨进程查询，随屏幕状态波动），而把统一超时拉长又会让存活探测迟钝。现为读取 90s、`/health` 8s：慢读取不能被误判成 runner 死亡，runner 死亡也不该等一分钟才发现。

## 二、宿主侧接入点（代码事实）

- **[事实] CLI 是两级 dispatch，加一级子命令很自然。** `reticle-host/Sources/ReticleHostCore/CLI/ReticleCLI.swift:192-223` 是 `switch` 表，`ui` 一支即 `case "ui"` 内再 `switch` 出 `report`/`screenshot`/`tree`/... 。`system` 一级可完全对称地加在同一表内。
- **[事实] `HostBackend` 协议是固定的 12 个方法**（`reticle-host/Sources/ReticleHostShared/HostBackend.swift:25-42`），含 `uiReport` / `screenshot` / `act` 等，且 `close()` 有默认空实现。**system 通道不应挤进这个协议**：它的方法集与既有 12 个不重叠，且 Android backend 无法实现——协议是跨平台共享的。
- **[事实] loopback HTTP 客户端有现成范式可类比**：`reticle-host/Sources/ReticleHostIos/IosAgentHTTP.swift:9-36`，`get`/`post` + 由 `port` 计算 URL。
- **[事实] 端口派生规则已存在且可直接复用**：`reticle-swift/Sources/ReticleProtocol/PortMap.swift`，`derivePort(appId)` = FNV-1a 32 位取模落在 `[8765, 9765)`。runner 用**自己的** bundle id 走同一规则，即可与目标 app 的端口天然不撞，无需新增分配机制。
- **[事实] 真机 loopback 需隧道，既有做法是 `iproxy -u <ECID> <port> <port>`**（`scripts/inject-ios-device.sh:104`；`scripts/e2e-ios-device.sh:16` 说明了原因：真机的 loopback 不是宿主的）。ECID 对 `devicectl --device` 与 `iproxy -u` 均可用。
- **[事实] 触摸 surface 只有一个 seam，且 `resolve()` 一次决定**：`reticle-host/Sources/ReticleHostIos/IosTouchSurface.swift`，`enum` 现有 `.hid(udid:)` / `.agent(bundleId:)` 两个 case，`describe` 供证据输出。
- **[事实] 进程外坐标的拒绝发生在 agent 侧、由宿主转述**：`IosTouchSurface.post()` 在 `result.dispatched == false` 时抛 `HelperError("in-process touch failed: \(result.message)")`，注释已说明 message 会是「本进程没有窗口包含该点」。**这是 US5 唯一需要改的地方**——补充两种可能与 system 通道指引，不改变拒绝这一行为本身。
- **[事实] 截图结果已有来源与降级两个字段**：`ScreenshotResult { pngBase64, via, degraded }`（`HostBackend.swift:378-390`），`degraded` 的注释即「这张图已知缺了什么」。US4 的取景范围标注可直接落在 `via` + `degraded`，无需新字段。
- **[事实] `source=` 已是 act 结果的既有输出惯例**：`ReticleHostCore/CLI/ReticleCommands.swift:302` 会把 `source` 拼进结果首行。
- **[事实] 「读不到就自报」在协议层已有先例**：`Node.styleGaps`（`reticle-swift/Sources/ReticleProtocol/Snapshot.swift`）是 `[String: String]`，键为属性名、值为不可读原因，注释明确「an unreachable thing names itself rather than looking absent」。NFR-003 应沿用这一形状而非发明新机制。
- **[事实] 另一进程占焦点已有既有证据字段**：`Screen.windowFocused`（`reticle-swift/Sources/ReticleProtocol/Geometry.swift:122`），并已进入 `WaitPredicate`。
- **[事实] `NodeKind` 是封闭枚举**（`Snapshot.swift:5-13`）：`application` / `window` / `view` / `composeSemantics` / `axElement` / `domNode` / `probe`。
- **[事实] 边界表在 `docs/boundaries.md`**，每行四列（不可达项 / 为什么 / Reticle 改为输出什么 / 由哪个测试或 scenario 覆盖），iOS 机制细节在 `docs/ios.md` 的 "Honest boundaries" 段。对应 NFR-009。
- **[推断] 真机 e2e 应新增独立脚本而非扩写 `scripts/e2e-ios-device.sh`。** 依据：现有脚本的前置条件（linked agent、app 前台、iproxy 到 app 端口）与 system 通道的前置条件（runner 已装、UI Automation 开关、iproxy 到 runner 端口）不同，且 system 通道会主动把 app 踢到后台——与现有脚本「保持 app 前台」的假设直接冲突。

---

## 三、变更影响分析

本次改动触及对外契约与共享符号，故记录如下：

- **受影响的共享符号**
  - `ReticleProtocol.NodeKind`：若 system 通道的节点复用 `Node`，需要新增来源区分。**不可破坏的语义约束**：现有 7 个取值被两端（Swift + Kotlin 双写）与快照解析共同消费，`docs/ios.md` 与 boundaries 文档也按此叙述；新增取值会要求 Kotlin 侧同步，属于协议双写风险（见记忆 `full-audit-2026-08-01` 记录的协议漂移批）。
  - `IosTouchSurface`：新增 case 会使所有 `switch` 处失去穷尽性，需逐处确认。
  - `HostBackend`：**不应改**。往协议加方法会强迫 Android backend 实现一个平台上不存在的能力。
- **潜在风险点**
  - `Node.styleGaps` 语义被扩用于「整条通道读不到」而非「这个属性读不到」时，可能让既有消费方误判粒度。
  - runner 与目标 app 各占一个 loopback 端口，两条 iproxy 隧道并存；若沿用同一 `PortMap`，需确认两个 bundle id 不会哈希碰撞到同一端口（概率低但需在准备阶段显式检测并报错，而非静默复用）。
- **预测需回归的入口**
  - `act tap/swipe/drag/scroll-to` 在真机上的既有拒绝路径（US5 改动点）。
  - `ui screenshot` 在真机上的 `via` / `degraded` 输出（新增来源后不得改变既有取值）。
  - `scripts/e2e-ios-device.sh` 全流程（确认 system 能力的引入未改变 linked-agent 路径的行为）。
  - `DeviceTouchTests`（`docs/ios.md` 称其为私有 surface 的 canary）。
