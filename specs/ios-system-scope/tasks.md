# Tasks: iOS 真机 system scope

**Workspace**: `ios-system-scope` | **Date**: 2026-08-11
**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Explore**: [explore.md](explore.md) | **Test Plan**: [test-plan.md](test-plan.md)

> 说明：本任务列表由主 agent 生成，未启动只读探索 subagent（用户环境明确约束不使用 subagent）。
>
> **真机验证的执行前提**：本需求的绝大多数 TC 只能在真机上验证，且依赖三个人工前置条件——设备解锁（Auto-Lock=Never）、设备端 Enable UI Automation 已开启、本机有含该设备的通配 profile。这些 Gate **无法在 CI 中运行**，与既有 `scripts/e2e-ios-device.sh` 同样属于手动执行的验证脚本。TC-002 / TC-006 需要临时关闭上述条件来验证报错，执行后需恢复。

---

## Phase 1 — US1: 准备与收摊（含 runner 工程与协议类型）

此 Phase 跨 Phase Gate：无（prepare / stop / status 是完整可独立验证的功能单元，其 E2E 不依赖后续 Phase 的读写能力）。

### 实现

- [x] T001 [US1] 新建 runner 工程骨架：一个不依赖目标 app 的独立 UITest 工程，其唯一测试方法启动 HTTP server 后永不返回，作为常驻进程的载体
  - **状态: done（2026-08-12 环境恢复后验证）** — 真机 `xcodebuild test` 与 `test-without-building` 两种方式均常驻成功。此前的失败全部源于设备 automation 服务故障，重启后消失。工程含一个占位 host target（排查时加入，予以保留）
  - files: [新增] reticle-runner-ios/project.yml, [新增] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerServerTest.swift
  - symbols: N/A（新增；工程组织方式参照 sample-app-ios/xcode/project.yml 的 xcodegen 用法）
  - tests: N/A
  - covers: N/A

- [x] T002 [P] [US1] 在 runner 中实现 HTTP server 与 /health 端点，端口由 runner 自身 bundle id 经既有派生规则算出，使其与目标 app 端口天然不撞
  - **状态: done（2026-08-12）** — `/health` 在真机上实测应答：`{"screenWidth":428,"screenHeight":926,"pointScale":3,"version":"0.1.0"}`，端口 9346 由 `PortMap` 派生并经 USB 隧道连通
  - files: [新增] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerHTTPServer.swift, [修改] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerServerTest.swift
  - symbols: PortMap.derivePort
  - tests: N/A（端点契约由 T012 的 E2E 覆盖）
  - covers: N/A

- [x] T003 [P] [US1] 在协议层新增 system 通道的独立观测类型，不复用 Node、不扩 NodeKind，从类型上阻止两条通道的证据合流
  - files: [新增] reticle-swift/Sources/ReticleProtocol/SystemObservation.swift
  - symbols: SystemObservation, SystemNode, Node.styleGaps（作为 unreadable 字段形状的参照先例）
  - tests: [新增] reticle-swift/Tests/ReticleProtocolTests/SystemObservationTests.swift
  - covers: TC-030

- [x] T004 [US1] 实现 runner 生命周期管理：设备与签名材料校验、构建、替换旧实例、安装、启动、隧道、探活、停止
  - files: [新增] reticle-host/Sources/ReticleHostIos/IosRunnerLifecycle.swift
  - symbols: IosSimctl, Simctl.isSimulator, HelperError
  - tests: [新增] reticle-host/Tests/ReticleHostCoreTests/IosRunnerLifecycleTests.swift
  - covers: TC-029

- [x] T005 [US1] 实现启动失败的原因判别，把「设备端 UI Automation 开关未开」从伪装成连接错误的底层报错中单独识别出来，并给出设备端操作指引
  - files: [新增] reticle-host/Sources/ReticleHostIos/IosRunnerFailure.swift, [修改] reticle-host/Sources/ReticleHostIos/IosRunnerLifecycle.swift
  - symbols: IosRunnerFailure
  - tests: [新增] reticle-host/Tests/ReticleHostCoreTests/IosRunnerFailureTests.swift
  - covers: TC-031

