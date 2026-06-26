# Reticle

[English](README.md) | **简体中文**

Reticle 帮助 AI 编码 agent 在 **Android** 上构建并验证原生应用界面——它检查的是
**正在运行**的应用本身,而不是源码或一张截图。

Reticle 的职责是*定位并度量*屏幕上的内容:从实时的 view / 无障碍 /
Compose-semantics 树中解析出稳定的选择器和精确坐标,让 agent 能有把握地对正确的
元素执行操作。

`adb`、Espresso、UiAutomator 这类工具能构建、启动或驱动应用。Reticle 补上的是
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

| 关注点 | 机制 |
| --- | --- |
| 把代码送进进程 | 链接 `reticle-agent` AAR——一个空操作的 `ContentProvider` 自动启动 server,无需改应用代码。对于**可调试**但未链接 AAR 的应用:`reticle app inject` 通过 JDWP 加载一个 payload dex 并启动运行时——无需重打包、无需 root(即使在 `wrap.sh` 被禁的锁定 `user` 构建上也可用)。不可调试的 release 构建仍需 Frida/root。 |
| 与运行中的应用通信 | 进程内 `ReticleServer` 监听 `127.0.0.1`,CLI 经 `adb forward` 抵达。端口按 `applicationId` 逐应用派生(agent 与 CLI 算出同一个值),因此多个已链接应用绝不会在某个固定端口上冲突。 |
| 捕获 UI | 遍历 `WindowManagerGlobal` 根 + 反射 View 属性;合并 Compose **semantics** 树(选择器只来自 semantics,绝不取私有内部实现)。 |
| 合成输入 | `adb shell input`(tap / swipe / drag / type)——公开且稳定。 |
| 选择器解析 | 语义树优先,view 树 frame 兜底;`testId` / `resourceId` / `ref` / 原始坐标点。 |

完整设计见 `docs/architecture.md`,包括 Compose-semantics 边界与注入权衡。

## 多区域控件

单个 View 可以承载多个点击目标——典型例子是协议勾选行:
*"我已阅读并同意 [服务条款][隐私政策]"*,其中文本切换勾选框,而每个链接打开
不同的页面。view 树和语义树都会把它塌缩成一个节点。Reticle 通过多条通道将其
拆解:

- **`span`**——真实的 `ClickableSpan` / `URLSpan` 区间,带逐行像素命中矩形和
  链接颜色。
- **`a11yVirtual`**——虚拟无障碍子节点(`ExploreByTouchHelper`)。
- **`touchDelegate`**——扩展/转发的命中矩形。
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

- **`reticle`** skill——教 agent 何时以及如何检查/驱动一个运行中的 Android 应用;
- **`/reticle:report`**——捕获一份运行时 UI 报告并概括当前屏幕;
- **`/reticle:tap`**——按选择器(或通过 `--region` 按短语)点击某元素并验证结果。

### 在 Cursor 中安装

同一个仓库也是一个 Cursor 插件——`.cursor-plugin/` 下的清单镜像了
`.claude-plugin/`,并共享完全相同的 `skills/` 与 `commands/`,因此两个编辑器只有
一份事实来源。像安装任何 Cursor 插件一样添加 marketplace 并安装 `reticle`;
下面的启动器与 CLI 获取流程完全一致(无论哪个编辑器安装,`reticle` CLI 都会落到
PATH 上)。

### CLI 如何获取

启动器按以下顺序解析真正的 CLI 二进制(命中即止):

1. `$RETICLE_CLI`——指向某个 `reticle` 启动脚本的显式路径。
2. `$RETICLE_HOME/bin/reticle`——一个已解包的 release 发行包。
3. `RETICLE_FROM_SOURCE=1`——通过内置 Gradle 进行**显式选择**的源码构建
   (需要 JDK 17)。仅用于开发/离线场景。
