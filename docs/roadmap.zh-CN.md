# Reticle 路线图与多平台架构

[English](roadmap.md) | **简体中文**

状态:路线图与当前状态文档(2026-07-23 更新,对应 0.9.3——Loom 抓包引擎、流量规则、
flow replay)。记录了将 Reticle 从单
平台 Android CLI 演进为多平台运行时 harness(集成抓包代理与实时 Web 面板)的既定
方向。`docs/architecture.md` 描述当前实现的操作细节。最后一节**下一步提案:证据
工作流 + 安全证据线**记录了一组尚未构建、建在 Phase 1–3 已落地原语之上的提案。

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
9 个端点:`/report` `/snapshot` `/semantics` `/compact` `/screenshot` `/mutate`
`/clipboard` `/runtime` `/logs`)。未来的 iOS(Swift)或鸿蒙(ArkTS/C++)agent **不需要共享 Kotlin
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
| `SemanticTree.build`、`CompactObservation.from`、选择器解析 | **agent**(设备上) | 都是对 snapshot 的纯函数;当前 agent 捕获一次并派生 report 视图。`ui report` 已经消费这个 bundle;选择器解析是剩余的下沉工作。 |
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
  *还没有它*的进程——agent 是注入的*结果*,不是前提。所以那 ~680 行 JDWP codec
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

### 现状(2026-06-26):一个可用的 Swift host CLI 已存在

这个方向已越过 spike——存在一个**真正的 Swift host CLI**,在真机上端到端地经 Kotlin
helper 驱动 Android。当前已存在的:

- **Kotlin helper**——一个 `reticle helper` 子命令(`reticle-helper/.../Helper.kt`):
  长生命周期的 JSONL stdio RPC 循环(stdin 一行一个请求,stdout 一行一个响应;
  stdout 只走协议,诊断走 stderr)。方法(截至 0.7.0):`ping`、`listDevices`、
  `status`、`inject`、`launch`、`uiReport`、`act`、`mutate`、`logs`、`logcat`、
  `screenshot`、`render`(helper 侧 tree/compact/node/regions/outline 渲染),以及
  `proxyStatus` / `proxySet` / `proxyClear` / `proxyInstallCa`——原样复用现有
  `Platform` SPI 与 `RuntimeClient`(helper *就是*今天的 Android host 层,藏在 RPC
  接缝后面)。常驻循环,不是 fork-per-call;
  坏的/未知请求返回结构化错误而不会掀翻循环。`inject` 接受显式 `payloadDex`;
  `uiReport` 在设备侧派生树并返回成品 `snapshot`/`semantics`/`compact` JSON。
- **RPC 契约**——形式化在 `reticle-protocol/helper-rpc.md`(信封、方法清单、显式
  payload 规则、inject 等待 runtime 起来的规则)。
- **Swift host CLI**——`reticle-host/`(SwiftPM;在 Gradle 构建之外)。是与 Kotlin
  CLI 命令对齐的真正 CLI:`HelperClient`(常驻 JSONL RPC,带 id 关联)+ `doctor` /
  `devices` / `status` / `app launch|inject` / `act` / `mutate` / `debug` /
  `ui report|screenshot|tree|compact|node|regions` / `version`。它不持有任何设备
  代码——每条命令都是一次 RPC 调用。`ui report` 把 helper 返回的树直接写到
  `snapshot.json` / `semantics.json` / `compact.json`(薄客户端边界的实践——host
  从不重新派生)。(最初的一次性 spike 已随真正的 host 落地而移除。)

真机上已验证:`doctor`/`devices`/`status` 返回真实设备数据;**对链接版示例 app 跑
`ui report` 得到 healthy runtime 并写出真实的 24KB `snapshot.json` + semantics +
compact**(nodes=15、compact=8、semantic=10)。所以完整价值路径 Swift → helper →
Android 是通的。

一个设备侧注意点(与 host 正交):在这台 OEM 测试 ROM 上,`inject` 完成但之后
runtime 起不来——*与 CLI 自带的 `app inject` 表现完全一致*,所以是该 ROM 的
JDWP/breakpoint 怪癖,不是 host 或边界问题。因此 `ui report` 是用**链接版**示例 app
(agent AAR,无需 JDWP)验证的;一次成功的端到端 *inject* 最好在模拟器上确认。

