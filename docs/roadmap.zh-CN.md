# Reticle 路线图与多平台架构

[English](roadmap.md) | **简体中文**

状态:设计文档(2026-06-26)。记录了将 Reticle 从单平台 Android CLI 演进为
多平台运行时 harness(集成抓包代理与实时 Web 面板)的既定方向。这是计划,尚未
实现;`docs/architecture.md` 描述的是当前已有的内容。

## 愿景

最终目标:**应用需求开发完成后的端到端(E2E)测试与校验**——让 AI agent 在真机上
把一个完成的功能端到端跑一遍并检查每一步。一个关键的范围决定:
**Reticle 只提供证据,不下判定。** 产品的动词是 *observe / drive / capture*
(观察 / 驱动 / 捕获),绝不是 *assert*(断言)。Reticle 忠实地输出状态、树、
网络事件、截图和操作 trace;由 **agent**(或外部测试框架)来判断某一步是否通过。
因此协议与命令面**不会**有 `assert`/`expect`/`verify` 这类原语——它们得到的是
更丰富、更可比较的*证据*。这让工具保持诚实、可组合,并把证据质量(结构化、可 diff
的 trace 与网络事件)作为优化目标。

Reticle 今天从实时运行时检查并驱动一个运行中的 Android 应用(进程内 agent +
host CLI,经 loopback HTTP/JSON 协议)。本路线图在不放弃项目核心约束——
**无 root、无重打包、无字节码 hook**——的前提下,沿三条轴扩展:

1. **多平台**——Android 优先并做完整;iOS 与鸿蒙作为*薄*预留(协议 spec + 平台
   接口),尚未构建。
2. **whistle 式抓包代理**——一个纯 host 侧的 MITM 代理子系统,集成进同一个
   CLI/daemon,用于检查应用网络流量。
3. **实时 Web 面板**——一个统一 UI,展示代理流量、应用操作路径(tap/swipe/type
   序列)和状态截图,由一个长生命周期 daemon 供数据。

### "深度"能力存在真实天花板——在每个平台上都如此

本领域的先例(其他平台上、基于相同"进程内 server + host CLI"形态的运行时
harness)印证了"深度"能力存在真实天花板,也印证了下文的诚实边界并非 Android 的
局限,而是结构性的:

- 对象检查是**类元数据反射**,不是堆实例枚举。
- 网络捕获是**应用协作式或 host 侧 MITM**,不是对任意进程内流量的被动拦截。
- 任意真机注入**超出范围**——真机构建必须在构建期链接 agent。

因此跨平台资产是**协议**,而非共享源码。未来的 iOS 或鸿蒙 agent 只通过讲同一套
loopback 契约来互操作,用什么语言由平台自定。

## 原则:协议才是脊柱,代码不是

agent 与 CLI 已经通过 loopback HTTP + JSON 通信(`reticle-core/Protocol.kt` 中的
8 个端点)。未来的 iOS(Swift)或鸿蒙(ArkTS/C++)agent **不需要共享 Kotlin
代码**——它只需产出同样的 JSON。`reticle-core` 里的 Kotlin 类型是该 spec 的一种
实现;每个平台带自己的实现。

因此第一项预留工作是把 `reticle-core` 从"一组 Kotlin 类型"升级为**语言中立、
带版本的协议 spec**(JSON schema + golden fixtures + 契约测试)。Kotlin 类型由此
成为该 spec 的*一种实现*。这是多平台支持真正的脊梁,且现在做几乎零成本。

**Polyglot monorepo ≠ 单一构建系统。** 仓库保持 monorepo,但每个平台保留各自的
原生构建(JVM/Android 用 Gradle,未来 iOS agent 用 SwiftPM,鸿蒙用 hvigor)。
统一的是 **host CLI 二进制**和**协议 spec**——不是构建系统。这一点必须明说,免得
有人试图用 Gradle 去驱动 Swift 构建。

## 平台缝(只有三个)——薄预留

"为还不存在的平台做抽象"通常有抽*错*的风险(只有一个实现时看不出正确的接口长
什么样)。但这些缝是由"同类 harness 如何切分各自平台层"佐证出来的,不是凭空想象。
host CLI 中只有三处是平台特定的:

| 缝 | Android(今天) | iOS(预估) | 鸿蒙(预估) |
| --- | --- | --- | --- |
| **设备控制 / 传输** | `Adb.kt`(forward / push / run-as / pidof / screencap / 代理配置) | `xcrun simctl` + CoreSimulator | `hdc` |
| **注入** | JDWP + payload dex(`Injector`) | DYLD constructor(模拟器)/ 链接 framework(真机) | 待定 |
| **输入合成** | `adb input`(`InputBackend`) | 私有 CoreSimulator HID | `hdc input` |

HTTP 传输层(`RuntimeClient`)**已经是平台中立的**——任何讲该协议的平台 agent
都能原样使用它;它不需要抽象。

**预留 = 只立接口,不建空 stub(YAGNI)。** 引入一个 `Platform` SPI,打包
`DeviceController`、`Injector`、`InputBackend`;把当前 Android 代码放到
`AndroidPlatform` 后面;让 CLI 按 `--target` 选择平台(默认 `android`)。**不要**
为不存在的平台建占位模块或"不支持"stub——立接口,而非 stub。

注意这种不对称:只有 **agent**(进程内代码)才是真正平台特定的,它有各自的逐平台
构建(AAR / framework / HAP)。**CLI** 是 host 侧的,保持单模块;它的三个平台缝
作为*源码包*(`dev.reticle.cli.platform.android`)存在,不是独立模块。

## CLI 是薄客户端:派生逻辑归 agent

一个澄清后的边界(此前是模糊的)。host CLI **绝不**应持有 UI 形态的算法。
捕获派生出的各类视图在 **agent 内、设备上**计算,作为成品 JSON 返回;CLI 接收
成品,只做协议 I/O(HTTP、JSON、参数解析、fork `adb`/`simctl`/`hdc`)。

| 算法 | 归属 | 原因 |
| --- | --- | --- |
| `SemanticTree.build`、`CompactObservation.from`、选择器解析 | **agent**(设备上) | 都是对 snapshot 的纯函数;agent 捕获一次,一趟派生出所有视图。CLI 今天在本地重算只是为了单次捕获的一致性——把它收进 agent 反而让一致性*更*自然,而非更差。 |
| `PortMap.derivePort` | **两端各持一份,按 spec** | 鸡生蛋:CLI 需要在能连上 agent *之前*就知道设备端口,所以无法向 agent 索取。它是一条协议规则(对 `applicationId` 做稳定哈希),两端各自实现得一致。归 `reticle-protocol`,不归共享代码。 |

对语言选择的影响:一旦派生逻辑归 agent,CLI 对 `reticle-core` 的依赖就收缩到
**仅数据模型**——而模型本来就不跨平台共享(每种语言各有一份,由 schema 对齐;
见下文)。所以薄客户端 CLI 是**语言无关的**:Kotlin/JVM、Swift、Go、Rust 都可行,
因为 CLI 只是讲协议、调设备工具。跨平台契约是协议,永远不是共享代码。

这意味着:**让 CLI 干净的,是派生下沉和薄客户端形态——不是实现语言。** 因此用
另一种语言重写 CLI 是可选偏好,而非架构必需。JVM 对 host 工具是个不错的默认:
成熟的跨 OS 分发、构建不需要 macOS(CI 是 Linux)、而且今天它还能和 Android agent
免费共享 `reticle-core`。下文的方向(Swift host + Kotlin Android helper)是既定的
长期形态;在它被执行之前,host 保持 Kotlin/JVM。

## 方向:Swift host + 逐平台 helper(已选定,尚未构建)

既定方向:把 **host 程序**(CLI + daemon + Web 面板——它们是同一个进程
`reticle serve`,不是独立组件)统一到 **Swift**,而每个平台的设备脏活保留在最适合
该平台的语言里,经一个进程边界被调用。

为什么是这种形态,而不是把一切都用 Swift 重写:

- **JDWP 注入无法下沉到 agent。** JDWP 注入的全部意义,就是把 agent 弄进一个
  *还没有它*的进程——agent 是注入的*结果*,不是前提。所以那 ~669 行 JDWP codec
  在本质上是 host 侧的,也在本质上是 Android 特有的。
