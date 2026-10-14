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

- [x] 新建SwiftPM库与测试目标，平台macOS14，客户端另立可执行目标。
- [x] 先写失败测试：缺active profile不得选first；local-only不能选cloud/lan/unverified；ASR任务不能选LLM；未验证能力不得ready；明确允许cloud只能影响该任务；支持本机已验证profile的正常路由。
- [x] `swift test --filter RouteResolverTests`观察缺失路由行为，再实现。
- [x] 类型包含ModelKind、ExecutionLocation、TaskRole、ProviderProfile、TaskRoute和RouteError。显式profileID、modelID、verified location与任务能力；不默认兜底，不发网络。
- [x] 实现`RouteResolver.resolve(task:route:profiles:) throws -> ProviderProfile`，通过上述行为测试，支持Codable与Sendable。
- [x] 再做spec review和code quality review；修正后重新运行测试与`swift build`。
- [x] 提交基础模块与验证证据，更新FR-001/013/017为部分实现；实际服务探测与模型运行仍未完成。

## Task 2: 文本生成传输

在Task1接口稳定后细化：profile级URL/鉴权、同模型窗口、SSE、first-token/idle/total超时、取消与finish_reason、Keychain原子更新。使用本地测试HTTP服务器做真实传输测试，禁止只测mock拼接。

### Task 2A: 兼容接口与真实HTTP行为

**Files:** Sources/MeetingCore/ChatClient.swift、Tests/MeetingCoreTests/ChatClientTests.swift、Tests/Fixtures/chat_server.py。

- [x] RED：真实loopback HTTP服务器记录请求。验证自定义前缀、已有/v1、根URL、Bearer、明确model/messages、401/429/500、空choices、无models接口但生成可用、取消和模型列表。
- [x] `ChatEndpoint`仅允许http/https，无URL内嵌凭据/query/fragment；base URL保持完整前缀，已有/v1不重复，根URL默认补/v1。可显式选择API路径，支持原生Ollama/api/tags发现与兼容/v1/models，发现失败不得阻止手动模型生成。
- [x] `ChatClient`使用URLSession，提供discover与非流式generate；typed HTTP/响应/取消错误，不在错误中泄露服务正文或凭据。生成必须由RouteResolver验证所选任务/profile，并保持实际model ID；无默认first/备用provider。关闭自动redirect，防止本机地址意外重定向到外部；on_device HTTP仅允许loopback host，实际代理云仍由后续位置验证处理。
- [x] 标准payload含model/messages/stream=false与可选max_tokens/temperature。测试/正式请求使用同一生成入口。provider私有参数暂不发送，thinking/tools/JSON/SSE由后续能力适配独立实现。
- [x] loopback服务器测试读真实socket和JSON，随机本机端口，清理子进程，不访问用户模型、不发送外网。
- [x] spec review、quality review、构建与测试后提交。FR-013/017仍为partial。

### Task 2B: 流式、取消与预算

在2A后实现SSE字节/行事件、finish reason、有界响应与token/first-token/idle/total预算；真实socket测试分片、多行/UTF8、断线与取消。未知context不借用其他模型metadata。

### Task 2C: 凭据与能力探测

Security Keychain更新失败保留旧凭据/配置；临时Key测试不先保存。按task/profile/config revision记录探测证据，修改失效。能力和执行位置分别验证；本地代理云不能标本机。

## Task 3A: Qwen 本机 ASR 与真实运行入口

为优先验证用户要求的 ASR 替换，2A完成后先推进本机适配器；2B/2C仍保留为必须完成的后续工作。

**Files:** Sources/CSherpaBridge/、Sources/MeetingCore/QwenASREngine.swift、Sources/MeetingASRCheck/、Tests/MeetingCoreTests/QwenASREngineTests.swift、scripts/setup-sherpa.sh、ThirdParty/sherpa-onnx/、Package.swift。

- [x] 固定官方 sherpa-onnx v1.13.7 头文件与 Apache LICENSE；运行时动态下载与 SHA-256 核验，不提交 dylib 或权重。不依赖临时路径，运行时安装到被忽略的 `.build/native/`。
- [x] C bridge 用固定头文件构建，动态加载与版本核验，缺库/符号/不匹配返回可解释错误。Qwen config零初始化，仅设置本模型族；CPU推理、有界线程、长度，销毁所有stream/result/recognizer/dlopen资源。
- [x] Swift层显式路径/模型revision、有限PCM输入、sample rate、非空/有效数值、文件清单校验；异步串行处理，不在主线程进行模型初始化/解码。缺失文件不得运行或标ready；取消明确定义，native单段不能抢断时说明限制。
- [x] 输出记录原ASR文本、model/runtime及推理耗时；没有对齐能力时不捏造词级时间。VAD片段、热词、对齐、分离及长文件分块另有后续任务。
- [x] TDD测试缺库、错模型/缺文件、非法采样/PCM、有界输入、取消与生命周期；实际库版本探针另验。受控假库只用于异常接口行为，不当成实际ASR成功证据。
- [x] `MeetingASRCheck`可执行入口接受本机runtime/model/WAV路径，用授权合成音频做真实转写，保存配置、耗时与原始输出证据。已验证官方完整archive SHA并完成三语言短合成音频CLI转写；长会议与质量验收仍待完成。
- [x] spec、quality review和build/test后提交；FR-014仍partial，最终Qwen/FunASR同音频对照和App接线不能省略。