**当前阶段"Swift host"的含义:** host *CLI* 已完成,且现已与 Kotlin CLI 的一次性
命令面**功能对齐**。除 doctor/devices/status/inject/ui report 外,Swift host 还能
驱动 `launch`、`act`(tap/swipe/drag/type,含选择器与 `--region` 解析)、`mutate`、
`debug logs`/`logcat`、`ui screenshot`(PNG 经 base64)、以及本地
`ui tree`/`compact`/`node`/`regions`(由 helper 渲染——派生留在 Kotlin)。全部已对
链接版示例 app 在真机上验证(选择器 tap 解析成坐标、mutate 生效、读到日志、写出
1080×2412 PNG、`--region "《隐私政策》"` 解析到精确坐标)。

`reticle serve` 的 daemon、事件总线、Web 面板、HTTP/HTTPS 代理、MITM lane 与
session 级网络 mock 已落在 Swift host。流式代理转发与类型化 `network.*` schema 也已
落地(见下方 Phase 2)。**完整 Swift host 仍待办的:** 如果后续明确选择则加入面板反向
驱动,以及一个流式 `logs --follow`。JDWP 永不重写。

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
├─ reticle-helper/        # Kotlin Android host 层 → 无 JDK 原生 reticle-helper(RPC server)
│   └─ src/.../platform/android/  # AndroidPlatform: Adb / JDWP / InputBackend
├─ reticle-host/          # Swift host CLI + `reticle serve` daemon、面板、proxy/MITM、mock
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

## 抓包引擎藏在接口后面(接口已落地,引擎已选定:Loom)

lane 独立在 `ReticleNetworkLane` target 里,只通过一个发出规范化 `network.*`
事件的 sink 接触 host(host 最终是 Swift,不是当初设想的 Kotlin):

```swift
public protocol NetworkEventSink: AnyObject, Sendable {
    var sessionDirectory: URL { get }
    func emit(_ request: EventPostRequest)   // 尽力而为;抓包永不让请求失败
}
```

引擎已尘埃落定:自研的 in-tree SwiftNIO 代理已删除,Reticle 以 SPM 库形式消费
**[Loom](https://github.com/KQAR/Loom)** 的 `ProxyEngine`(`LoomProxyCore` /
`LoomSharedModels`,pin 到 release tag)。`LoomCaptureLane` 以 loopback +
`persistFlows: false` 跑引擎,订阅 `flowStream()`,把交换经 sink 重新发布。接口依然
有价值——换引擎(受管的 `whistle` sidecar、外部 `mitmproxy`)只需改这一个 target,
由 `scripts/e2e-proxy.sh` 端到端守护——但"用哪个引擎"已不再是开放问题。

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
- **操作 trace**——第一版证据包已通过 `act --trace-output` 落地:`trace.json`
  记录 gesture、selector、解析后的 point/source/ref 与紧凑 snapshot diff,前后
  snapshot 和截图放在同一 action 目录下。`reticle serve` 已能把这些 trace ingest
  进 session 事件总线并在面板时间线展示。
- **WebView / DOM 支持**——`WebViewBridge` 照搬 Compose 桥,L0→L1→L2 分级,DOM
  节点融进统一树(`NodeKind.domNode`)。见上文 WebView 一节。L1 的只读 DOM 遍历 +
  坐标折算已在应用内嵌 `android.webkit.WebView` 上落地;剩余工作是 L2 语义增强,
  以及为更多边界情况补 fixture 覆盖。
- **薄客户端下沉**——`ui report` 现在消费 agent 的单次捕获 `/report` bundle,
  因此当前 agent 的报告产物里 `SemanticTree.build` / `CompactObservation.from`
  已经在 app 进程内完成。剩余工作:把 action 的选择器解析也移到 agent,让 CLI 消费成品 target JSON。`PortMap` 作为协议
  规则在两端各留一份。这是语言话题牵出的、真正"让 CLI 干净"的工作——它让 CLI
  语言无关,并收紧单次捕获的一致性。见上文"CLI 是薄客户端"。