- [x] T006 [P] [US1] 实现 runner 的 HTTP 客户端，含「进程已消失则重启一次并重试一次、且必须在结果中标注曾中断」的语义
  - files: [新增] reticle-host/Sources/ReticleHostIos/IosRunnerClient.swift
  - symbols: IosAgentHTTP（形状参照）, ReticleJSON
  - tests: [新增] reticle-host/Tests/ReticleHostCoreTests/IosRunnerClientTests.swift
  - covers: N/A（重启声明的行为由 T015 的 E2E 覆盖）

- [x] T007 [US1] 实现 system 命令族的执行者，负责平台准入、连通保障、来源标注与 unreadable 填充
  - files: [新增] reticle-host/Sources/ReticleHostIos/IosSystemBackend.swift
  - symbols: IosSystemBackend, HostBackend（**不实现**，见 plan Decision 1）
  - tests: N/A（准入分支由 T008 承载）
  - covers: N/A

- [x] T008 [US1] 在 CLI 中新增 system 一级子命令分支及 prepare / stop / status 三条命令，并实现模拟器上的准入拒绝与替代命令指引
  - files: [修改] reticle-host/Sources/ReticleHostCore/CLI/ReticleCLI.swift, [新增] reticle-host/Sources/ReticleHostCore/CLI/ReticleSystemCommands.swift
  - symbols: ReticleCLI dispatch switch
  - tests: [新增] reticle-host/Tests/ReticleHostCoreTests/IosSystemCommandTests.swift
  - covers: TC-028

- [x] T009 [US1] 新增 system 通道的真机 e2e 脚本，覆盖准备、状态、停止三条路径及其边界；不扩写既有 e2e-ios-device.sh，因两者前置条件冲突（后者假设 app 保持前台，而本通道会主动把 app 踢到后台）
  - files: [新增] scripts/e2e-ios-system.sh
  - symbols: N/A
  - tests: [新增] scripts/e2e-ios-system.sh（脚本自身即验证载体）
  - covers: TC-001, TC-002, TC-003, TC-004, TC-005, TC-006, TC-007, TC-008

### Phase 1 门禁

- [x] [Gate] `swift build` 在 reticle-swift 与 reticle-host 均通过
- [x] [Gate] 运行 SystemObservationTests（UT）→ 验证 TC-030（10 tests passed）
- [x] [Gate] 运行 IosRunnerLifecycleTests、IosRunnerFailureTests、IosRunnerClientTests、IosSystemCommandTests（UT）→ 验证 TC-029, TC-031, TC-028（30 tests / 4 suites passed）
- [x] [Gate] 真机执行 `scripts/e2e-ios-system.sh` 的 PREPARE 段 → 验证 TC-001, TC-003, TC-004, TC-005, TC-007, TC-008（ALL AUTOMATED SYSTEM-CHANNEL CHECKS PASSED，2026-08-12）
- [ ] [Gate] 真机手动验证两个需要临时破坏前置条件的场景，验证后恢复设置 → 验证 TC-002（关闭设备端 Enable UI Automation）, TC-006（锁屏）
  （**待人工执行**：脚本末尾的 MANUAL 段列出了两条的具体做法与判据）

---

## Phase 2 — US2: 读取另一个进程的界面

此 Phase 跨 Phase Gate：无（读取能力自身完整，其 E2E 只需 Phase 1 已完成的连通能力）。

### 实现

- [x] T010 [US2] 在 runner 中实现最上层覆盖物的读取，并在无覆盖物时返回明确结论而非空树
  - files: [新增] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerObservation.swift, [修改] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerHTTPServer.swift
  - symbols: XCUIApplication, XCUIElement.ElementType
  - tests: N/A（由 T013 的 E2E 覆盖）
  - covers: N/A

