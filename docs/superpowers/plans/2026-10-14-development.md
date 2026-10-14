# Meeting Mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task, with spec and quality reviews. Steps use checkbox syntax.

**Goal:** 实现完整v0.2产品并提交hansluo/meeting-mac，不把本计划的首个任务当成目标完成。

**Architecture:** Swift Package包含可测试MeetingCore与SwiftUI客户端。原生音频和Qwen ONNX适配MAC-record；FunASR独立本地worker。资料/会议版本层连接ASR、RAG和按任务生成路由。

**Tech Stack:** Swift 6、SwiftUI/AppKit、AVFoundation、ScreenCaptureKit、SQLite、Security、Python/FunASR与sherpa-onnx。

## 全范围执行顺序

- [ ] 模型profile、明确任务路由、执行位置与能力验证。
- [ ] 生成HTTP/SSE客户端、Keychain、探测、token预算、取消与错误。
- [ ] Qwen ONNX依赖和本机adapter，FunASR worker与文件/实时契约。
- [ ] 原生桌面模型设置和基础导航；可运行.app与构建脚本。
- [ ] 持久化的来源、片段、会议、任务与revision。
- [ ] 双来源录音、原音频保全、ASR事件、重转录和回放。
- [ ] 文件摄取、embedding、检索、引用和删除一致性。
- [ ] 问答、纪要、行动项、笔记增强、导出。
- [ ] 日程/资料同步、语音输入、说话人管线。
- [ ] 检测/sidecar及知识组织，多模态按能力启用。
- [ ] 真实运行、质量/性能基准、全需求完成审计与交付。

以上全范围每个子系统继续写细化实现任务；没有明细或证据的需求保持未完成。

## Task 1: Swift工程与明确路由核心

**Files:** Package.swift、Sources/MeetingCore/ModelProfile.swift、Sources/MeetingCore/RouteResolver.swift、Tests/MeetingCoreTests/RouteResolverTests.swift。

- [ ] 新建SwiftPM库与测试目标，平台macOS14，客户端另立可执行目标。
- [ ] 先写失败测试：缺active profile不得选first；local-only不能选cloud/lan/unverified；ASR任务不能选LLM；未验证能力不得ready；明确允许cloud只能影响该任务；支持本机已验证profile的正常路由。
- [ ] `swift test --filter RouteResolverTests`观察缺失路由行为，再实现。
- [ ] 类型包含ModelKind、ExecutionLocation、TaskRole、ProviderProfile、TaskRoute和RouteError。显式profileID、modelID、verified location与任务能力；不默认兜底，不发网络。
- [ ] 实现`RouteResolver.resolve(task:route:profiles:) throws -> ProviderProfile`，通过上述行为测试，支持Codable与Sendable。
- [ ] 再做spec review和code quality review；修正后重新运行测试与`swift build`。
- [ ] 提交基础模块与验证证据，更新FR-001/013/017为部分实现；实际服务探测与模型运行仍未完成。

## Task 2: 文本生成传输

在Task1接口稳定后细化：profile级URL/鉴权、同模型窗口、SSE、first-token/idle/total超时、取消与finish_reason、Keychain原子更新。使用本地测试HTTP服务器做真实传输测试，禁止只测mock拼接。

## 完成审计

18项FR、8项NFR及各AC全部列于implementation-status.json。每项保存代码、单元/集成测试、真实场景验证与缺口。真实ASR、云route、系统权限、双轨、引用/删除、同步、语音输入和主动触发等没有证据时不标完成。