- **键盘状态 + 遮挡标记(已落地,0.9.1)**——系统键盘(IME)是另一个进程的窗口,
  从不出现在节点树里,被盖住的控件看起来仍然 tappable——这正是实测中登录流卡死
  的根因。快照现在携带 `screen.keyboard`(visible + frame;Android 用 window
  insets 进程内探测,iOS 用键盘通知流),agent 提供 `GET /keyboard` 与
  `POST /keyboard/hide`,`act hide-keyboard` 在两端都能确定性收起键盘。遮挡
  标记是**通用**的而非键盘专属:compact 条目的落点被更高 z 序窗口盖住标
  `occluded-by:<窗口ref>`,被键盘盖住标 `occluded-by:keyboard`。两端 sample
  各带一个登录键盘陷阱场景,iOS e2e 全链路驱动验证。
- **面向 agent 的定位 + 批处理(已落地,0.6.5–0.7.0)**——`ui outline --live` 给
  可见目标编号并缓存短生命周期 `@N` 别名;`act --alias` 点击它们;选择器未命中时
  从当前快照报同类候选。`act batch` 从 JSON 文件顺序跑确定性 flow,首个失败即停。
  `Reticle.registerProbe(testId, metadata)` 让已链接应用为没有合适具体 view 的位置
  (canvas 区域、离屏状态)注册一个可寻址的合成节点。它们在保住确定性 selector 骨干
  的同时降低 agent 驱动定位的成本——**不是**截图/自然语言探索路径。

### Phase 2 —— 抓包引擎 + daemon
- 已完成:`reticle serve`、事件存储、session 模型、SSE/REST 表面、action trace
  ingestion、设备自动配代理、CA 签发、可选 HTTPS MITM、以及 session 级流量规则。
- 已完成(引擎):自研的 in-tree SwiftNIO 代理已删除;抓包现以 SPM 库形式跑 **Loom**
  的 `ProxyEngine`(`LoomProxyCore` / `LoomSharedModels`)。传输、MITM、CA、上游转发
  都是 Loom 的;Reticle 以 loopback + `persistFlows: false` 跑它、自己存储、把 flow
  归一化成 `network.*` 事件(见 architecture.md 的 network-lane 段)。
- 已完成(规则):原本只做 mock 的存储已泛化为通用**流量规则**存储——route
  `mock` / `block` / `mapRemote` / `passthrough` 加修饰符(`delayMs`、请求/响应 header
  rewrite、find/replace substitution),1:1 映射到 Loom 的 `RuleActions`。匹配支持
  `regex`(upsert 校验)、`ANY` method 通配、query `"*"` 存在性谓词。
- 已完成(replay):**flow replay + diff**(`POST /sessions/current/flows/:id/replay`、
  `reticle replay flow`)闭合 Loom 的 capture → modify → replay → diff 环,发出携带响应
  diff(status/body/header 名字增删改)的 `network.replay` 事件。
- 已完成(schema):类型化 `network.*` payload schema
  (`reticle-protocol/schema/network-event-payload.schema.json`)加 request/response/
  error 三个 golden fixture,由 Kotlin 契约测试校验,并用 Swift 字段集测试把发射端
  钉死到同一 schema。
- 下一步:把类型化 schema 覆盖扩展到其余事件族(action / runtime payload),并在出现
  具体用例时为 header/body 增加 matcher 谓词。

### Phase 3 —— Web 面板
- 已完成:localhost 只读证据面板,展示 action trace、截图/产物、network lane 卡片、
  body 预览、MITM/tunnel/rule 模式、以及 rule id / action / value id。
- 已完成(收尾):**网络过滤器**——模式(RULE/ERROR/MITM/TUNNEL)、状态类
  (2xx/3xx/4xx/5xx)、以及对 method/url/host/path/status/rule id 的自由文本搜索,三者
  可组合;一个 **Rule groups** 视图切换,把命中规则的请求按其规则聚合(含命中次数),其余
  按 host 聚合;以及每张网络卡片上的 **copy as rule** 按钮,拼装出可直接运行的
  `reticle rule set` 命令(含指向已捕获响应的 `--body-file`)复制到剪贴板。面板保持
  display-only——只产出命令供用户运行,自身不 POST 规则状态。