- **Android 的脏活在 JVM 里最自然**(JDWP、dex、`d8`)。用 Swift 重写它是任何
  重写里风险最高的一块(它 git 历史里每个修复都是一个来之不易的 ART/dexopt/GC
  边界条件)。
- 所以:把**整个当前 `AndroidPlatform`**(adb + injector + JDWP + input)保留为
  Kotlin 的 **`reticle-android-helper`**,让 Swift host 去调用它。现有的
  `Platform` SPI 原样平移到一个*进程边界*,而非被重写。

```
Swift host(CLI + daemon + Web)
├─ 通用核心:args / HTTP / JSON / 事件总线 / 代理 / Web 面板
└─ PlatformClient(Swift 接口)
   ├─ AndroidHelperClient → 与 `reticle-android-helper`(Kotlin:今天的 AndroidPlatform)通信
   ├─ (future) iOS      → 在 Swift host 内原生做(simctl / DYLD —— 同生态,无需 helper)
   └─ (future) harmony  → hdc / helper 待定
```

注意这种不对称:**仅当某平台的脏活处于非-host 生态时,才有 helper。** Android
(JVM)需要一个;iOS 不需要(simctl/DYLD 本就是 Swift/macOS host 的原生生态)。
不要把"helper"过度推广到每个平台。

诚实的代价(这不是免费的,它用 IPC 复杂度换取重写风险):

- **仍残留一个完整的 Kotlin/JVM helper。** "全 Android 经 helper"意味着该 helper
  就是整个当前 Android host 层(~1137 行),需要 JVM 或它自己的 native-image。
  JVM 依赖没有被消除——而是被收拢进一个隔离的、语言归属正当的可执行体。
- **每次 Android 调用都变成跨进程。** `forward`/`screencap`/`input`/`logcat` 都是
  高频调用;因此该 helper 必须是一个**长生命周期 RPC 服务**,而非每次 fork。它的
  请求/响应契约归 `reticle-protocol`,与 wire 协议并列。
- **两个长生命周期进程。** Swift daemon 与 Kotlin Android helper 都常驻;host
  编排两者。roadmap 必须把它们区分清楚(Swift daemon 不是 Kotlin helper),以免
  陷入"两个 daemon"的混乱。

风险姿态:这**彻底消除了 JDWP 重写风险**(Android 代码原样保留),并把"重写最难的
代码"转化为"设计一个好的 host↔helper IPC 契约 + 管理两个常驻进程"——是真实工作,
但属于低风险、标准模式的工作。执行采取**spike 优先**:先证实 host↔helper RPC,
再把通用核心移植到 Swift。

### spike 结果(2026-06-26):RPC 边界已验证

最高风险点——Swift host 能否可靠地跨进程边界驱动 Kotlin helper——已**端到端验证**。
当前已存在的:

- **Kotlin helper**——一个 `reticle helper` 子命令(`reticle-cli/.../Helper.kt`):
  长生命周期的 JSONL stdio RPC 循环(stdin 一行一个请求,stdout 一行一个响应;
  stdout 只走协议,诊断走 stderr)。方法:`ping`、`listDevices`、`inject`、
  `uiReport`——原样复用现有 `Platform` SPI 与 `RuntimeClient`(helper *就是*今天的
  Android host 层,藏在 RPC 接缝后面)。它是常驻循环,不是 fork-per-call,且坏的/
  未知的请求返回结构化错误而不会掀翻循环。
- **Swift spike**——`spikes/swift-host/`(SwiftPM;在 Gradle 构建之外)。它 spawn
  helper、经 JSONL 驱动它,并(针对一台真机)验证:`ping` 往返、`listDevices`
  跨边界打到真实 `adb`、未知方法浮现为结构化错误、helper 在该错误后**仍存活**、
  以及——带 `--package` 参数时——一次真实的 `inject` + `uiReport` 被送过边界,
  helper 即使在 inject 失败时也存活。结果:PASS。

