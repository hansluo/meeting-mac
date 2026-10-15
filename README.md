# Meeting Mac

原生macOS会议与个人知识助手，基于Foresight产品流程和Hans的MAC-record构建。

开发目标是内置并自动准备Google EmbeddingGemma和MAC-record默认SenseVoice INT8 ASR，默认DeepSeek云端生成（用户填写API Key），保留FunASR/本地生成高级选项、双来源会议、音频重转录、个人资料RAG、引用、笔记增强、行动项、备会和主动助手。

目前正在开发，未完成的功能和验证状态见 `docs/implementation-status.json`。模型注册、代码编译和模拟测试不能替代真实ASR/模型运行与完整验收。

当前产品基线：`docs/spec/product-v0.3.md`；需求与验收：`docs/spec/requirements-v0.3.json`。

本地代码仓库：`https://github.com/hansluo/meeting-mac`。

## 开发验证

当前基础模块可使用 `swift build` 构建，`scripts/test-core.sh` 运行测试。
若系统选用 Command Line Tools，脚本使用已安装 Xcode 的 XCTest 框架；不会修改系统开发工具选择或许可证状态。
可通过 `MEETING_XCODE_DEVELOPER_DIR` 指定其他 Xcode 的 `Contents/Developer` 路径。

当前已实现明确模型路由、兼容生成接口的 HTTP 基础层、Qwen 本机 ONNX adapter 和 FunASR 常驻 CPU worker。Qwen / FunASR 已用同一组三语言短合成音频完成真实转写，证据与限制见 `docs/verification/2026-10-15-real-asr-smoke.md`。这不代表长会议、原生流式、真实模型生成服务或桌面工作流已验收。

实际本地 Qwen 生成的短请求也已通过正式 ChatClient；采用受控 llama-server 与独立权重，测试后服务已停止。具体模型与限制见 `docs/verification/2026-10-15-local-qwen-generation.md`，不代表所有本地服务或长会议总结已验收。

## 本机 ASR 开发入口

- Qwen runtime：`scripts/setup-sherpa.sh` 校验官方固定版本后安装到 `.build/native/`。
- FunASR 环境：`scripts/setup-funasr.sh` 创建独立 `.venv/funasr`；详细管道配置见 `Runtime/FunASR/README.md`。
- 模型需另行下载并核对版本与摘要，放在被忽略的 `models/` 或显式本机目录；不提交权重和环境。
- Qwen CLI：`swift run MeetingASRCheck --runtime <绝对dylib路径> --model <模型目录> --wav <PCM16/16k/mono WAV> --revision <固定版本>`。可加 `--manifest <JSON路径>` 校验六份必需模型文件。实际用于长文件前仍需分块、音频转换和版本层。

## 原生桌面开发版

运行 `scripts/build-app.sh` 生成 `dist/Meeting Mac.app`。默认构建包含已校验的 Google EmbeddingGemma300M、SenseVoice INT8 及原生运行库和许可文件。首次打开自动准备到此 Mac 的应用数据目录；普通用户无需填写模型或 Python 路径。缺失或损坏的内置资源会通过固定下载来源重新获取并校验，失败或取消保留已有有效版本。

当前支持默认 SenseVoice 本地短 WAV 转写，Qwen/FunASR 手动路径保留在高级设置。不超过30秒的 PCM16/16kHz/单声道 WAV 可导入、转写、取消、复制和导出。数字全零静音会在模型调用前返回未识别到语音；一般噪声、长文件和实时录音仍待实现。每次文件任务后释放 ASR 模型，尚未在桌面入口复用常驻引擎。

157项核心测试通过，完整默认应用包构建、清单和签名通过。实际包内资源安装、官方归档经真实HTTP下载/校验/展开及生产转写均已验证；原生界面已完成默认就绪、选音频、转写、保存导出和导出字节核对。设置面板点击再次触发界面自动化连接故障，设置/取消/复制内容等完整点击验收仍有缺口。详见 `docs/verification/managed-defaults-smoke-20261015.json`。

这是持续开发版。本地向量服务核心已完成并用真实Google模型验证中文排序、连续调用和清理；资料持久化、版本索引和范围检索核心也已接通，原生资料库界面尚未接入；DeepSeek设置与真实云调用、会议录音、长文件、历史、知识库、引用问答和其余完整v0.3工作流继续实现。开发者构建需先准备清单中固定版本的资源到忽略目录；权重、运行库二进制和凭据不提交到Git。

受控向量服务与客户端实测见 `docs/verification/managed-embedding-service-smoke-20261015.json`。它只说明默认模型的正式调用已工作，不能代替资料索引、引用问答和整套检索质量验收。

资料层已通过真实默认模型与TXT/Markdown/PDF合成资料的持久化、更新、重开和范围检索验证，详见 `docs/verification/source-index-production-smoke-20261015.json`。这仍是核心接口验收；原生资料库和带引用的生成式问答继续实现。
