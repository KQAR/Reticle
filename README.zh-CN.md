# Reticle

[English](README.md) | **简体中文**

Reticle 帮助 AI 编码 agent 在 **Android 与 iOS** 上构建并验证原生应用界面——它检查
的是**正在运行**的应用本身,而不是源码或一张截图。

Reticle 的职责是*定位并度量*屏幕上的内容:从实时的 view / 无障碍 /
Compose-semantics / SwiftUI 树中解析出稳定的选择器和精确坐标,让 agent 能有把握地
对正确的元素执行操作。一个 CLI、一份 wire 协议、一套命令面:用 `--target ios`
切换平台(默认 `android`)。

`adb`、Espresso、UiAutomator、XCUITest 这类工具能构建、启动或驱动应用。Reticle 补上的是
**运行时 UI 层**:来自正在运行的应用的结构化证据,让 agent 能检查、探查并验证
原生界面的实现。

## 为什么用 Reticle

- **少靠截图猜。** agent 通过原生 view 树、无障碍/语义元数据、截图和日志来检查
  正在运行的应用。
- **少漏 UI 问题。** Reticle 针对实时界面检查布局、命中测试和设计偏差。
- **能精确定位到单个 View 内部。** 协议勾选行、"高亮即链接"的文本、自绘控件,
  常常把多个点击目标塞进同一个节点。Reticle 能把它们拆解到具体短语(见下文)。
- **更快的开发循环。** 紧凑观察(compact observation)和运行时 UI 变更让 agent
  能在下一次构建/运行之前先试小修改。

## 工作原理

Reticle 在应用进程**内部**跑一个绑定到 loopback 的微型 HTTP server,host 侧的
CLI 通过 `adb forward` 与之通信。agent 在进程内捕获实时 UI 树;CLI 解析选择器
并派发真实输入。

| 关注点 | Android | iOS |
| --- | --- | --- |
| 把代码送进进程 | 链接 `reticle-agent` AAR——空操作 `ContentProvider` 自动启动 server,无需改应用代码。**可调试**但未链接 AAR 时,`reticle app inject` 经 JDWP 加载 payload dex:无需重打包、无需 root,连 `wrap.sh` 被禁的锁定 `user` 构建也可用。不可调试的 release 仍需 Frida/root。 | 链接 `ReticleKit` 并调 `Reticle.start()`(或交给 DYLD 构造器)。`app inject` 在模拟器上用 `DYLD_INSERT_LIBRARIES`;自签名的 debug 构建也能在真机上注入(`scripts/inject-ios-device.sh`)。 |
| 与运行中的应用通信 | 进程内 `ReticleServer` 监听 `127.0.0.1`,经 `adb forward` 抵达。 | 同一个 loopback server,模拟器直连、真机走 `iproxy`。 |
| 捕获 UI | `WindowManagerGlobal` 根 + 反射 View 属性,合并 Compose **semantics** 树。 | `UIWindow` + 反射 UIKit 属性,合并 SwiftUI 的**无障碍**元素(`axElement`)。 |
| 读嵌入式 Web 内容 | `android.webkit.WebView` 上的只读 DOM 桥。**第三方内核**(X5/TBS、UC)根本无法桥接——标记为 `dom:unsupported-kernel`,而不是报成一个空页面。 | `WKWebView` 上同一套桥;iOS 只有一个 web 引擎,内核那种情况不会出现。 |
| 合成输入 | `adb shell input`(tap / swipe / drag / type)——公开且稳定。 | 模拟器用 CoreSimulator HID;真机没有 host 可达的 HID 面,用进程内 `act activate`。 |
| 选择器解析 | 语义树优先、view 树 frame 兜底;`testId` / `resourceId` / `css` / `ref` / `label` / 原始坐标点——两端同一套顺序。 | 同上,由 `reticle-protocol/fixtures/selector-resolution.cases.json` 从两种语言双向钉住。 |

两条规则在两个平台都成立:loopback 端口按 bundle id / `applicationId` 逐应用派生、
两端算法一致,所以已链接的应用不会在固定端口上冲突;选择器只来自
语义/无障碍面,绝不取私有框架内部——没有无障碍身份的元素被明确记为"不可寻址",
而不是靠猜。