所以这个边界不再是一个风险假设——它能工作,包括高价值的 `inject`/`uiReport` 调用
(Swift host 发起它们,helper 执行并返回结构化结果或结构化错误;常驻 helper 在失败后
存活)。两点值得带入后续:

- **helper 的 payload-dex 解析是相对 cwd 的。** 当 host 从别处 spawn 它时,要设置
  工作目录或传 `RETICLE_PAYLOAD_DEX`——否则 `inject` 会以"payload dex not found"
  失败。RPC 契约应当显式给出 payload 位置,而不是依赖 cwd。
- **在这台 OEM 测试真机上,注入后 runtime 没起来**——注入完成但 `awaitRuntime`
  超时,*与 CLI 自带的 `app inject` 表现完全一致*。所以这是该 ROM 的设备侧
  JDWP/breakpoint 怪癖,与 Swift 边界正交(helper 逐字复现了 CLI 的行为,这正是
  我们想要的正确性信号)。验证一次*成功*的端到端 inject 更适合在模拟器上做,且不是
  本 spike 结论的阻塞项。

**仍留待执行的:** 把 helper 的 RPC 契约形式化进 `reticle-protocol`(含显式 payload
位置);两个常驻进程(Swift daemon + Kotlin helper)的监管;以及 helper 的分发
(JVM jar vs 它自己的 native-image)。这条线排期时的下一步,是在这个已验证的接缝
后面把通用核心移植到 Swift——而不是重写 JDWP。

## 协议 spec:JSON Schema 是权威,Kotlin 手写 + 校验

`reticle-protocol/` 存放 **JSON Schema(2020-12)** 文件外加 golden fixtures,作为
wire 契约唯一的、语言中立的事实来源。

- `reticle-core` 里的 Kotlin 类型保持**手写**(保留其文档注释,以及像
  `MetadataValue` 这类密封层级的 kotlinx-serialization 配置——codegen 处理得很糟),
  并由一个 **CI 契约测试**校验它产出的 JSON 是否符合 schema + fixtures。
- 未来的绿地平台(Swift / ArkTS)可以从同一份 schema **codegen** 出自己的模型。
  "生成 vs 手写"是各平台自己的选择;schema 是大家共享的契约。

## 目标模块布局

`reticle-agent/` 是一个**分组目录,不是构建单元**——它绝不能含自己的
`build.gradle`。Gradle 里只 `include` 了 `:reticle-agent:android`;未来的 `ios/`
(SwiftPM)与 `harmony/`(hvigor)兄弟目录,按设计对 Gradle 不可见。(嵌套会让
Gradle 叶子项目名变成 `android`,所以该模块必须显式设置 `archivesName`,否则它的
AAR 会被命名为 `android-…`。)

```
reticle/  (polyglot monorepo — 一个 host 二进制 + 一份协议 spec)
├─ reticle-protocol/      # JSON Schema(权威)+ golden fixtures + 契约测试  ← 脊柱
├─ reticle-core/          # Kotlin 类型:手写,在 CI 中对 schema 校验
├─ reticle-agent/         # 仅分组目录(此处无 build.gradle)
│   ├─ android/           # Gradle 模块 :reticle-agent:android → reticle-agent-android.aar
│   ├─ (future) ios/      # SwiftPM 包 —— 对 Gradle 不可见
│   └─ (future) harmony/  # hvigor 模块 —— 对 Gradle 不可见
├─ reticle-cli/           # 一次性命令 + Platform SPI(源码包)
│   └─ src/.../platform/android/  # AndroidPlatform: Adb / JDWP / InputBackend
├─ reticle-daemon/        # 新增:`reticle serve` —— 持有代理、聚合 trace、推送事件
│   ├─ proxy/             #   纯 host MITM 引擎 + CA 签发 + 设备自动配代理
│   └─ web/               #   前端面板:流量视图 + 操作路径/截图时间线
└─ sample-app/            # 链接 :reticle-agent:android 的演示应用
```

---

# daemon 与事件总线(优先设计)

决定:**先把 daemon 和事件总线设计好;代理引擎是个可插拔后端,晚点再选。** 本节
所有内容都刻意与引擎无关。

## 为什么需要一个 daemon

