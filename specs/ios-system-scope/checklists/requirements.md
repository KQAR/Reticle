# Specification Quality Checklist: iOS 真机 system scope

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-11
**Feature**: [spec.md](../spec.md)
**Iteration**: 2/3（Iteration 2 = clarify 一轮后复核）

> **审查方式说明**：本次质量验证由主 agent 自审完成，未启动独立只读审查 agent（用户环境明确约束不使用 subagent）。自写自审存在偏差风险，人工复核时请优先关注下方标注为「自审时修正」的两项，以及 US4 / US5 的粒度判断。

---

## Overall Spec Quality

- [x] Spec 聚焦 WHAT/WHY，未泄漏 HOW（语言、框架、API、数据库、代码结构等实现细节）
- [x] Spec 面向业务干系人可读，表达清晰、可测试、无歧义
- [x] 必填章节已完成，功能范围、依赖和假设已清晰界定

## User Story Quality

- [x] 所有 User Story 均有明确用户目标，并覆盖主要用户路径
- [x] 所有 User Story 尽可能处于同等粒度层级
- [x] 横切 User Story 有独立用户目标和独立验收条件；否则已归入 NFR 或对应 Story
- [x] 每个 User Story 均包含 Acceptance Scenarios（Given/When/Then）

## Acceptance Scenario Quality

- [x] Acceptance Scenario 按独立用户路径/分支拆分；同一路径上的时间线观察已合并到同一 Scenario
- [x] 每条 Acceptance Scenario 自包含，QA 可独立执行，不依赖其他 Scenario 的上下文
- [x] Scenario 只描述用户可验证的行为和结果，不包含 UI 实现细节
- [x] 已检查运行中、完成后、失败后是否遗漏可独立验证的用户路径

## Edge Case Quality

- [x] Edge Case 归属到对应 User Story，覆盖该 Story 特有的边界输入、错误场景、并发场景或系统极端状态
- [x] Edge Case 未混入主流程的另一条用户选择分支
- [x] Edge Case 未混入「正常情况下也应该如此」的泛化陈述
- [x] 「不做什么」的设计决策或质量约束未写入 Edge Case，已归入 NFR 或 Out of Scope

## Implicit Constraint Quality

- [x] 已按需检查口径清晰度
- [x] 已按需检查作用域
- [x] 已按需检查边界与状态语义
- [x] 已明确的隐式约束已落到相关 User Story、Acceptance Scenario、Edge Case、NFR 或 Out of Scope

## Numbering And References

- [x] 所有 Acceptance Scenario 和 Edge Case 均有唯一编号（US{N}-{M}，同一 Story 内连续编号）
- [x] 进入质量验证前没有遗留 `Unclear Questions`
- [x] 外部上下文：用户未提供设计稿 / 接口文档 / PRD / 截图链接，故未创建 `external-references.md`

---

## Validation Notes

| 检查项 | 状态 | 证据 | 问题描述 | 修复建议 |
| ------ | ---- | ---- | -------- | -------- |
| Edge Case 未混入作用域说明 | ✅ 自审时修正 | 原 US2-5 | 原 US2-5「目标界面内含网页内容时…」写的是通道作用域限制，不是异常场景；且与 Out of Scope 中「不通过 system 通道读取网页结构与样式」重复。系统层界面本身也不会内含网页内容，场景错位 | 已删除该条，原 US2-6 顺延为 US2-5；作用域说明保留在 Out of Scope |
| 口径清晰度：「系统层界面」定义 | ✅ 自审时修正 | 背景与定界 | 全文反复使用「系统层界面」但未定义其外延，读者无法判断目标 app 自身界面是否属于此列 | 已在「背景与定界」补充定义：指当前显示在屏幕上、但不属于目标 app 的界面；并指明目标 app 自身界面仍走 app 内通道 |
| US4 / US5 粒度 | ⚠️ 保留待人工确认 | US4、US5 | 两者的验收面小于 US1–US3，存在归入 NFR 的可能 | 判断保留：US4 有独立触发入口（请求画面）与独立验收（取景范围可区分）；US5 有独立触发入口（进程内坐标动作失败）与独立验收（错误信息内容）。删掉任一条会使对应用户路径无处验证，故未归并 |
| NFR-004 含实测数字 | ✅ | NFR-004 | 「分钟级」为实测结论，作为约束成立理由出现，非实现细节 | 保留 |

---

## Iteration History

### Iteration 1

- **Date**: 2026-08-11
- **Issues Found**: 2（均已修复）
- **Status**: 通过（自审；建议人工复核 US4 / US5 粒度判断）

### Iteration 2（clarify 后复核）

- **Date**: 2026-08-11
- **Issues Found**: 4 处歧义（均已澄清并落地）
- **Status**: 通过

clarify 一轮补上的四处，及其落地位置：

| 歧义 | 结论 | 落地位置 |
| ---- | ---- | -------- |
| 默认读取范围未定义（NFR-004 禁止全遍历，但没说默认读多少） | 默认只读最上层覆盖物；更大范围须显式指定且仍受上限约束 | 背景（定义「最上层覆盖物」）、US2-1、新增 US2-3、NFR-004 |
| runner 用完后的归属未定义 | 常驻 + 显式停止命令；常驻事实必须对使用者可见 | 新增 US1-4（停止路径）、US1-8、新增 NFR-010 |
| 「就绪」未定义，US1-1 与 US5-2 用词相同但语义可能不同 | 拆成「已安装」/「已连通」两个状态，因两者的修复动作不同 | 背景（定义两状态）、US1-1、US5-2 |
| runner 中途死亡完全没写 | 自动重启一次并**必须声明发生过重启**（重启会打断前台状态，是可观察干扰） | 新增 US2-7、新增 NFR-011 |

复核项：

- [x] 编号连续无重复（US1-1..8、US2-1..7、US3-1..7、US4-1..3、US5-1..2）
- [x] 新增内容未引入与原文矛盾的陈述；US1 标题已随「收摊」路径更新
- [x] 未新增多余章节；澄清全部落到既有章节
- [x] 术语一致：全文统一使用「已安装」/「已连通」/「最上层覆盖物」/「system 通道」/「app 内通道」
- [x] `Unclear Questions` 仍为空
