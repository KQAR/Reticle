# Reticle 路线图

[English](roadmap.md) | **简体中文**

**本文讲 Reticle 往哪走**：还剩什么（按优先级），以及哪些决定已经拍板、不必再讨论。
其余文档各自的职责由 `AGENTS.md` 统一给出。

状态：2026-08-05，对应 0.17.0。捕获 / 驱动 / 证据这条主干已完成且跨平台；
**边界能力扫描**（15 个点）于 2026-07-25 收官。剩余工作全部列在
[还剩什么](#还剩什么)——本文除该节外，没有任何一节是待办清单。

---

## 目标，以及唯一的范围决定

最终目标是**开发完成后的 E2E 校验**：agent 在真机上把一个做完的功能端到端跑一遍，
逐步检查。

**Reticle 只提供证据，不下判定。** 产品动词是 *observe / drive / capture*，绝不是
*assert*。它输出状态、树、网络事件、截图、操作 trace；由 agent（或人，或测试框架）
判断这一步过没过。由此推出一条对下文每一项都生效的约束：协议和 CLI 永远不会引入
`assert`/`expect` 原语。要优化的是证据质量——结构化、可 diff、可比较。

底线：**无 root、无重打包、无字节码 hook。** 以及三条结构性（而非 Android 特有）的
天花板，换个平台也不会"变好"：

- 对象检查只有类元数据反射 + 可达对象图，永远不做堆实例枚举（真要看堆：`am dumpheap`
  离线分析）；
- 网络抓取只有 host 侧 MITM，不做进程内流量的被动截获；遇到证书绑定是**如实上报**
  而不是绕过；
- 注入只覆盖 **debuggable** 应用（JDWP）或主动链接 agent 的应用——任意 release 包是
  Frida/root 的地盘，本项目不进。

还有一条约束同样贯穿所有后续项，因为它决定了这是"校验工具"还是"看起来像校验的工具"：
**确定性选择器是主干。** 自然语言目标、靠截图猜位置，都不会被提升为主要定位路径。
`ui outline --live` + `@N` 别名是可接受的便利层；探索是覆盖率辅助，永远不是校验路径。

因此跨平台的资产是**协议**，不是共享源码：任何平台的 agent 只要说同一套 loopback
契约就能互通，用什么语言都行。

---

## 当前状态

| 领域 | 状态 |
| --- | --- |
| **观察**（Android） | View 树 + Compose semantics + WebView DOM 合并进同一张扁平 `ref → Node`；语义树与 compact 在进程内派生；多目标控件有 regions / 字符网格 |
| **观察**（iOS） | UIKit 树 + SwiftUI `axElement` 桥（含单个 `Text` 内部的链接）+ `WKWebView` DOM；同一套协议 JSON |
| **驱动** | `tap` / `swipe` / `drag` / `scroll-to` / `type` / `hide-keyboard` / `activate`，选择器优先，支持 `--region`、`--label`、`--settle`、`--verify`、`act batch`（`@N` 别名**仅 Android**——outline 缓存未移植到 iOS host，`Render.swift` 就地写明了这一点）。Android 与 iOS 模拟器上是真实 HID；iOS 真机用进程内 activation |
| **证据** | 操作 trace（前后快照 + 截图 + 排过序、自描述的 diff），默认录制；`trace log` 摘要、`replay gif`、session 时间线，以及"说出缺席"的词汇表（`window: UNFOCUSED`、`dom:unavailable`、`dom:unsupported-kernel`、`pixels:unavailable`、`screencap:blank`、`occluded-by:*`、`scroll:*`） |
| **网络** | `reticle serve` 抓包线跑在 Loom 的 `ProxyEngine` 上，HTTPS MITM + CA 签发，session 级流量规则（`mock`/`block`/`mapRemote`/`passthrough` + 修饰符），flow replay + diff。Android 与 iOS（模拟器与真机）均可用 |
| **面板** | 本地只读证据面板：trace、产物、网络卡片（过滤、按规则分组、"copy as rule"）。设计上只展示 |
| **协议** | `reticle-protocol/` 内的 JSON Schema(2020-12) 为权威，附 golden fixtures；Kotlin 与 Swift 是手写实现，两侧同时对 schema 校验 |
| **分发** | Swift host + GraalVM 原生 Kotlin helper，以预编译 release 分发；Claude Code / Cursor 插件清单版本锁步 |
| **覆盖** | `scripts/e2e-android.sh` 与 `scripts/e2e-ios.sh` 在真机/模拟器上跑遍每个 scenario，每步都断言一个可观察副作用；`scripts/e2e-proxy.sh` 在 CI 守住抓包线 |

以上每一项的操作细节都在 `docs/architecture.md`。

**平台对等情况。** Android 与 iOS 在 observe / drive / capture + 证据上已实际对等，
覆盖模拟器与真机：iOS agent、host 平台层、WebView 桥、操作 trace、抓包代理都已落地，
链接 agent 的真机路径在 iPhone 13 Pro Max / iOS 26 上验证通过
（`scripts/e2e-ios-device.sh`——USB 隧道上的观察、`activate`、`mutate`、trace 证据，
外加代理绑 LAN 后一条解密的 HTTPS 事件）。唯一剩下的结构性缺口是**真机 HID 输入**
（第 5 项）。HarmonyOS 尚未开始且零验证——见"暂缓"。

---

## 还剩什么

按杠杆排序。规模粗估：**S** ≈ 一天，**M** ≈ 几天，**L** ≈ 一个项目。每项还标注病因的
确立程度：*已实测*（在设备上复现过）、*由构造可知*（代码不可能是别的样子），或者什么都
没标——什么都没标的，动手前第一步就是去复现
（见[决策记录](#决策记录)里的"补齐能力前先查病因"）。

### 1. 长会话卫生 — S，由构造可知

E2E 跑得久，而这个已知泄漏恰好只在长跑时咬人。

- **`network-bodies/` 无淘汰。** 每条 flow 写一个 body 产物且从不回收，长校验会话会
  漏磁盘。淘汰必须与事件环的淘汰联动：body 是仍被存活事件引用的证据，不能在其脚下抽走。

### 2. 已经藏过 bug 的测试空白 — M

审计中最大的缺口，而且不是理论问题：`nativeID` 的"捕获与解析不一致"就藏在这里。

- **进程内 Android agent 零单测。** `MutationEngine`（选择器解析）、`SnapshotCapture`
  （testId 链）、`ReticleReflect`、WebView/Compose 桥全无测试，其中纯逻辑部分完全可用
  JVM/Robolectric 测。
- **注入编排无测试。** `JdwpClientTest` 只覆盖握手与 id-size 协商；
  `JdwpClient.inject()` 的断点/InvokeMethod 序列和 `Injector.inject` 的顺序 + 死区重试
  只在设备上验证过。
- **Swift 侧规则 → Loom 的 `translate*()` 层与 HTTP 路由层。** 翻译层（path→regex
  提升、优先级排序、丢弃空操作）是整条 lane 最易错的单点；`rules` 与
  `flows/:id/replay` 没有路由级回归网。

### 3. 证据装配产品 — 各 M，尚未开工

原语都在，只是靠 agent 手工拼。下面每一项都把它们装配成人能直接消费的东西；三项都只
输出量级，不给等级。顺序 **A1 → A2**（A4 已作为 `replay gif` 落地；A3 按原设计已废弃，
见下）。

- **A1 — PR 证据机器人（`reticle review`）。** 读 diff → 用确定性 flow 驱到受影响页面
  → 把 trace + compact diff + 网络事件 + 截图装配成一条 PR 评论。复用 `act batch`、
  `--trace-output`、session 时间线。
- **A2 — 视觉回归（`reticle diff visual`）。** 两个构建之间做像素 diff，输出变化区域
  叠加图。与结构 diff 互补：结构 diff 回答"文案/状态变了"，像素 diff 回答"布局/渲染
  漂了"。阈值是提示，不是判定。
- **A3 — 按原设计已废弃；能力那一半以 `ui style` 落地。** 原计划是把设计稿组件框与
  实时节点 rect 对齐、输出每个区域的偏差。那是判定套着观察的壳，而"不打分"只挡住了
  三条路里的第三条：读设计稿就引入了外部真值，让 Reticle 成了"什么算对"的裁判；算
  偏差需要阈值，阈值是策略；跳过状态栏需要豁免名单，那是业务策略。三者都属于消费方。
  真正只有从进程内才知道的东西——值、值所在的单位、以及哪些属性没有任何通道能读——
  现在是 `ui style`（`StyleObservation`）；Reticle 不关心调用方拿它去比设计稿、比上个
  版本，还是比另一台设备。

  两条附带结论值得留档。**`reticle diff responsive`** 也被同样的理由否掉了，尽管它
  不引入外部真值：判定一个宽度"应当按比例缩放"而不是"应当固定 dp"，本身就是设计意图。
  `ui style` 改为把每个长度同时给出原生单位、dp、（文字还有）sp 以及占屏比例，由消费方
  决定它期望哪一个跨设备恒定。而 **A2 保留**——它比的是 Reticle 自己拍的两张图，不引入
  任何外部真值。
- **A5 — 导航/覆盖图（`reticle map`）。** 把 `ui outline` 与 trace 的页面跳转折成
  "页面 → 可达路径"，严格定位为覆盖率辅助（"哪些页面还没有 flow 碰过"），绝不是校验
  路径。优先级最低。

### 4. 跨信号关联 — M，校验时最疼的缺口

session 时间线已经把 UI 操作 + 网络 + 截图统一了，但一次校验在点完之后真正要问的两个
问题——*该发的埋点发了吗？* *崩了吗？*——还在各自独立的工具里
（`sensors-query`、`sentry-query`），今天由 agent 跨工具手工对齐。把埋点/错误信号折进来
作为证据源，需要的是一层编排，不是新的捕获机制。

### 5. iOS 真机输入悬崖 — L，先量化再动手

真机只有 `act activate`（靠选择器）；坐标点击、复杂手势、键盘 `type` 都需要模拟器的
HID 面。因此任何"没有稳定选择器"的真机步骤都没被覆盖。要补就得上 XCUITest/WDA 或
CoreDevice，是个真项目。**先量清楚 `activate` 到底覆盖不了多少真机动作**——适用"先查
病因"规则。

### 6. 阶段遗留 — S–L，纯增量

- **运行时对象检查 + 布局诊断（`ui audit`）** — L。把 `mutate` 背后的反射泛化成运行时
  类元数据与约束检查。天花板同上：只有可反射元数据 + 可达图。
- **WebView L2（语义增强）** — S。用现有遍历脚本读 ARIA role + accessible name，与语义
  树对齐。L0/L1 已落地。
- **选择器解析下沉** — M。选择器解析是最后一块还留在 host 的派生逻辑；沉进 agent 才算
  补完 thin-client 边界，也让"单次捕获一致性"更紧。
- **其余事件族的 typed schema** — S。`network.*` 已有 schema 且两侧钉住，action/runtime
  的 payload 还没有。
- **规则的 header/body 匹配谓词** — S，**按需再做**。等出现真实用例，不提前建。

### 7. 安全证据线 — 各 M，尚未开工

在安全语境下 Reticle 是**防守方的证据引擎**：观察、驱动、捕获。以下永久不做，因为越过
no-hook 底线：绕过证书绑定、运行时注入 CA 信任、hook 采集管线 / 虚拟摄像头注入、逆向
破解二进制。先做 **B2**——它最贴合"确定性驱动 + mock"的形态。

- **B2 — 风控流程回归 harness。** 驱动活体 / 人脸上传 / 设备核验流程，捕获它们发往外部
  校验服务的调用，用 session 规则 mock 出不同外部结论（可信 / 不可信 / 降级），从而确定
  性地跑通客户端每条分支。
- **B1 — 敏感数据传输证据。** 在现有 MITM 线上标注：明文传输标记、请求/响应体中疑似敏感
  字段（可配模式）的位置标注，以及隧道解不开时如实标"不可观测"。
- **B3 — 客户端安全态势快照（只读）。** debuggable 标志、用户 CA / network-security-config
  标注、WebView 是否开 JS 与是否存在混合内容，以及反射可见的组件暴露面。依赖第 6 项的
  `ui audit` 能力。

### 8. 文档欠债 — S

原有几条已关闭。剩下的是结构性的：

- **两份全量 README 是一笔常驻成本。** 至今已经补过两次、且是双向补的——这本身就是信号：
  一个功能落地要写两遍，否则某一边会静默丢掉它。如果第三次再漂移，就把中文 README 砍成
  一页定位说明、深度内容指向英文，而不是再同步 400 行。

### 未解 flake（软件 GPU 模拟器）

- `lottie-web` 动画期间用单次快照做 DOM 断言：750ms 的 `evaluateJavascript` 预算耗尽，
  整个 DOM 收起来。已改为轮询规避，预算本身的问题仍开放。
- 原生 Lottie 弹窗偶发在 60s `wait_compact` 预算内不出现——2026-07-25 又见两次，且
  **隔离下无法复现**（手动 4/4 绿，触发按钮 rect 从第一帧就稳定，所以不是 `tap --settle`
  那一类）。没有瞎猜着修，而是让 `wait_compact` 超时时打印最后一次观察，下次再现就能看出
  是"点根本没落上"还是"弹窗在但捕获在动画负载下降级了"。

- **`scripts/e2e-ios.sh` 依赖"热"应用状态。** 2026-07-29 在新建模拟器上实测：示例
  应用停在 Login 页，脚本第一步导航（`act activate --test-id scenario.checkout`）
  找不到该节点，整轮就此中止。而在用过的模拟器上，应用已经过了登录，套件能通过——
  也就是说这套 e2e 只在"热"设备上可复现，正好和 fixture 应有的性质相反。不是产品缺陷
  （两条路径行为都正确），而且显而易见的修法有约束：提前登录**不能用 type**，因为第一个
  HID 键盘事件会锁死模拟器的硬件键盘状态，从而毁掉同一轮后面 LOGIN 段自己的键盘断言
  （见 docs/boundaries.md）。

### 暂缓——等触发条件

- **HarmonyOS 可行性探测。** HarmonyOS 的三个接缝（`hdc` 的 forward/input、调试注入通道）
  都是纸面占位，**零验证**。*触发条件：* 在 HarmonyOS 进入任何已承诺计划之前，先花一次
  短 spike 确认接缝存在；在那之前一律标 `est.`/`TBD`，不做承诺。
- **面板反向驱动。** 面板目前是单向 SSE 的只读展示。让浏览器去驱动 App 会强制改成双向传输
  （WebSocket）并带来实打实的前端工作量。*触发条件：* 在改动面板传输层之前决定，避免
  SSE 与 WebSocket 之间返工两次。
- **协议代码生成统一。** Kotlin 与 Swift 的模型 / 渲染 / 选择器 / trace diff / WebView
  脚本是 1:1 手写，靠对同一份 schema 的测试防漂移。codegen 是大工程、回报慢。
  *触发条件：* 出现一个 schema 测试没抓住的漂移 bug。

  **这个触发条件已经响过一次，答案是加 fixture 而不是 codegen。** 两个手写的 host 侧
  selector 解析器之间漂了七处——其中一处让 Swift 侧的查找每进程随机——而 schema 测试
  一条都抓不到，因为这些全不是 wire 形状。修法是 `selector-resolution.cases.json`：
  两端共读的决策表，和 `wait-classification.cases.json` 是同一个手法。在漂移面是
  **行为表**而不是**模型**时，这是更便宜的答案。等模型本身出现漂移（fixture 描述不了
  的那种契约）再回来看 codegen。

---

## 决策记录

已拍板。连同理由一起记下来，免得被默默重开。

**协议是脊柱，不是代码。** agent 与 host 走 loopback HTTP + JSON。`reticle-protocol/`
存放权威 JSON Schema(2020-12) + golden fixtures + `events.md`（daemon 事件信封与分类）
+ `helper-rpc.md`。Kotlin(`reticle-core`) 与 Swift(`reticle-swift`) 是**手写实现，两侧
都对 schema 校验**——保持手写是为了保留文档注释与密封层级的序列化处理（codegen 处理得
很差）。未来全新平台可以从同一份 schema 生成；"生成还是手写"是逐平台的选择。

**只有三个接缝与平台相关**，HTTP 传输层本来就与平台无关：

| 接缝 | Android | iOS | HarmonyOS（估计，未验证） |
| --- | --- | --- | --- |
| 设备控制 / 传输 | `Adb` | `xcrun simctl` + CoreSimulator | `hdc` |
| 注入 | JDWP + payload dex | DYLD constructor（模拟器）/ 链接 framework（真机） | TBD |
| 输入合成 | `adb input` | 私有 CoreSimulator HID | `hdc input` |

预留的含义是**只留接口，不留空壳**——不建空的平台模块。只有 agent（进程内代码）真正
与平台绑定并拥有各自的构建（AAR / SwiftPM / HAP）；`reticle-agent/` 是分组目录，永远
不许有自己的 `build.gradle`。

**host 是瘦客户端，派生逻辑住在 agent。** 捕获派生视图（`SemanticTree.build`、
`CompactObservation.from`）在进程内算好、以成品 JSON 返回。`PortMap.derivePort` 是刻意
的例外——host 必须在够到 agent **之前**就知道端口，所以它是一条两端各自实现、结果必须
一致的协议规则。选择器解析是最后一块还在 host 的（第 6 项）。

**Swift host + 各平台 helper——已落地。** host 程序（CLI + daemon + 面板，同一个进程）
是 Swift；Android 的设备脏活留在 Kotlin，藏在 RPC 缝后面，以免 JDK 依赖的 GraalVM 原生
`reticle-helper` 分发。为什么不整体重写：JDWP 注入天然只能在 host 侧（agent 是注入的
*结果*，不是前提），而且天然属于 JVM——它 git 历史里的每个修复都是啃下来的
ART/dexopt 边界情况。**只有当某平台的脏活不在 host 生态里时才配 helper**：Android 需要，
iOS 不需要（simctl/DYLD 对 Swift host 是原生的）。接受的代价：两个常驻进程，以及 Android
热调用要跨进程——换来的是彻底消除 JDWP 重写风险。

**daemon 持有全部长生命周期状态。** 一次性命令仍可独立工作；`reticle serve` 在跑时它们
额外向其发布事件。session 把设备 + 应用 + 时间窗绑成一条时间线。内存有界环 + JSONL 落盘；
大 body 与截图落到 session 目录、由 `refs` 引用，绝不内联进事件。实时推送用 SSE + REST
——WebSocket 只为反向驱动保留，而那是暂缓项。

**抓包引擎藏在一个 sink 后面。** `NetworkEventSink`（emit + sessionDirectory）是这条 lane
看得见 host 的唯一入口，所以换引擎只需要改一个 target。引擎问题已定：Loom 的
`ProxyEngine`，以 SPM 库消费，loopback 运行且 `persistFlows: false`——传输、MITM、CA 是
Loom 的，存储与归一化是 Reticle 的。

**抓包代理止步于 host（L1）。** HTTP 明文随便抓；HTTPS 只在应用信任本地 CA 时可解；证书
绑定会挡住它，我们**如实上报**而不绕过。曾考虑过的 "L2 agent 协助"模式（运行时注入 CA
信任 / 中和 pinning）已**否决**，以守住 no-hook 承诺。

**WebView DOM 是 Compose 桥的再次套用，不是新机制。** DOM 元素以 `NodeKind.domNode` 并入
同一张扁平节点表，因此 compact / tree / 选择器 / tap 原样复用。与 Compose 不同的两点：
读取是异步跨边界的（`evaluateJavascript`，有界超时闩住），坐标要从 CSS px 折算到屏幕 px
——协议钉死：`domNode.frame` **已经**是屏幕坐标系。分级如实降级：L0 不透明叶子 → L1 DOM
结构（已落地）→ L2 语义（第 6 项）。Chrome Custom Tabs / TWA 属于另一个进程，不在范围内。

**补齐能力前先查病因。** 在"平台 A 有、所以给平台 B 补"之前，先证明同样的病因在 B 上存在。
正是这条规则让边界扫描保持诚实——好几个"缺口"其实是另一个问题，还有一个根本不存在。

---

## 调研过并放弃

**`act wait --for <appears|gone|stable|enabled|network-idle>`** —— 代码级审计后以可靠性
为由放弃。一个会静默返回错误答案的 wait 比没有 wait 更糟，而它要轮询的地面真值撑不起
可靠答案：

- `isVisible` 是弱且两端不一致的代理（Android：`visibility==VISIBLE && w>0 && h>0`，不看
  祖先链也不做在屏判断；iOS：链式 `parentVisible && !isHidden && alpha>0.01`），而且
  **原始节点都不带遮挡信息**——遮挡只在 compact 层计算。于是 `appears` 可能对一个点不到的
  节点报"可见"；
- ref 每次捕获重新生成，所以 `ref`/`alias` 无法在两次轮询间标识同一个节点；
- 选择器解析会坍缩到第一个匹配，而两次轮询的"第一个"可能是不同节点，任何前后对比都被破坏；
- `stable` 看不见 transform/alpha 动画（只看布局边界），而且逐次全量快照本身会扰动被观察的
  动画。

`appears` 唯一可靠的定义是"此刻发出的一次点击会落在这里"，那需要主干层的可见性统一，不是
一层轮询。已落地的 `tap --settle` 是这件事诚实的窄切片：与 tap 同一条解析路径、只看位置，
并且它明说这一点——扫描记录里就有"仅位置稳定不够"的实测案例。

**L2 agent 协助的 CA 信任 / pinning 中和** —— 已否决，见上面的抓包代理决策。

**堆实例枚举** —— 结构上不做；诚实路径是 `am dumpheap` 后离线分析。

---

## 已完成的专项：边界能力扫描（2026-07-25）

对"工具还覆盖不了的 case"做的一轮按优先级排序的扫描，一点一个 PR，每次同一套纪律：
**先在设备上证明病因**，只修证据支持的部分，然后在两端 e2e 里各钉一条断言。这个顺序值回
票价——一半的点其实是"失败即静默返回空"的真缺陷，而两个"修复"当场又被套件抓出新问题。

15 个点、PR #107–#121，全部合入。除单点修复之外留下的长期产出：每次捕获都会说的
**缺席词汇表**，以及 `docs/boundaries.md` 的 **Honest boundaries** 表——下一个这类
case 就记到那里。

| 点 | 实测病因 | 结果 |
| --- | --- | --- |
| 区域通道 | `a11yVirtual` 按 `0 until childCount` 探虚拟 id，但 id 是**应用自己的**（`ExploreByTouchHelper` 可能用稳定的业务 id）→ 零区域；`touchDelegate` 读 `TouchDelegate.mBounds`，而平台对现代 target 一律拦截（`api=max-target-o`）→ 该通道在任何真实应用上都是死的 | 两个都修（androidx helper 路径 + 公开的 `getTouchDelegateInfo()`）；iOS 补上第二种 `UIAccessibilityContainer` 约定；`--region <source>` 可寻址无标签通道 |
| Compose semantics | 桥能用，但**零覆盖**（仓库里根本没有 Compose） | Compose scenario + e2e：testTag 点击、往 composable 输入框 `type`、Compose `Dialog` 自成一窗、`AndroidView` 互操作 |
| Compose 文本链接 | 带两个 `LinkAnnotation` 的 `Text` 是**一个**节点，无 regions、无字符网格（而 `ClickableSpan` 行能正常拆开） | `ComposeTextRegions`：链接范围取自 semantics 配置，几何取自 `GetTextLayoutResult` |
| 同源 iframe | 穿透与页面偏移本来就是**对的**，只是没人断言（iOS 只验了 JS 激活，rect 错了也能过） | 两端补坐标点击断言 |
| 屏外列表行 | 回收/惰性列表只绑定可见窗口：60 行里只绑 0-14（Android）/ 0-12（iOS）。第 40 行没有节点、没有 frame、没有选择器 | `Node.scroll` 证据（compact 里的 `scroll:up,down`、选择器未命中时的滚动提示）与 `act scroll-to` |
| 弹出窗口 | `PopupWindow` / `Spinner` 下拉 / `PopupMenu` 都能正常捕获——但它们的行共用一个 resource id，没法单独指定 | `--label` 选择器（精确 → 子串，取有匹配的最顶层窗口，**歧义即报错**） |
| DOM 读取被阻塞 | 降级本身是对的（~1s，退回不透明节点）但**静默**："没有 DOM 节点"与"空页面"无法区分 | 宿主节点上的 `dom:unavailable` 标记，两端 |
| iOS 窗口遮挡 | 每个 `UIWindow` 都被记成 `kind = .view`，于是窗口对窗口的遮挡在 iOS 上从未触发过——覆盖层窗口之下的一切看起来都还能点 | 改为 `kind = .window`，但排除键盘宿主窗（整屏大小，会把整屏标成被遮挡） |
| 跨进程窗口 | Android 权限弹窗弹出时，`mCurrentFocus` 是权限控制器，而捕获仍把每个控件列为 `tappable`。进程内**截图**同样看不见它 | `screen.windowFocused` + compact 首行 `window: UNFOCUSED …`；两端各有 permission scenario |
| 点击移动中的目标 | 解析与派发是两步：动画中被捕获的 `PopupMenu` 行在 y=1396，tap 解析到 y=1474，菜单最终停在 y=1612——`--label "Delete item"` 打出了 "Menu: Rename"（5 次中 1 次）。iOS 的同名问题**不是**这个：`UIAlertController` 的 AX frame 从第一帧就是终值，而 `activate` 之后立刻点根本落不上——那是原地 transform 动画，任何位置信号都看不见 | `act tap --settle`（+ `--settle-timeout`）：重复解析直到坐标重复再派发，并如实报 `settled`。必须带选择器，裸 `--point` 直接拒绝。iOS 套件把这个区别钉住——弹窗上 settle 报 `settled=true`，延迟照留 |
| SwiftUI Text 链接 | markdown `Text` 是**一个**无障碍元素、一个 label：没有 `UILabel`、没有 `.link` run、没有子元素（实测 0）、没有 element count、没有 custom action、没有可用 rotor、没有 `_accessibility*` 访问器。而 `accessibilityAttributedLabel` **带** `UIAccessibilityTokenLink` 分段和每段字体 token | `SwiftUITextRegions`：用各段自己的字体在元素屏幕 frame 内重排 → 每条链接一个 `span` region + 字符网格。几何是重建的，所以断言走**后果**——点每个 rect，看 `openURL` 实际收到哪个 URL |
| 截图降级 | 两条路径是精确互补，而不是原以为的"进程内两样都缺"：`SurfaceView` 在进程内截图是透明洞（rgba 0,0,0,0）、在 `screencap` 里是洋红；`FLAG_SECURE` 则把**设备级**截图整张涂黑，进程内那张毫发无伤。iOS 是第三种形状：键盘宿主窗拒绝渲染进借来的上下文，捕获早就跳过了它——只是没说 | `pixels:unavailable` / `screencap:blank`，加上 `ui screenshot` 的 `degraded:` 一行，说明**这张**图缺了什么、哪条路径能看到。两端套件同时断言标签**和**背后的像素 |
| 第三方 WebView 内核 | 由构造即可确认：桥是按 `android.webkit.WebView` 定型的，只是"自称 WebView"的内核在任何层级都拿不到 DOM——而这与空页面无法区分 | 上报而不适配（反射适配器没有真内核样本无法验证）：`dom:unsupported-kernel` + `custom.domKernel`、`--css` 未命中时解释这堵墙，并用一个自绘替身挨着真 WebView，把对比断言下来 |
| 结构性边界 | 好几条是假设而非实测。写下来的过程逼出两次核对：**闭合** shadow root 只丢内容（宿主元素仍按自身 rect 被捕获），以及跨域那条离线确实没法演练 | `docs/boundaries.md` 的 **Honest boundaries** 表：每条边界挨着"改吐什么证据"和"哪个 scenario 钉住它"，没演练过的地方明写。skill 里放面向 agent 的一半 |
| iOS 失焦证据补断言 | 两个实测原因导致此前无法断言：弹窗无法**重新触发**（`simctl privacy … reset notifications` 直接失败），开着的弹窗也无法从 host **回答**，而卡住的弹窗会静默吞掉之后所有 HID 点击 | 用**重装 bundle** 重新触发；用坐标 HID 点击（屏高 ~57%，宽 ~32% 拒绝 / ~68% 允许，不读文字）在"回答→重试→复检"循环里回答；该段放在最后执行 |

套件抓出来的自伤 bug，作为失败形状值得记住：`act scroll-to` 最初是快滑（列表还在惯性滑动，
上报的坐标到下一条命令就过期了——现在改成慢拖并确认 `settled`）；它会挑**任意位置**最大的
可滚动容器，结果选到后台窗口的页面滚动器；它每轮重新选方向，于是选择器不存在时在列表末尾
来回摆。还有：示例应用自己的首页列表长过一屏，最后几行被裁掉、真的点不到——解析出的点击落
在了系统导航栏上。