Reticle 今天是**一次性 CLI**:每条命令做 forward → probe → act → 退出。但新增
需求里有三项天然是*长生命周期、流式*的:

- 抓包代理是一个常驻 MITM 监听器;
- 操作路径是跨多条命令累积的时间有序序列;
- Web 面板需要某个东西把实时更新推给浏览器。

所以我们引入一个新的运行模式,由它持有所有长生命周期状态:

```
reticle serve [--target android] [--session <name>]
   # 长生命周期 daemon:跑代理、聚合事件时间线、
   # 在 localhost 上提供 Web 面板、暴露控制 + 事件 API
```

现有的一次性命令照常独立工作。当 daemon 在运行时,它们额外把自己的结果
**作为事件发布**给它,于是 Web 时间线就把 tap、snapshot、截图与网络流量一并收录。

## 事件总线——核心抽象(与引擎解耦)

一切可观测的东西都成为单一进程内总线上的一个带类型的事件。源(source)发布;
汇(sink)消费。代理只是*其中一个源*——这正是引擎选择得以推迟的原因。

### 事件信封(对每个源统一)

```jsonc
{
  "id": "evt_01J...",          // 单调、可排序
  "ts": 1719400000000,         // epoch 毫秒(由 daemon 打戳,不是脚本)
  "session": "sess_abc",       // 把 设备 + 应用 + 时间窗 绑在一起
  "target": "android:emulator-5554",
  "source": "proxy | action | ui | runtime | log",
  "type": "network.response",  // 见下方分类法
  "payload": { ... },          // 类型特定,在 reticle-protocol 里定 schema
  "refs": { "screenshot": "sess_abc/0007-after.png" }  // 大块数据按路径引用,不内联
}
```

### 事件分类法

| 源 | 类型 | Payload(在 `reticle-protocol` 里定 schema) |
| --- | --- | --- |
| `proxy` | `network.request`、`network.response`、`network.error` | method、url、status、headers、timing、body 引用 |
| `action` | `action.dispatched` | 手势(tap/swipe/drag/type)、选择器、解析出的坐标点、操作前/后的节点引用 |
| `ui` | `ui.snapshot`、`ui.screenshot` | 捕获元数据 + 指向磁盘产物的 `ref` |
| `runtime` | `runtime.lifecycle` | agent 启动 / 注入 / 端口绑定 / 健康变化 |
| `log` | `log` | 应用自行写入的桥接日志(现有的 `/logs`) |

**规范化的 `NetworkEvent`** 是关键解耦点:无论哪种引擎产出它(见下文),都适配到
这一个类型。总线永远看不到引擎内部。

### 缓冲、持久化、保留

- 每个 session 一个内存**有界环形缓冲**(默认约 500 个事件,可配置)。大块
  body/截图溢写到 session 目录,经 `refs` 引用,绝不内联进事件。
- 可选的 **JSONL 持久化**写到 `~/.reticle/sessions/<session>/events.jsonl`,
  这样一次运行可以事后回放进面板——一个持久化的 session 目录把"逐操作的 trace
  目录"泛化成了完整时间线。

### Session

一个 **session** 把 设备 + 应用 + 时间窗 绑成一条时间线,于是面板能把"本次运行:
这些网络调用 + 这些 tap + 这些截图"作为一个连贯视图展示。一次性命令若发现 daemon
在跑(通过 `~/.reticle/` 下的 pidfile + 端口发现),就挂到当前 session 上;否则像
今天一样无状态运行。

## Web 推送传输(轻依赖)

与"手写 HTTP server"的理念一致(不引入重型框架):

- **控制 + 历史**:在 daemon 的 localhost 端口上用普通 HTTP REST
  (`GET /sessions`、`GET /sessions/{id}/events?since=`、`POST /act`……)。
- **实时流**:**Server-Sent Events**(`GET /events/stream`)——单向 server→浏览器,
  在现有 socket server 上实现起来很简单,足以支撑实时时间线。仅当面板日后需要丰富的
  双向控制时才保留 WebSocket;起步用 SSE + REST。

## 代理后端藏在接口后面(引擎推迟)

引擎就是一个发出规范化 `network.*` 事件的 `EventSource`:

```
interface ProxyBackend {
  fun start(listenPort: Int, ca: CaMaterial): Flow<NetworkEvent>
  fun stop()
}
```

以下任何一种都能在日后实现它,而不触碰总线或面板:内嵌 JVM 引擎
(netty/LittleProxy 类)、受管的 `whistle` sidecar、或外部 `mitmproxy`。
**之所以能推迟决定,正是因为事件总线让它可插拔。** 现在设计总线和时间线;代理阶段
开始时再选引擎。

## 抓包代理——诚实的能力边界

决定:**只做纯 host 代理(L1)。agent 绝不动应用的信任链或 pinning——守住无 hook
红线。** 这刻意与 whistle 的天花板对齐,且必须如实记录:

- **HTTP 明文**——随便抓。
- **HTTPS**——需要设备/应用信任我们的代理 CA。在 Android 7+ 上,应用默认**不**
  信任用户 CA:对**可调试**应用可行(通过其 `network_security_config`,或应用显式
  opt-in);系统级 CA 信任需要 **root**(超出范围)。通过
  `adb settings put global http_proxy` 配置设备代理本身是 **host** 动作(不是
  hook),在范围内。
- **证书锁定(pinning)**——击穿代理。whistle 也破不了它;我们如实报告这个限制,
  而不是越过无 hook 红线去绕过它。

(一个"L2 agent 辅助"模式——在可调试应用里运行时注入 CA 信任 / 中和 pinning——
经考虑后被**否决**,以保住无 hook 保证。记录于此,免得这个权衡被悄悄重提。)

---

# WebView / DOM 支持

决定:**照搬 Compose 桥——一个默认开启、只读的 DOM 桥,其节点融进唯一的统一树。**

## 它在结构上和 Compose 是同一个问题

捕获已经在处理一棵藏在原生 `View` 内部的外来树:`SnapshotCapture.captureView()`
遍历原生子节点,然后调用 `ComposeSemanticsBridge.captureInto()` 把 Compose
**semantics** 树合并进同一个 `nodes` map,打上 `NodeKind.composeSemantics` 标签。

一个 `android.webkit.WebView` 是同样的形态:今天它是一个不透明的叶子 `view` 节点;
内部挂着一棵 Reticle 看不见的 **DOM 树**。修法是加第二座桥,契约完全一致,而非新
机制:

```kotlin
// 在 captureView() 中,紧挨着 Compose 合并那行:
val webChildren = WebViewBridge.captureInto(view, parentRef = ref, nodes = nodes) { makeRef() }
childRefs.addAll(webChildren)
```

新增一个 `NodeKind.domNode`;DOM 元素作为 WebView 节点的子节点融入。因为
`ui compact` / `ui tree` / `SelectorResolver` / `act tap` 全都作用于 `Node`,
并不关心节点来自 View、Compose 还是 DOM,**它们原样复用**——这是扁平 ref→Node
模型的红利。

## Compose 没有、而它有的两件事

1. **异步 + 跨边界读取。** Compose semantics 在主线程上由反射同步读取。DOM 只能
   通过 `WebView.evaluateJavascript(js) { result -> ... }` 抵达,其结果是
   **异步**的。`captureLocked()` 是同步的(经 `runOnMainSync` 的一个
   `CountDownLatch`),因此该桥注入一段只读的 DOM 遍历脚本,并以一个有界超时把
   JSON 结果 latch 回来。代价真实但有界。
2. **坐标换算。** DOM 报告的是**相对 WebView 视口的 CSS 像素**;整棵树用的是
   **屏幕物理像素**。每个 DOM 矩形都必须折算到屏幕坐标系:
   `screen = webview.locationOnScreen + domRect × density − scrollOffset`。这是
   最易出错的部分(折算错了会让 `act tap` 点偏),所以协议契约把它钉死:
   **一个 `domNode.frame` 已经处于屏幕坐标系**,正如 Compose 的 `boundsInScreen`。

## 能力分级(诚实降级,如同 `ui screenshot`)