完整设计见 `docs/architecture.md`(含 Compose-semantics / SwiftUI 边界与注入权衡);
`docs/boundaries.md` 收齐了进程内观察者结构上够不着的所有情况(闭合 shadow root、
跨域 iframe、第三方 WebView 内核、烘进位图的文字、跨进程系统 UI、截图的盲区),
每条边界都挨着 Reticle 改吐什么证据——而不是回一个看起来合理的"空"。

## 样式证据

`ui style` 报告每个节点的几何与样式属性——间距、颜色、字号/字重/字体/行高、圆角、
边框——每个值都以比对所需的单位给出,并各自标注它是从哪条通道读到的:

```
screen: 1080x2400px density=3 fontScale=1 -> 360x800dp
#checkout.payButton button "Pay now"
    frame  24,1800 1032x120px | 8,600 344x40dp | 95.6%x5% of screen
    cornerRadius  24px | 8dp  [drawableReflect]
    paddingLeft   48px | 16dp  [viewField]
    textSize      42px | 14dp | 14sp  [viewField]
    ! fontFamily  unreadable: android-typeface-exposes-no-family
```

有三件事是截图做不到的。长度除了原始像素还会给出 **dp**,于是同一个屏幕在 320dp 和
411dp 的设备上可以直接比较;文本还额外给出 **sp**,它把系统字体缩放除掉——从而把
"应用要的字号就是错的"和"用户把字体调大了"分开。读不到的属性会**连同原因一起点名**,
而不是干脆缺席,于是"应用没设字体"和"根本没有通往它的通道"不再长得一样。而每个值都
带着自己的**通道**,因为一个实时 view 字段和一次反射出来的 `Drawable` 可信度并不相同。

它刻意不做比对。值应该是多少、容差算多大、哪些区域豁免,都是调用方的策略——所以同一份
输出既能服务设计还原度检查,也能服务跨构建 diff,或同一个屏幕在两台设备上的对照,
而 Reticle 不需要知道是哪一种。

```bash
reticle ui style snapshot.json
reticle ui style --live --package <pkg>
```

## 多区域控件

单个 View 可以承载多个点击目标——典型例子是协议勾选行:
*"我已阅读并同意 [服务条款][隐私政策]"*,其中文本切换勾选框,而每个链接打开
不同的页面。view 树和语义树都会把它塌缩成一个节点。Reticle 通过多条通道将其
拆解:

- **`span`**——真实的 `ClickableSpan` / `URLSpan` 区间,带逐行像素命中矩形和
  链接颜色。
- **`a11yVirtual`**——虚拟无障碍子节点(`ExploreByTouchHelper`),无论 app 采用
  哪种虚拟 id 约定。
- **`touchDelegate`**——扩展/转发的命中矩形(API 29+),无标签,因此用
  `--region touchDelegate` 定位。
- **`textMarker`**——自绘行上每个文本内括号/markdown 链接对应一个区域,各自带
  矩形。括号检测与脚本无关(markdown `[text](url)`,以及 `«…»`、`《…》` 这类
  成对分隔符)。
- **`colorSpan`**——一段重新着色的文本("高亮即链接"模式),连同其真实颜色一并
  暴露。
- **字符网格(char grid)**——来自已排版文本的逐字符精确 X 坐标,因此即使没有任何
  结构性标记,agent 也能按子串命中任意短语(对字体、字号、字间距/行距都稳健——
  全部读自 `Layout`)。

区域匹配就是普通的子串匹配——传入屏幕上出现的文本即可,任何语言皆可。

```bash
reticle ui regions snapshot.json
reticle act tap --package <pkg> --test-id agreement --region "隐私政策"
reticle act tap --package <pkg> --test-id agreement --region "服务条款"
```

## 作为 Claude Code 插件安装

Reticle 以 Claude Code 插件形式发布。把本仓库添加为 marketplace 并安装:

```text
/plugin marketplace add KQAR/Reticle
/plugin install reticle@reticle
```

这会把 `reticle` CLI 放到 Bash PATH 上,并添加:

- **`reticle`** skill——教 agent 何时以及如何检查/驱动一个运行中的应用;
- **`/reticle:report`**——捕获一份运行时 UI 报告并概括当前屏幕;
- **`/reticle:verify`**——端到端驱动一条流程,再逐步基于捕获到的证据下判断。

