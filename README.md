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

运行 `scripts/build-app.sh` 生成 `dist/Meeting Mac.app`。当前入口支持显式配置本机 Qwen / FunASR、选择不超过30秒的 PCM16/16kHz/单声道 WAV、转写、取消、复制与文本导出。模型、sherpa dylib 和 Python 环境保持外置；设置保存路径与用户声明的模型版本，不保存凭据。首次使用需在“模型设置”选择实际文件位置。

已验证应用启动、原生窗口控件、生产转写适配流程和任务状态测试。界面自动化连接故障使文件选择、复制、导出、关闭等完整点击验收仍待补全，不能把源码存在当作这些交互已通过。每次文件任务后当前释放模型，桌面入口暂未复用常驻引擎。

这是一份过渡开发版；v0.3最终版本将自动管理默认本地模型，不再要求上述手动路径。完整模型连接/Keychain、会议录音、长文件、历史、知识库、引用问答与其余 v0.2 工作流继续实现。