| 分级 | 机制 | 产出 | 前提 |
| --- | --- | --- | --- |
| **L0**(始终可用) | 当前行为 | WebView 作为不透明叶子节点:有 frame,可整体点击 | 无 |
| **L1**(DOM 结构) | 注入只读 DOM 遍历 JS,折算坐标 | DOM 元素树:tag / id / class / text / 屏幕矩形;按 CSS 选择器或文本定位;可点击 | WebView 启用了 JS |
| **L2**(语义) | JS 读取 ARIA role / 可访问名 | role + 可访问名,与语义树对齐 | 启用了 JS |

L0 无需任何工作。L1 是主体。L2 是增量。该 DOM 桥**默认开启但只读**——它注入一段
不改变页面状态的遍历脚本。当 JS 被禁用或注入失败时,Reticle **不**伪造 DOM:它
如实把该 WebView 留作不透明的 L0 叶子,这与 Compose 桥对非 `AndroidComposeView`
宿主所遵循的诚实规则一致。

## 范围

- **范围内:** 应用内嵌的 `android.webkit.WebView`(混合应用场景)。
- **范围外:** Chrome Custom Tabs / Trusted Web Activity——它们跑在一个*独立*的
  (Chrome)进程里,进程内 agent 够不着。明说出来,免得被误当成缺口。
- **跨平台复用:** `domNode` 节点类型与"DOM 矩形折算到屏幕坐标系"这条契约进
  `reticle-protocol`,作为又一个平台中立节点类型——同样的"注入 JS、读 DOM"做法
  直接映射到 iOS `WKWebView` 和鸿蒙 Web 组件。这与上文"协议即脊柱"原则一脉相承。

---

# 路线图阶段

Android 优先并做完整;其余一切藏在 spec + SPI 后面预留。

### Phase 0 —— 薄预留(现在做,近乎零成本)
- **现在改名**:把 `:reticle-agent` → `:reticle-agent:android`(分组目录,无根
  `build.gradle`;设置 `archivesName` 让 AAR 保持 `reticle-agent-android.aar`)。
  更新这一改动触及的耦合点——`settings.gradle.kts`、`ci.yml`、`release.yml`
  (含 `reticle-agent.aar` / `…-payload.jar` 资产名 + 启动器)、`bin/reticle`、
  `validate_plugin.py`、`sample-app` 依赖。
- 新增 `reticle-protocol/`,放**权威 JSON Schema(2020-12)** + golden fixtures;
  接上一个 CI 契约测试,校验 `reticle-core` 产出的 JSON 符合它。Kotlin 类型保持
  手写。
- 引入 `Platform` SPI;把 `Adb` / `Injector` / `InputBackend` 移入
  `dev.reticle.cli.platform.android` 并置于其后。**不建 iOS/鸿蒙 stub。**
- **设计 daemon + 事件总线**(本文档)——模型、信封、session、SSE/REST 表面——
  与任何代理引擎解耦。

### Phase 1 —— Android 功能完善(纯加分,无新架构)
- **活对象检查** + **布局诊断**,泛化 `mutate` 已有的反射——运行时类元数据、一个
  `ui audit`、以及经由 Java/Kotlin 反射的约束检查。
- **诚实的天花板,如实记录:** 类/字段/属性元数据 + *可达*对象图(自 view 树、
  单例、静态根)。**不是**堆实例枚举,**也不是**任意地址读取——这是结构性限制,
  而非 Android 的限制。要拿完整堆,诚实的路径是 host 侧
  `adb shell am dumpheap`(可调试应用,无需 root)离线分析。
- **操作 trace**(每个 `act` 存操作前/后的 snapshot + 截图 + diff)——为 Phase 3
  的时间线供数据。
- **WebView / DOM 支持**——`WebViewBridge` 照搬 Compose 桥,L0→L1→L2 分级,DOM
  节点融进统一树(`NodeKind.domNode`)。见上文 WebView 一节。L0 今天就免费;
  L1(只读 DOM 遍历 + 坐标折算)是真正的工作量。
- **薄客户端下沉**——把 `SemanticTree.build` / `CompactObservation.from` /
  选择器解析移到 agent,让 CLI 消费成品 JSON(agent 已经暴露了 `/semantics` 与
  `/compact`;让 `ui report` 去拉取而非重算)。`PortMap` 作为协议规则在两端各留
  一份。这是语言话题牵出的、真正"让 CLI 干净"的工作——它让 CLI 语言无关,并收紧
  单次捕获的一致性。见上文"CLI 是薄客户端"。