- 下一步:仅当下方 deferred 问题被回答(会强制双向传输)时再考虑反向驱动;否则面板边界不变。

### Phase 4 —— 多平台
- iOS / 鸿蒙 agent 在各自的构建系统里,遵循协议 spec。host 与面板复用;每个新平台
  提供它的三个缝——生态匹配时在 host 内原生做(iOS:Swift host 里的 simctl/DYLD),
  不匹配时做成 helper(Android:Kotlin `reticle-android-helper`)。见"方向:
  Swift host + 逐平台 helper"。

# 下一步提案:证据工作流 + 安全证据线

尚未构建。下面全部是**建在已存在原语之上的产品化层**(action trace、截图、网络
事件、节点 rect、session 时间线)——不引入新的捕获机制,不移动核心红线。三条约束
在这里的每一项都原样成立:

1. **证据,不下判定。** 这些工作流只产出更可比的证据与差异量;不新增
   `assert`/`verify` 原语;Reticle 不产出 pass/fail 或风险评级——判定交给 agent 或人。
2. **确定性 selector 仍是骨干。** 不把「自然语言 target / 从截图猜坐标」提升为主
   定位路径。已落地的 `ui outline --live` + `@N` 别名是可接受的便利层;探索式只作
   覆盖率辅助,绝不作验证主路径。
3. **无 root / 无重打包 / 无 hook / 不绕 pinning。** 安全线是**防御侧证据引擎**,
   不是攻击或绕过工具。

## 工作流 A —— 证据工作流产品

每项都把现有原语组装成一个人能直接消费的成品。

- **A1 —— PR 证据机器人(`reticle review`)。** 一层 CI/PR 包装:读 diff → 用确定性
  flow 驱动到改动界面 → 把 action trace + 前后 compact diff + 网络事件 + 截图汇成
  PR 评论。复用 `act batch`、`act --trace-output`、session 时间线、面板的证据排序
  逻辑。只贴证据,判定交给人。*建在 Phase 1 trace 上;CI/GitHub 集成随 Phase 3 落地。*
- **A2 —— 视觉回归(`reticle diff visual`)。** 两个 build(或同 build 前后)间截图
  像素级 diff,可配阈值,出差异区域叠加报告。补结构 diff 的盲区:结构 diff 回答
  「文字/状态变了」,像素 diff 回答「布局/渲染漂了」。阈值是提示,不是 verdict。
  *先出报告(Phase 1),面板卡片随后(Phase 3)。*
- **A3 —— 设计保真度证据(`reticle diff design`)。** 把设计稿组件框与活屏节点 rect
  (`ui report` / `ui regions` / `ui node`)对齐,产出逐区域偏差(位置/尺寸/颜色/
  文案)+ 叠加图。设计数据经现有 Figma 通道取回。**给偏差量,不给字母评级**——评级
  是判定,留给使用方。Reticle 只测「活屏与给定设计框的几何/样式差」,不判断设计
  对不对。*Phase 1 证据;面板 Phase 3。*
- **A4 —— 流程回放产物(`reticle replay gif`)—— 已落地。** 把一段 flow 的逐步截图
  拼成带设备边框的 GIF,供人审与 PR 沟通;步骤字幕取自 trace 的 gesture/selector,
  手势几何(解析出的 tap 点、swipe 轨迹)绘制在 before 帧上。以
  `reticle replay gif <trace-dir>` 交付——纯 host 本地,直接读盘上已有的
  `act --trace-output` 证据包,用 ImageIO/CoreGraphics 渲染,零新依赖。没有截图的
  步骤诚实跳过(stderr 提示),绝不伪造。MP4 变体留待出现具体需要再做。
- **A5 —— 导航/覆盖图(`reticle map`,谨慎定位)。** 由 `ui outline` + action trace
  的界面转移归并出「界面 → 可达路径」图,**定位为覆盖率辅助**(「哪些界面/路径还
  没被 E2E 覆盖」),绝不作自动验证路径。只用于发现,发现后仍走确定性 selector 的
  flow 去验证。*Phase 1 之后;优先级更低。*