- [x] T011 [US2] 在 runner 中实现按显式目标读取（主屏或指定 bundle id），并施加节点数与深度上限、超限时返回截断声明
  - files: [修改] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerObservation.swift
  - symbols: N/A
  - tests: N/A（由 T013 的 E2E 覆盖）
  - covers: N/A

- [x] T012 [US2] 在宿主侧实现读取命令，落实来源标注与 unreadable 填充，并把该通道读不到的属性显式表达为不可读而非空值
  - files: [修改] reticle-host/Sources/ReticleHostIos/IosSystemBackend.swift, [修改] reticle-host/Sources/ReticleHostCore/CLI/ReticleSystemCommands.swift
  - symbols: SystemObservation, SystemNode.unreadable
  - tests: [修改] reticle-host/Tests/ReticleHostCoreTests/IosSystemCommandTests.swift
  - covers: N/A（渲染与标注的端到端效果由 T013 覆盖）

- [x] T013 [US2] 扩充 e2e 脚本的读取段，覆盖弹窗读取、无覆盖物、显式目标与截断、不可读属性、竞态、超时、runner 中途消失
  - files: [修改] scripts/e2e-ios-system.sh
  - symbols: N/A
  - tests: [修改] scripts/e2e-ios-system.sh
  - covers: TC-009, TC-010, TC-011, TC-012, TC-013, TC-014, TC-015

### Phase 2 门禁

- [x] [Gate] `swift build` 通过
- [x] [Gate] 运行 IosSystemCommandTests（UT）→ 回归 TC-028（30 tests / 4 suites passed）
- [x] [Gate] 真机执行 `scripts/e2e-ios-system.sh` 的 READ 段 → 验证 TC-011, TC-012, TC-015
  （**TC-009 / TC-010 转人工**：两者都要求特定的屏幕状态——前者需要一个系统弹窗正压着 app，后者需要确无弹窗。让冒烟脚本去驱动使用者手机上碰巧存在的真实弹窗是不可接受的，故列入脚本末尾 MANUAL 段，附判据。
  **TC-013 / TC-014 未覆盖**：竞态（读取瞬间界面消失）与超时上限在真机上无法稳定构造，留待后续以注入方式覆盖）

---

## Phase 3 — US3: 驱动另一个进程的界面

此 Phase 跨 Phase Gate：无（驱动能力的验收以 app 自身状态变化为证，只需 Phase 1 的连通与 Phase 2 的读取，二者均已完成）。

### 实现

- [x] T014 [US3] 在 runner 中实现按可操作项标签与按坐标两种派发方式，含目标不存在时列出实际存在项、坐标越界时拒绝
  - files: [新增] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerInput.swift, [修改] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerHTTPServer.swift
  - symbols: XCUICoordinate
  - tests: N/A（由 T017 的 E2E 覆盖）
  - covers: N/A

- [x] T015 [US3] 在 runner 中实现回到主屏与让指定 app 回到前台；后者必须用 activate 而非 launch，以免重启目标 app
  - files: [修改] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerInput.swift
  - symbols: XCUIDevice.press, XCUIApplication.activate
  - tests: N/A（由 T017 的 E2E 覆盖）
  - covers: N/A

- [x] T016 [US3] 在宿主侧实现驱动命令，记录动作经由哪条通道与作用进程，并在无观察到变化时如实报告「已下发但未观察到变化」
  - files: [修改] reticle-host/Sources/ReticleHostIos/IosSystemBackend.swift, [修改] reticle-host/Sources/ReticleHostCore/CLI/ReticleSystemCommands.swift
  - symbols: N/A
  - tests: [修改] reticle-host/Tests/ReticleHostCoreTests/IosSystemCommandTests.swift
  - covers: N/A（端到端效果由 T017 覆盖）