4. 一个**预编译 release**——缓存在 `~/.reticle/cli`,或新鲜下载(带 SHA256 校验)
   自 [GitHub Releases](https://github.com/KQAR/Reticle/releases)。**这是默认项**;
   需要 `curl`+`unzip` 和网络,但**不需要 JDK**。

默认情况下 Reticle 总是使用预编译 release——无需工具链,且**不会静默地从源码构建**。
若无法获取下载,启动器会停下并给出指引(恢复网络 / 把 `RETICLE_HOME` 指向手动
下载 / 用 `RETICLE_FROM_SOURCE=1` 选择源码构建),而不是回退。用 `reticle version`
确认;用 `reticle doctor` 检查 adb 与设备。用 `RETICLE_REPO` 锁定到某个 fork。

host 侧要求:一台通过 `adb` 连接的 Android 设备/模拟器,以及预编译下载所需的
网络(或 `RETICLE_FROM_SOURCE=1` + JDK 17)。

要在不安装的情况下本地开发或测试:在仓库根目录运行 `claude --plugin-dir ./`。

### 发布

推送一个 `v*` tag 会触发 `.github/workflows/release.yml`,它会构建并附加到一个
GitHub Release:

- `reticle-cli.zip` / `reticle-cli.tar`——host CLI 发行包(启动器下载的就是它);
- `reticle-agent-android.aar`——供链接进 host 应用构建的 agent 库;
- `SHA256SUMS`——用于校验的校验和。

## 模块

- `reticle-core`——纯 JVM 的 snapshot / 语义 / 紧凑观察模型与 wire 协议。无
  Android 依赖。
- `reticle-agent/android`(`:reticle-agent:android`)——Android 库(AAR)。进程内
  HTTP server + view 与 Compose-semantics 捕获、区域检测、运行时变更、截图,由一个
  空操作 `ContentProvider` 自动启动。(`reticle-agent/` 是为未来逐平台 agent
  预留的分组目录;目前只有 Android 子项是 Gradle 模块。)
- `reticle-cli`——host 侧 JVM CLI。`adb forward` + loopback 证据 + 一个
  `adb input` 动作后端。
- `sample-app`——端到端链接 agent 的演示应用。

## 快速开始

```bash
# 构建全部
./gradlew assemble

# 在已启动的模拟器/设备上安装示例应用
adb install sample-app/build/outputs/apk/debug/sample-app-debug.apk

# 运行 CLI(通过生成的启动脚本)
./gradlew :reticle-cli:installDist
CLI=reticle-cli/build/install/reticle/bin/reticle

# 启动 + forward + 等待进程内运行时(对于**链接了** agent 的应用)
$CLI app launch --package dev.reticle.sample

# 或者,对于一个**可调试**但未链接 agent 的应用:先启动它,然后通过 JDWP 注入
# 运行时——无需重打包、无需 root。注入之后,下面所有命令对它原样可用。
# (见 `noagent` 示例 flavor。)
$CLI app inject --package dev.reticle.sample.noagent

# 捕获一份运行时报告
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui compact reticle-report/snapshot.json
$CLI ui node reticle-report/snapshot.json --test-id checkout.payButton

# 对应用执行操作(语义/选择器优先,frame 兜底)
$CLI act tap --package dev.reticle.sample --test-id checkout.payButton

# 多区域控件:一个 View、多个点击目标(协议勾选行等)
$CLI ui regions reticle-report/snapshot.json
$CLI act tap --package dev.reticle.sample --test-id agreement.span     --region "Terms"
$CLI act tap --package dev.reticle.sample --test-id agreement.markdown --region "«Privacy»"

# 读取应用自行写入的运行时日志
$CLI debug logs --package dev.reticle.sample

# 在不重新构建的情况下实时修改某个允许列表内的属性
$CLI mutate --package dev.reticle.sample --test-id checkout.status \
    --property text --value "Paid!"
```

## 工具链

- Android SDK(compileSdk 35)、build-tools、platform-tools(`adb`)
- 用于 Gradle/AGP 的 JDK 17
- Gradle 8.13(通过 wrapper)

面向 agent 的导览图与架构规则见 `AGENTS.md`。

## 灵感来源

Reticle 的灵感来自 [Loupe](https://github.com/heoblitz/Loupe),一个面向 Apple
平台的运行时 UI 检查与操作 harness。Reticle 把同样的理念——检查正在运行的应用
本身,而非其源码或截图——应用到 Android 上,并使用自己的注入、UI 捕获与输入机制。

## 许可证

Reticle 以 [MIT 许可证](LICENSE)发布。