## 工作流 B —— 安全证据线(Reticle 自己的范围)

安全是一等方向,但范围必须划精确。在安全语境里 Reticle 是**防御侧证据引擎**:它
观测、驱动、抓取,产出可复核的安全相关证据——它不 hook、不绕 pinning、不注入。

**超出范围(越 no-hook 线——Frida/root 地界):** 证书 pinning **绕过** / 运行时
注入 CA 信任 / 中和 pinning;hook 采集链路或虚拟摄像头/deepfake 注入(PAD/IAD
红队);逆向或破解二进制本身。

**在范围内(都在 observe/drive/capture + 可反射元数据 + 主机代理边界内):**

- **B1 —— 敏感数据流转证据。** 在现有主机代理/MITM 通道上,观测并标注敏感数据如何
  流转,产出证据(不下「有漏洞」判定):明文 HTTP 传输标注;请求/响应体中疑似敏感
  字段(可配模式)的位置标注;HTTPS CONNECT 隧道无法解密时如实标注「opaque,未
  解密」。复用 `network.*` 事件与面板已有的 cookie/authorization 脱敏。pinning 挡住
  时如实报「不可观测」,不越线破解。*Phase 2(代理上的 additive 增强)。*
- **B2 —— 风控流程 E2E 回归 harness(最契合,B 里优先做)。** 用确定性 selector 驱动
  给风控功能本身当回归 harness:驱动活体 / 1:1 人脸上传 / 设备校验 UI 流程,抓取其
  对外部校验/风控服务的调用,并用 session 级 `mock` 模拟不同外部 verdict(可信/
  不可信/降级),让客户端在各分支下的 UI 与后续调用可确定性复现验证。Reticle 只
  *驱动真实流程 + mock 外部返回 + 存证*,不伪造采集内容、不攻击活体(那是红队,不在
  此)。*Phase 2(依赖 mock + 代理)。*
- **B3 —— 客户端安全态势证据(observe-only)。** 产出一份安全相关客户端配置的只读
  快照,全部落在可反射元数据与主机可观测边界内:应用是否 debuggable;用户 CA 信任 /
  network security config 标注;WebView 是否启用 JS、是否有混合内容(based on 现有
  WebView/DOM 桥);以及经类/字段元数据反射可见的组件暴露面(建在 Phase 1 的活对象
  检查 / `ui audit` 之上,以安全视角归纳)。只列可观测事实——不做堆枚举、不做任意
  读、不下「不安全」判定。*Phase 1 的对象/布局诊断落地之后。*

## 建议顺序

先做 **A4 + A1 + A2**——复用现成 trace/截图、近零新机制,直接提升人审与 PR 证据
质量。安全线先做 **B2**——最契合 Reticle 的确定性驱动 + mock 形态,价值最高。
A3 / B1 / B3 随后;A5 优先级最低。

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
- **host 语言:Swift host + Kotlin Android helper —— 已完成(已交付,不再搁置)。**
  选定形态已被执行并在今天交付:host 程序(CLI + daemon + Web)已是 Swift
  (`reticle-host`,SwiftPM),整个当前 Android 层保留为 Kotlin,做成长生命周期
  `reticle-helper` 经 RPC 契约被调用,JDWP *不*重写。`bin/reticle` 默认跑 Swift
  host + native helper;已不再有面向用户的 Kotlin/JVM CLI。三个待定子问题全部解决:
  helper RPC 契约在 `reticle-protocol/helper-rpc.md`;Kotlin helper 以自己的
  **GraalVM native-image** 分发(无 JDK 单文件 `reticle-helper`),不是 JVM jar;
  两个常驻进程经 `reticle serve` helper-broker(0.6.5)监管——它在 daemon 后面常驻
  一个 helper,并把 `--use-daemon` / `RETICLE_USE_DAEMON=1` 的命令 RPC 路由过去。
  见上文"方向:Swift host + 逐平台 helper"与"现状(2026-06-26):一个可用的 Swift
  host CLI 已存在"——此项仅作指针保留,已不再是待定问题。