- [x] T017 [US3] 扩充 e2e 脚本的驱动段，以副作用为证据覆盖点弹窗、回主屏、回前台不重启、坐标手势、目标缺失、越界、空效果
  - files: [修改] scripts/e2e-ios-system.sh
  - symbols: N/A
  - tests: [修改] scripts/e2e-ios-system.sh
  - covers: TC-016, TC-017, TC-018, TC-019, TC-020, TC-021, TC-022

### Phase 3 门禁

- [x] [Gate] `swift build` 通过
- [x] [Gate] 真机执行 `scripts/e2e-ios-system.sh` 的 DRIVE 段 → 验证 TC-017, TC-018, TC-020, TC-021
  （**TC-016 转人工**：点系统弹窗的「允许」要求设备上正好有一个权限弹窗，且脚本不应去点使用者手机上碰巧存在的真实弹窗。
  **TC-019 / TC-022 转人工**：需要一块「已知无反应」的屏幕区域，因设备与当前界面而异。三条均已写入脚本 MANUAL 段并附判据）

---

## Phase 4 — US4: 显示级画面

此 Phase 跨 Phase Gate：有（TC-024 需要与既有 `ui screenshot` 对比，涉及两条通道协作，见跨 Phase Gate 节）。

### 实现

- [x] T018 [US4] 在 runner 中实现显示级截图端点
  - files: [修改] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerObservation.swift, [修改] reticle-runner-ios/Sources/ReticleRunnerTests/RunnerHTTPServer.swift
  - symbols: XCUIScreen
  - tests: N/A（由 T020 的 E2E 覆盖）
  - covers: N/A

- [x] T019 [US4] 在宿主侧实现截图命令，用既有的来源与降级两个字段标明取景范围，并在熄屏时说明屏幕未点亮而不返回纯黑图
  - files: [修改] reticle-host/Sources/ReticleHostIos/IosSystemBackend.swift, [修改] reticle-host/Sources/ReticleHostCore/CLI/ReticleSystemCommands.swift
  - symbols: ScreenshotResult.via, ScreenshotResult.degraded
  - tests: N/A（由 T020 覆盖）
  - covers: N/A

- [x] T020 [US4] 扩充 e2e 脚本的截图段，覆盖含弹窗的画面、熄屏说明，以及与进程内截图的来源对比
  - files: [修改] scripts/e2e-ios-system.sh
  - symbols: N/A
  - tests: [修改] scripts/e2e-ios-system.sh
  - covers: TC-023, TC-025

### Phase 4 门禁

- [ ] [Gate] `swift build` 通过
- [ ] [Gate] 真机执行 `scripts/e2e-ios-system.sh` 的 SHOT 段 → 验证 TC-023, TC-025

---

## Phase 5 — US5: 进程内够不到时的指引

此 Phase 跨 Phase Gate：无（文案改动的验证只需 system 通道处于不同状态，Phase 1 已提供）。

### 实现

- [x] T021 [US5] 修改进程外坐标的拒绝文案：补充两种可能（坐标不正确 / 目标在另一进程）、指引 system 通道，并区分「尚未安装」与「已安装但未连通」两种状态；拒绝行为本身不变
  - files: [修改] reticle-host/Sources/ReticleHostIos/IosTouchSurface.swift
  - symbols: IosTouchSurface.post
  - tests: [新增] reticle-host/Tests/ReticleHostCoreTests/IosOutOfWindowGuidanceTests.swift
  - covers: TC-027

- [x] T022 [US5] 在既有真机 e2e 脚本的坐标手势段补充拒绝文案断言，确认拒绝行为未因本次改动而变化
  - files: [修改] scripts/e2e-ios-device.sh
  - symbols: N/A
  - tests: [修改] scripts/e2e-ios-device.sh
  - covers: TC-026

### Phase 5 门禁

- [ ] [Gate] `swift build` 通过
- [ ] [Gate] 运行 IosOutOfWindowGuidanceTests（UT）→ 验证 TC-027
- [ ] [Gate] 真机执行 `scripts/e2e-ios-device.sh` 的 COORDINATE GESTURES 段 → 验证 TC-026