### Phase 2 —— 代理 + daemon
- 实现 `reticle serve`、事件总线、session 模型、SSE/REST 表面。
- 把纯 host 代理实现为一个 `ProxyBackend`(此时选定引擎),含设备自动配代理与 CA
  签发。边界遵循上文。

### Phase 3 —— Web 面板
- 统一的 localhost 面板:**流量视图**(whistle 式)+ **操作路径 / 截图时间线**,
  两者都经 SSE 由事件总线供数据。两个视图,一个 UI。

### Phase 4 —— 多平台
- iOS / 鸿蒙 agent 在各自的构建系统里,遵循协议 spec。host 与面板复用;每个新平台
  提供它的三个缝——生态匹配时在 host 内原生做(iOS:Swift host 里的 simctl/DYLD),
  不匹配时做成 helper(Android:Kotlin `reticle-android-helper`)。见"方向:
  Swift host + 逐平台 helper"。

## 诚实边界(贯穿每份文档与 skill)

- **无 root、无重打包、无字节码 hook** 始终是核心红线。
- **对象/堆检查**:仅可反射的元数据 + 可达图;堆枚举超出范围(用 `am dumpheap`
  离线做)。
- **网络捕获**:host MITM,等同 whistle;HTTPS 需要 CA 信任;pinning 不绕过。
- **WebView / DOM**:经注入的遍历 JS 读取只读 DOM;需要 WebView 启用 JS;不可用
  时如实降级为不透明叶子。Custom Tabs / TWA(独立进程)超出范围。
- **注入**:把已链接的 agent 或经 JDWP 注入到*可调试*应用;不可调试的 release
  构建与任意真机应用超出范围(那是我们不进入的 Frida/root 地界)。iOS 真机到来时,
  将要求应用在构建期链接 framework。

## 已搁置 / 待定问题

显式搁置——尚未决定,记录下来以免被遗忘或被误当成已定。触发条件到来时再重启。

- **鸿蒙可行性侦察。** 平台缝表里的鸿蒙行(`hdc`、注入、输入)是**零验证**的
  纸面占位——`hdc` 是否有 `forward` / `input` / 某种调试注入通道的等价物尚未核实。
  搁置。*触发条件:* 在鸿蒙进入任何已承诺的计划之前(即 Phase 4 触及它之前),花
  一小段时间做侦察以确认这些缝存在;在那之前它保持 `est.`/`TBD` 标注,不作承诺。
- **Web 面板反向驱动。** Phase 3 面板目前是**只展示**的(流量 + 操作路径 + 截图,
  经单向 SSE)。浏览器能否*驱动*应用(在面板里点一下 → 触发 `act tap`)是待定的。
  *触发条件:* 若需要反向驱动,它会逼出一个双向传输(在当前 SSE 之上加 WebSocket)
  外加一大块前端交互工作——在敲定 Phase 3 传输之前决定,免得 SSE-vs-WebSocket
  返工。
- **host 语言:Swift host + Kotlin Android helper(已选定,未排期)。** 长期形态
  已定(见"方向:Swift host + 逐平台 helper"):host 程序(CLI + daemon + Web)转
  Swift,整个当前 Android 层保留为 Kotlin,做成一个长生命周期 `reticle-android-
  helper`,经一个 RPC 契约被调用。JDWP *不*重写。这是方向,尚未排期——在它被执行
  之前 host 保持 Kotlin/JVM,且执行采取 **spike 优先**(先证实 host↔helper RPC
  再移植核心)。*待定子问题:* helper 的 RPC 契约(归 `reticle-protocol`);Kotlin
  helper 以 JVM jar 还是自己的 GraalVM native-image 分发;以及 Swift daemon 与
  Kotlin helper(两个常驻进程)如何被监管。*排期触发条件:* 当 Swift Web 服务 /
  daemon 工作启动时,因为那与 host 是同一进程,会逼出语言决定。