## Task 3B: FunASR 本地工作进程

固定独立 Python 环境、具体 checkpoint/revision与管线；进程消息有session/job/cancel身份，有界队列，文件/分段/原生流式能力分开。实际Mac CPU转写与失败恢复验证后才标能力通过。模型下载、输出时间和说话人能力不得从工具包名称推断。

- [x] 私有NDJSON管道，固定协议version/job ID和worker generation，有界响应及启动/请求超时；单个正在执行任务，不无限排队。
- [x] 成功任务复用同一worker与已加载模型；取消/超时/崩溃清理并reap自己的进程，下个任务可重启相同配置，不换模型。
- [x] 本机显式模型目录与revision，CPU FunASR backend，关闭运行时自动更新/下载与remote_code，库日志不污染IPC或泄露正文。
- [x] 初始严格PCM16/16k/mono批处理合同，保留raw/display文本；流式、热词、词对齐和分离逐checkpoint另验证，不宣称默认具备。
- [x] 独立环境和固定hash依赖；实际工具包CPU/import探测与真实转写验收分开。
- [x] Python后端单元测试及Swift真实pipe测试包含连续复用、取消后新PID、错误身份、坏消息、启动和请求超时、崩溃/清理。
- [x] spec/quality review后提交，FR-014及本机模型验收仍保留未完工作。

## Task 3C1: Qwen 常驻引擎核心

- [x] 同一引擎成功任务复用recognizer，stream/result每段独立释放，单任务有界。
- [x] shutdown取消并等待native返回后释放，之后按同配置重载；失败/取消使缓存失效。强所有权保护并发与deinit。
- [x] 每段检查size/mtime/resolved path，可信SHA仅coldload；可选复用/阶段耗时兼容旧Codable。
- [x] TDD、独立spec/quality审查、66/66测试；真实checkpoint同引擎复用与关闭后重载通过。证据见2026-10-15-real-asr-smoke.md。

## Task 3C2: 实时 ASR 分段与采集编排〔未完成〕

Qwen在录音session边界清理；FunASR复用worker，真正流式checkpoint的cache按session隔离。VAD/分段、音频时间范围、有限队列、迟到修复与原音频保存仍须实现与验收。常驻短文件解码并不等于实时会议录音闭环。

## Task 4A: 可运行的原生文件转写桌面入口

Task3C1独立spec/quality审查后实施。先让用户能在原生窗口选择本机引擎和短WAV、看到真实转写、取消及导出；完整会议/知识/长文件能力仍是后续必要任务。

**Files:** Package.swift、Sources/MeetingMacApp/、scripts/build-app.sh；必要的可测状态逻辑放MeetingCore及Tests。

- [ ] SwiftUI macOS14可执行目标与.app打包脚本，Info.plist/唯一bundle ID，无需接受Xcode license或改系统工具链。不打包模型权重、Python环境、API Key。不依赖/private/tmp路径。
- [ ] 转写界面选择Qwen/FunASR，显式本机runtime/model/revision或Python/worker/checkpoint；保存非敏感路径与选项。模型未配置显示可操作原因，不用假成功/样本文字。
- [ ] 文件选择仅承诺已实现的PCM16/16k/mono WAV≤30秒；显示所选文件、进行中、错误、取消、真实文本与来源。后续长文件/转换另有任务。原文可复制和导出UTF8，成功结果不因下一次失败消失。静音导致空转写时明确显示未识别到语音，不伪造文本。
- [ ] 单任务、重复点击有界，参数变更不改变活动任务，取消及关闭窗口清理原生/worker；UI不阻塞主线程；Qwen先await shutdown再释放。
- [ ] 引擎路由显式，无first默认模型、无云回退；FunASR后台与Qwen能力说明分开，不能把文件转写标为原生流式或会议已完成。
- [ ] 测试可测状态：开始/失败保留旧结果、取消禁止迟到结果、活动任务配置snapshot、busy与清理。脚本构建.app后实际启动、检查进程和原生界面，使用合成WAV跑一条真实Qwen路径。
- [ ] spec/quality审查，更新真实实现状态并提交；会议录音、LLM连接UI、资料问答等缺口继续保留。

## 完成审计

18项FR、8项NFR及各AC全部列于implementation-status.json。每项保存代码、单元/集成测试、真实场景验证与缺口。真实ASR、云route、系统权限、双轨、引用/删除、同步、语音输入和主动触发等没有证据时不标完成。