---

## Phase 6 — 边界与文档登记

### 实现

- [x] T023 [P] 更新跨平台边界表：进程内不可达的事实不变，补上 system 通道可达且它是另一条通道，并按四列格式登记本能力自身的新边界（无 DOM、无样式、无 regions、遍历开销）
  - files: [修改] docs/boundaries.md
  - symbols: N/A
  - tests: N/A
  - covers: N/A

- [x] T024 [P] 在 iOS 机制文档中补充本次实测细节：runner 拿到 backboardd HID 连接、独立启动的三行 syslog 证据、UI Automation 开关的伪装报错、iOS 26 上不可删内嵌 XC 框架
  - files: [修改] docs/ios.md
  - symbols: N/A
  - tests: N/A
  - covers: N/A

- [x] T025 [P] 在架构与命令文档中登记 system 命令族及其与 app 内通道的分工
  - files: [修改] docs/architecture.md, [修改] README.md, [修改] README.zh-CN.md
  - symbols: N/A
  - tests: N/A
  - covers: N/A

- [ ] T026 处置 spike 产物：将 sample-app-ios 下未提交的三个探针文件与 project.yml 改动，按其价值归入正式测试或移除，不把临时探针留在仓库里
  - files: [修改] sample-app-ios/xcode/project.yml, [修改] sample-app-ios/Tests/SampleAppUITests/
  - symbols: N/A
  - tests: N/A
  - covers: N/A

### Phase 6 门禁

- [x] [Gate] `python3 scripts/validate_architecture_map.py` 通过（含 --fix 同步 index.html 内嵌副本）；`validate_translations.py` 亦通过
- [ ] [Gate] 人工确认 boundaries 表新增行符合既有四列格式，且未与既有行冲突

---

## 跨 Phase Gate

- [ ] [Gate] 真机上对同一系统弹窗依次执行 `ui screenshot` 与 `system screenshot`，比对两者的来源与取景范围标注 → 验证 TC-024
  （编排依据：需要 app 内通道与 system 通道同时可用并对比输出，跨 Phase 1 与 Phase 4）
- [ ] [Gate] 真机完整执行 `scripts/e2e-ios-device.sh` 全流程 → 回归确认 linked-agent 路径的行为未因本次新增而改变
  （编排依据：回归范围覆盖 Phase 5 的文案改动与全部新增能力的共存影响，须在所有 Phase 完成后执行）
- [ ] [Gate] 真机运行 reticle-agent/ios 的 DeviceTouchTests → 回归确认私有触摸 surface 未受影响
  （编排依据：explore.md 变更影响分析列为必回归项；该测试是私有 surface 的 canary）

---

## TC 覆盖矩阵