### 在 Cursor 中安装

同一个仓库也是一个 Cursor 插件——`.cursor-plugin/` 下的清单镜像了
`.claude-plugin/`,并共享完全相同的 `skills/` 与 `commands/`,因此两个编辑器只有
一份事实来源。像安装任何 Cursor 插件一样添加 marketplace 并安装 `reticle`;
下面的启动器与 CLI 获取流程完全一致。

### CLI 如何获取

`reticle` 是 **Swift host**——一个无 JDK 的原生 macOS 14+ arm64 二进制,它通过相邻的
**原生 helper**(`reticle-helper`,即由 GraalVM native-image 编译的 Kotlin Android
层)驱动 Android。

启动器按以下顺序解析它(命中即止):

1. `$RETICLE_HOST`——指向某个 `reticle-host` 二进制的显式路径。
2. `$RETICLE_HOME/bin`——一个已解包的 release(`reticle-host` + `reticle-helper`)。
3. `RETICLE_FROM_SOURCE=1`——**显式选择**的源码构建(Swift host 用 `swift`,原生
   helper 用内置 Gradle + 一个 GraalVM)。仅用于开发。
4. 一个**预编译 release**——缓存在 `~/.reticle/cli`,或新鲜下载(带 SHA256 校验)
   自 [GitHub Releases](https://github.com/KQAR/Reticle/releases)。**这是默认项**;
   需要 `curl`+`unzip` 和网络,但**不需要 JDK**。

默认情况下 Reticle 总是使用预编译 release——无需工具链,且**不会静默地从源码构建**。
若无法获取下载,启动器会停下并给出指引,而不是回退。用 `reticle version` 确认;
用 `reticle doctor` 检查 adb 与设备。用 `RETICLE_REPO` 锁定到某个 fork。

要在不安装的情况下本地开发或测试:在仓库根目录运行 `claude --plugin-dir ./`。

发布就是推一个 `v*` tag:`.github/workflows/release.yml` 在 macOS arm64 runner 上构建
`reticle-macos-arm64.zip` 发行包、agent AAR 与 `SHA256SUMS`。打包与版本一致性规则见
`AGENTS.md`。

## 模块

- `reticle-protocol`——与语言无关的 wire 契约:JSON Schema 加 golden fixture,两种
  语言的实现都要对着它跑测试。不是构建模块。
- `reticle-core`(Kotlin)与 `reticle-swift`(`ReticleProtocol`)——该契约的两个实现:
  snapshot / 语义 / 紧凑观察模型、派生逻辑、host 侧渲染器。`reticle-core` 无 Android
  依赖;`ReticleProtocol` 由 iOS agent 与 Swift host 共用,谁都不用重新移植协议。
- `reticle-agent/android`(`:reticle-agent:android`)——Android 库(AAR):进程内 HTTP
  server、view + Compose-semantics 捕获、区域检测、运行时变更、截图,由空操作
  `ContentProvider` 自动启动。
- `reticle-agent/ios`(`ReticleKit` + `ReticleInjection`)——iOS 孪生体,由 SwiftPM 构建、
  对 Gradle 不可见:同一套 server 与捕获,建在 UIKit 上并带 SwiftUI 无障碍桥,支持
  链接式与 DYLD 构造器两种自启动。
- `reticle-helper`——Kotlin 的 **Android** host 层:`adb forward`、loopback 证据、
  `adb input` 动作后端、JDWP 注入。**不是面向用户的 CLI**——以无 JDK 的原生
  `reticle-helper`(GraalVM native-image)分发,其 `helper` 子命令是 Swift host 驱动的
  RPC server。它存在的唯一理由是 JDWP 注入天然属于 JVM;iOS 不需要 helper。
- `reticle-host`——**Swift host CLI**(SwiftPM,macOS 14+ arm64),面向用户的 `reticle`。
  Android 设备命令走 helper RPC;**iOS 在 host 内原生处理**(`simctl`/`devicectl`、
  loopback HTTP、CoreSimulator HID)。`reticle serve` 持有本机 daemon 的 session /
  event surface(Hummingbird 2.25.0),捕获代理在独立的 `ReticleNetworkLane` target 里,
  iOS 后端在 `ReticleHostIos` 里。
- `sample-app` / `sample-app-ios`——端到端链接各自 agent 的演示应用,各带一个无 agent
  的 flavor 用于测试注入路径。

## 快速开始

```bash
# 构建全部
./gradlew assemble

# 在已启动的模拟器/设备上安装 linked 示例应用
adb install sample-app/build/outputs/apk/linked/debug/sample-app-linked-debug.apk

# `reticle` 启动器即 Swift host;RETICLE_FROM_SOURCE=1 时它从源码构建并运行 host
# 与原生 helper(需 Swift 工具链 + 一个 GraalVM)。这是面向用户的 CLI。
export RETICLE_FROM_SOURCE=1
CLI="bin/reticle"

# 启动 + forward + 等待进程内运行时(对于**链接了** agent 的应用)
$CLI app launch --package dev.reticle.sample

# 或者,对于一个**可调试**但未链接 agent 的应用:先启动它,然后通过 JDWP 注入
# 运行时——无需重打包、无需 root。注入之后,下面所有命令对它原样可用。
# (见 `noagent` 示例 flavor。)
$CLI app inject --package dev.reticle.sample.noagent

# 捕获示例首页报告,选择一个场景行
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui compact reticle-report/snapshot.json
$CLI act tap --package dev.reticle.sample --test-id scenario.checkout

# `ui outline` 给可见目标编号并缓存一份短时别名。导航之后要重跑;重复行上的
# item i/n 只是位置提示,不是选择器。(别名缓存目前只有 Android 有。)
$CLI ui outline --live --package dev.reticle.sample
$CLI act tap --package dev.reticle.sample --alias @1

# 对应用执行操作(语义/选择器优先,frame 兜底)
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui node reticle-report/snapshot.json --test-id checkout.payButton
$CLI act tap --package dev.reticle.sample --test-id checkout.payButton

# 选择器没命中时,会从当前快照里列出同类候选,于是你可以换一个稳定 handle 重新
# 定位,而不是退回去写死坐标。

# 内嵌 WebView DOM:按 CSS selector 检查、点击、验证,并保留 trace 证据包
$CLI act tap --package dev.reticle.sample --test-id scenario.webview
$CLI ui report --package dev.reticle.sample --output reticle-webview
$CLI ui node reticle-webview/snapshot.json --css '#style-target'
$CLI act tap --package dev.reticle.sample --css '#style-target' \
    --verify 'css=#style-target' \
    --trace-output reticle-traces

# 把录下的 trace 流程拼成带设备边框的动图:before 帧画出手势落点
# (tap 圆环 / swipe 箭头),after 帧展示结果,字幕取自 gesture + selector。
# 纯 host 本地,Android / iOS trace 通用。
$CLI replay gif reticle-traces          # => reticle-traces/replay.gif

# 多区域控件:一个 View、多个点击目标(协议勾选行等)
$CLI app launch --package dev.reticle.sample
$CLI act tap --package dev.reticle.sample --test-id scenario.agreements
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui regions reticle-report/snapshot.json
$CLI act tap --package dev.reticle.sample --test-id agreement.span     --region "Terms"
$CLI act tap --package dev.reticle.sample --test-id agreement.markdown --region "«Privacy»"

# 惰性列表只绑定它可见的那一段,所以很靠下的行根本没有节点可点。
# `act scroll-to` 在容器内持续拖动,直到选择器解析成功,再确认位置已经不再移动;
# 拖到没有余量还没找到就显式失败。
$CLI act tap       --package dev.reticle.sample --test-id scenario.list
$CLI act scroll-to --package dev.reticle.sample --test-id list.item40
$CLI act tap       --package dev.reticle.sample --test-id list.item40

# 目标"还在动"是同一个问题往前一步:动画中途取到的矩形,等触摸落下时已经过期。
# 每次按选择器 tap 都会反复重新解析、直到坐标点重复出现才派发,并在第一次读数
# 确实已经过期时报 `rectMoved=<dx>,<dy>`。`--settle` 给明确正在入场动画的目标
# 放宽预算;`--no-settle` 退出这次确认(只关位置——见 docs/architecture.md)。
$CLI act tap --package dev.reticle.sample --test-id popup.menuTrigger
$CLI act tap --package dev.reticle.sample --label "Delete item" --settle

# 系统键盘是另一个进程的窗口——它不在节点树里,被盖住的提交按钮看起来仍然
# tappable。快照带 screen.keyboard,`ui compact` 首行报键盘状态,被盖条目标
# occluded-by:keyboard(弹窗盖住底层页面时同理标 occluded-by:<窗口ref>),
# hide-keyboard 在进程内收起键盘。--target ios 用法完全一致。
$CLI act tap  --package dev.reticle.sample --test-id scenario.login
$CLI act type --package dev.reticle.sample --test-id login.codeField --text "123456"
$CLI ui compact --live --package dev.reticle.sample   # keyboard: visible … occluded-by:keyboard
$CLI act hide-keyboard --package dev.reticle.sample
$CLI act tap  --package dev.reticle.sample --test-id login.submitButton

# 也可以省掉 hide-keyboard + tap 两步:--submit 在文本落入后按下键盘动作键
# (Android 走 agent 的 IME editor action,即 React Native onSubmitEditing
# 监听的那个回调;iOS 模拟器发 HID Return)。
$CLI act type --package dev.reticle.sample --test-id login.codeField \
    --text "123456" --submit

# 读取应用自行写入的运行时日志
$CLI debug logs --package dev.reticle.sample

# 在不重新构建的情况下实时修改某个允许列表内的属性
$CLI mutate --package dev.reticle.sample --test-id checkout.status \
    --property text --value "Paid!"
```

### 应用自述通道(可选,从应用内部写入)

链接了 agent 的应用可以给 Reticle 看到的内容做补充。这几个 API 都只写进程内的缓冲区
——在 Reticle 来取之前没有任何东西离开应用,日志环也是有界的——所以留在 debug 构建里
是安全的:

| API(Android / iOS) | 补充了什么 |
| --- | --- |
| `Reticle.log(message, metadata)` | `debug logs` 里的一条记录——应用自己的叙述,与树并排 |
| `Reticle.attachMetadata(testId, metadata)` | 捕获时把标量字段并进该节点的 `custom` map |
| `Reticle.registerProbe(testId, metadata)` | 挂在 application 根下的合成节点,用于没有 view 可依附的状态 |

probe 是进程全局的,所以进入时发布、**离开时撤销**——Android 用
`ReticleProbeRegistry.clear()`,iOS 用 `Reticle.clearProbes()`。不撤销的话,为某一个
屏幕注册的 `testId` 在之后每个屏幕上都仍然可寻址,读起来像一个过期的目标,而不像
一处泄漏。

所有由 helper 承载的命令都接受 `--json` 输出机器可读结果:成功是
`{ "ok": true, "data": ... }`,失败是 `{ "ok": false, "error": ... }`。交互使用仍以
文本输出为默认:

```bash
$CLI doctor --json
$CLI act tap --package dev.reticle.sample --test-id checkout.payButton --verify --json
$CLI ui node --live --package dev.reticle.sample --test-id checkout.status --json
```

## 本机 session 事件总线

`reticle serve` 启动本机 daemon:一个由 Hummingbird 承载的 localhost REST/SSE
事件总线,并把 session 事件追加写入
`~/.reticle/sessions/<session>/events.jsonl`。它内置只读 Web 面板;传入
`--proxy-port` 时还会启动 host 捕获代理,把 `network.request`、
`network.response`、`network.error` 写入同一个 session。捕获由
[Loom](https://github.com/KQAR/Loom) 引擎驱动(以 SPM 库形式依赖),
Reticle 把它的 flow 归一化后写入会话事件流。

```bash
reticle serve --session demo --port 9876 --proxy-port 9090
curl -s http://127.0.0.1:9876/health
curl -N http://127.0.0.1:9876/events/stream
# 浏览器打开 http://127.0.0.1:9876/panel
```

Android 抓包可加 `--proxy-device --serial <id>`:Reticle 会通过 `adb reverse`
和 `settings put global http_proxy` 配置设备代理,并在 `serve` 退出时尽量恢复原
代理设置。明文 HTTP 会直接捕获;HTTPS CONNECT tunnel 会记录耗时并展示。若需要解密
HTTPS,需显式开启 `--proxy-mitm --proxy-ssl-hosts <host[,host]>`。Reticle 默认在
`~/.reticle/proxy-ca` 生成本机 CA(可用 `--proxy-ca-dir <dir>` 覆盖),并按 host
动态签发 leaf 证书。加 `--proxy-install-ca` 会把 `reticle-ca.cer` 推到设备并打开
Android 安全设置;Android 11+ 仍必须由用户在设置中确认 CA 信任。未信任用户 CA、未在
Network Security Config 中信任用户 CA,或启用证书 pinning 的 app 仍无法解密。

**iOS 的路由永远不由 Reticle 代改**,模拟器和真机都一样:模拟器共享宿主网络(改它等于
改宿主全局代理),真机走的是手机 Wi-Fi 设置,而 daemon 中途挂掉会把任何一方撂在一个已
关闭的端口上。因此 `--proxy-device` 只**打印**该目标的设置与撤销命令,自己不改任何状态。
真机装 CA 不必来回传 `.cer`:加 `--proxy-phone-onboard true`,Loom 会在局域网上提供一个
provisioning 页面,`serve` 打印它的 URL、CA 的 SHA-256 指纹和一个可扫的二维码(同时写到
`~/.reticle/phone-onboard-qr.png`)。它会**自己**把代理 rebind 到 `0.0.0.0`,要求 Mac 处于
Wi-Fi/以太网,并且这个 LAN-wide 绑定会持续到 daemon 结束;它只发信任、不发路由,手机的
Wi-Fi 代理仍需你自己设。详见 `docs/ios.md` → **Network capture**。

被代理的请求 body 在转发上游前先缓冲在内存里,因此默认封顶 64 MiB;更大的上传会以
`413` + 一条 `network.error` 事件被拒,而不是把 daemon 的内存吃掉。上下调这个上限用
`--proxy-max-request-body-mb <n>`。

现有一次性命令在 daemon 不运行时仍按原样工作。daemon 运行时,
`reticle act ...` 会自动把 trace 包写入当前 session,并 best-effort 发布一条
`action.trace` 事件;snapshot 和 screenshot 通过 `refs` 引用,不会内联进事件。
面板把每条 action trace 平铺成纵向证据时间线——screenshot 证据、action、screenshot
证据、diff——网络请求按 request id 聚合在中轴另一侧,Cookie / Authorization 这类
敏感 header 值在进入事件日志前就脱敏,picker 可在 live session 与
`~/.reticle/sessions` 下的历史 session 间切换。它只展示:既不驱动输入也不改应用状态。
需要把 trace 额外复制到 session 之外时,再显式传 `--trace-output <dir>`。

面板的完整能力(过滤、rule 分组、copy-as-rule)与 REST/SSE surface、事件信封一起写在
`reticle-protocol/events.md`。

### 录制与回读

**录制默认常开,不依赖 daemon。** 没有 `serve` 时,动作录进自动 session
(`~/.reticle/sessions/auto-<时间戳>/traces`);15 分钟内相邻的命令归入同一个。清理只
针对 Reticle 自己创建的 session——判定依据是它写入的标记文件而非名字,所以你手工命名的
session 永远不在候选内——保留最近 20 个、总量不超过 2 GB,删了什么会打到 stderr。
`RETICLE_NO_AUTO_TRACE=1` 关掉自动录制;显式 `--trace-output` 不受影响。

`reticle trace log` 把一次录制渲染成每个动作几行,回溯一整段会话不必再打开每份
100KB+ 的 snapshot:

```bash
reticle trace log                       # 当前这次录制
reticle trace log reticle-batch         # 或任意 trace 目录
reticle trace log --changes 12 --json   # 更详细 / 机器可读
```

```
recording /Users/you/.reticle/sessions/auto-20260727-191146/traces
android · dev.reticle.sample · 3 actions · 19:11:47 → 19:11:55

1  19:11:47  tap  testId=scenario.checkout  →540,241 semantic:testId
    + r36 [testId=checkout.status role=text]
    + r37 [testId=checkout.payButton role=button]
    …7 more (present 5, children 1, nodeCount 1)
    evidence 1785150707495-tap/, 2 snapshots, 2 screenshots

2  19:11:48  tap  testId=checkout.payButton  →540,1176 semantic:testId
    ~ r36 text "Cart: 3 items" → "Paid!" [testId=checkout.status role=text]
    evidence 1785150708052-tap/, 2 snapshots, 2 screenshots

3  19:11:55  tap  testId=scenario.login  →540,2320 semantic:testId
    (no observable change between before and after — usually the gesture hit
     nothing, but an app can also answer out of tree or purely over the network)
    evidence 1785150715273-tap/, 2 snapshots, 2 screenshots
```

让它可读而不只是变短的是三件事。每条变更**说出它讲的是哪个节点**(`[testId=…]`),
同一个 ref 只标一次,于是一个光秃秃的 `r36` 不会再把你打发去翻 snapshot。diff **先排序
再截断**——出现与文案变化排在像素级 `frame` 抖动之前,可寻址的节点排在匿名布局容器之前
——所以截断后留下的是真正要紧的那些。而每一次丢弃都**有计数、不静默**:渲染层是
`…N more`,捕获层是 `! manifest kept X of Y`。什么都没变的动作会明说
`(no observable change between before and after)`——上面第 3 步就是:tap 派发成功了,
但屏幕没有任何反应。这是一条结论,不是一片空白。而且它会把两种读法都说出来:「手势没
命中」和「手势命中了、app 在树外回答了你」需要相反的处置。最常见的第二种是 toast——
它由系统绘制,不在任何视图树里,也不在进程内截图里,这一步会以
`! transient message shown: "…"` 打头,内容取自系统的 Toast Queue。

`trace log` 只读。它不是回放脚本,也不做任何断言:一次运行算不算通过由读的人判断,
要表达预期仍然用 `--verify` 和 `act wait --strict`。

### 热路径与命令路由

一次性命令默认走热路径:第一条 helper 命令会 fork-exec 一个按设备划分的
`reticle helper-daemon`(socket 在 `~/.reticle/helperd/` 下),之后每条命令复用这个常驻
helper,不再逐命令拉起进程。daemon 空闲 600s 后自行退出并删掉 socket;用
`--no-daemon` / `RETICLE_NO_DAEMON=1` 关掉,任何拉起失败都会静默回退到直接 spawn。

另一种路由是:`reticle serve` 已经在跑时,让命令走它的 helper broker:

```bash
reticle serve --session demo --helper-broker
RETICLE_USE_DAEMON=1 reticle status --package dev.reticle.sample
reticle act tap --use-daemon --package dev.reticle.sample --test-id checkout.payButton
```

`--helper-broker` 让一个 `reticle-helper` 进程常驻在 daemon 的 localhost HTTP 面之后,
`--use-daemon`(或 `RETICLE_USE_DAEMON=1`)把同一批命令 RPC 转发过去,短命令序列因此
不用反复启动 helper。设备选择仍遵循 `--serial` 规则,单条命令上的 `--serial` 会覆盖
broker 的默认设备。

`reticle status --package <pkg>` 另外维护一份本机基线 `~/.reticle/process-state.json`。
若后续 status 发现进程 PID 变了、进程消失,或运行时从 healthy 跌到不健康状态,文本输出
会多一行 `advisory:`,JSON 输出会多一个 `advisory` 对象;`serve` 在跑时同一条会以
`runtime.advisory` 事件发布。

## 流量规则与 flow replay

`serve` 运行时,`reticle rule` 可在 host 代理里重塑流量而不碰应用。一条规则匹配
流量并应用一个**动作**——`mock`(返回存好的固定响应)、`block`(断开连接)、
`mapRemote`(改路由到另一个 origin)、`passthrough`——外加可叠加的修饰符
(`--delay-ms`、请求/响应 header rewrite、find/replace substitution)。规则与可复用
的响应值分开存在当前 session 里:

```bash
reticle rule set --id users --action mock --value-id users-ok \
  --method GET --url /api/users --match prefix --priority 100 \
  --status 200 --headers '{"Content-Type":"application/json"}' \
  --body '{"users":[]}'
reticle rule set --id kill-analytics --action block --method ANY --url /track --match prefix
reticle rule set --id slow-home --action passthrough --delay-ms 3000 --method GET --url /api/home --match prefix
reticle rule disable --id users
reticle rule list
```

明文 HTTP 规则直接生效;HTTPS 规则需 MITM 解密 + 应用信任 Reticle CA;不透明的
CONNECT tunnel 与启用 pinning / 未信任 HTTPS 的流量无法改写。

`reticle replay flow <request-id>` 重放一条已捕获的流(可带 `--method`/`--url`/
`--set-headers`/`--remove-headers`/`--body`/`--clear-body` 覆盖),发出
`network.replay` 事件并返回重放响应 vs 原始的 diff(status、body 大小、header 名字的
增删改——只报名字不报值,不泄露密钥):

```bash
reticle replay flow <request-id> --set-headers '{"X-Debug":"1"}' --remove-headers '["Authorization"]'
```

replay 是从捕获引擎的有界内存 ring 里重发的,所以更早的交换在 `events.jsonl` 里证据
完整、但已经不能再重放;`GET /sessions/current/flows` 会给每个结果打上
`replayableOnly`,让"空列表"读作"没有可重放的匹配项",而不是"这事没发生过"。
过滤在引擎的 store 里跑:`host`、`method`、`urlContains`、`status`、
`onlyErrors`、`sinceMillis`,外加 `headerContains`(`x-env: staging` 这种带冒号
的写法要求同一个 header 上两半都命中)和 `bodyContains`(匹配**已捕获**的原始
字节,所以在 `bodyCaptureTruncated` 的流上没命中并不能证明线上没有这串字节)。
从 HAR 导入引擎的交换会带 `importedFrom`,不会冒充成本次会话观察到的流量。

## 批量动作与快速冒烟

用链接了 agent 的示例应用跑一遍:

```bash
reticle app launch --package dev.reticle.sample
reticle act tap --package dev.reticle.sample --test-id scenario.checkout
reticle act tap --package dev.reticle.sample --test-id checkout.payButton \
  --verify '#checkout.status'
```

确定性的短流程可以写成 JSON 文件按序执行。Swift host 把每一步展开成同一个单动作
helper RPC,遇到第一个失败就停。step 的键就是协议字段名,所以单条 `act` 支持的每个
选择器在这里都能用——`testId`、`resourceId`、`css`、`ref`、`point`、`alias`、`region`
——外加 type 的 `text`/`submit`、swipe/drag 的 `from`/`to`/`duration`:

```json
[
  { "gesture": "tap", "testId": "scenario.checkout" },
  { "gesture": "tap", "resourceId": "btnWithdraw" },
  { "gesture": "type", "testId": "login.codeField", "text": "123456", "submit": true },
  { "gesture": "tap", "point": "540,1600" },
  { "gesture": "tap", "testId": "checkout.payButton", "verify": "testId=checkout.status" }
]
```

```bash
reticle act batch --package dev.reticle.sample --file steps.json \
  --trace-output reticle-batch

# 把录到的流程拼成带设备边框的 GIF(见上文)。
reticle replay gif reticle-batch          # => reticle-batch/replay.gif
```

## 工具链

*运行*预编译 release:Apple Silicon macOS 14+ + `adb`。无需 JDK。

*从源码构建*(开发者):

- Android SDK(compileSdk 35)、build-tools、platform-tools(`adb`)
- 用于 Gradle/AGP 的 JDK 17;用于原生 helper 的、带 `native-image` 的 **GraalVM**
- 用于 host 的 **Swift** 工具链(Xcode);Hummingbird 2.25.0 使 host target 要求
  macOS 14+
- Gradle 8.13(通过 wrapper)

两个 JDK 可以用 [mise](https://mise.jdx.dev/) 一步装齐:在仓库根目录跑 `mise install`
会装上 JDK 17(作为主 `java`/`JAVA_HOME`)和一个 GraalVM 21,后者的 `native-image`
会落到 `PATH` 上——不需要再设 `GRAALVM_HOME`。这是可选的,手工安装的 JDK 照旧可用;
Xcode/Swift 与 Android SDK 不由 mise 管理(见 `mise.toml`)。

面向 agent 的导览图与架构规则见 `AGENTS.md`。

## 灵感来源

Reticle 的灵感来自 [Loupe](https://github.com/heoblitz/Loupe),一个面向 Apple
平台的运行时 UI 检查与操作 harness。Reticle 把同样的理念——检查正在运行的应用
本身,而非其源码或截图——应用到 Android 上,并使用自己的注入、UI 捕获与输入机制。

## 许可证

Reticle 以 [MIT 许可证](LICENSE)发布。