| TC | 来源 | 测试文件 / 验证动作 |
|----|------|---------------------|
| TC-001 | US1-1 | scripts/e2e-ios-system.sh（PREPARE 段） |
| TC-002 | US1-2 | 真机手动（临时关闭设备端 Enable UI Automation） |
| TC-003 | US1-3 | scripts/e2e-ios-system.sh（PREPARE 段） |
| TC-004 | US1-4 | scripts/e2e-ios-system.sh（PREPARE 段） |
| TC-005 | US1-5 | scripts/e2e-ios-system.sh（PREPARE 段） |
| TC-006 | US1-6 | 真机手动（锁屏） |
| TC-007 | US1-7 | scripts/e2e-ios-system.sh（PREPARE 段） |
| TC-008 | US1-8 | scripts/e2e-ios-system.sh（PREPARE 段） |
| TC-009 | US2-1 | scripts/e2e-ios-system.sh（READ 段） |
| TC-010 | US2-2 | scripts/e2e-ios-system.sh（READ 段） |
| TC-011 | US2-3 | scripts/e2e-ios-system.sh（READ 段） |
| TC-012 | US2-4 | scripts/e2e-ios-system.sh（READ 段） |
| TC-013 | US2-5 | scripts/e2e-ios-system.sh（READ 段） |
| TC-014 | US2-6 | scripts/e2e-ios-system.sh（READ 段） |
| TC-015 | US2-7 | scripts/e2e-ios-system.sh（READ 段） |
| TC-016 | US3-1 | scripts/e2e-ios-system.sh（DRIVE 段） |
| TC-017 | US3-2 | scripts/e2e-ios-system.sh（DRIVE 段） |
| TC-018 | US3-3 | scripts/e2e-ios-system.sh（DRIVE 段） |
| TC-019 | US3-4 | scripts/e2e-ios-system.sh（DRIVE 段） |
| TC-020 | US3-5 | scripts/e2e-ios-system.sh（DRIVE 段） |
| TC-021 | US3-6 | scripts/e2e-ios-system.sh（DRIVE 段） |
| TC-022 | US3-7 | scripts/e2e-ios-system.sh（DRIVE 段） |
| TC-023 | US4-1 | scripts/e2e-ios-system.sh（SHOT 段） |
| TC-024 | US4-2 | 跨 Phase Gate（两条通道截图对比） |
| TC-025 | US4-3 | scripts/e2e-ios-system.sh（SHOT 段） |
| TC-026 | US5-1 | scripts/e2e-ios-device.sh（COORDINATE GESTURES 段） |
| TC-027 | US5-2 | IosOutOfWindowGuidanceTests（UT） |
| TC-028 | B线: system 命令平台准入 | IosSystemCommandTests（UT） |
| TC-029 | B线: 端口派生与隧道 | IosRunnerLifecycleTests（UT） |
| TC-030 | B线: SystemNode 类型映射 | SystemObservationTests（UT） |
| TC-031 | B线: 启动失败判别 | IosRunnerFailureTests（UT） |

**完整性检查**

1. **TC 全分配**：test-plan.md 共 31 条（TC-001..TC-031），矩阵覆盖 31 条，无遗漏。
2. **测试文件可追溯**：Gate 引用的测试载体逐一核对——
   - `SystemObservationTests` → T003 `tests: [新增]` ✓
   - `IosRunnerLifecycleTests` → T004 `[新增]` ✓
   - `IosRunnerFailureTests` → T005 `[新增]` ✓
   - `IosRunnerClientTests` → T006 `[新增]` ✓
   - `IosSystemCommandTests` → T008 `[新增]` ✓
   - `IosOutOfWindowGuidanceTests` → T021 `[新增]` ✓
   - `scripts/e2e-ios-system.sh` → T009 `[新增]` ✓
   - `scripts/e2e-ios-device.sh` → 代码库已存在（explore.md 已确认），T022 `[修改]` ✓
   - `DeviceTouchTests` → 代码库已存在（`reticle-agent/ios/Tests/ReticleKitTests/DeviceTouchTests.swift`），仅回归不改动 ✓

---

## Notes

- **MVP 范围**：Phase 1 + Phase 2（US1 + US2）。准备 + 读取即可回答「挡住我的是什么」，这是本通道最主要的价值；驱动能力可后续追加。
- **任务统计**：26 个任务。US1: 9、US2: 4、US3: 4、US4: 3、US5: 2、收尾: 4。可并行任务（标 [P]）：7 个。
- **T026 需要人工决策**：spike 三个探针文件的去留（正式化为测试资产还是移除）不宜由实现阶段自行决定，执行到此任务时应先与用户确认。
- **不可破坏的语义约束**（来自 explore.md 变更影响分析，实现时须遵守）：
  - 不改 `HostBackend` 协议、不改 `Node`、不扩 `NodeKind`
  - `ui screenshot` 既有的 `via` / `degraded` 取值不得改变
  - `IosTouchSurface` 的拒绝行为不得变成自动改道
  - runner 的前台化一律用 `activate`，禁止 `launch`
