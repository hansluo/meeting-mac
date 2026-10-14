# Meeting Mac

原生macOS会议与个人知识助手，基于Foresight产品流程和Hans的MAC-record构建。

开发目标是可切换Qwen/FunASR转写、本地千问及可选云生成、双来源会议、音频重转录、个人资料RAG、引用、笔记增强、行动项、备会和主动助手。

目前正在开发，未完成的功能和验证状态见 `docs/implementation-status.json`。模型注册、代码编译和模拟测试不能替代真实ASR/模型运行与完整验收。

当前产品基线：`docs/spec/product-v0.2.md`；需求与验收：`docs/spec/requirements-v0.2.json`。

本地代码仓库：`https://github.com/hansluo/meeting-mac`。

## 开发验证

当前基础模块可使用 `swift build` 构建，`scripts/test-core.sh` 运行测试。
若系统选用 Command Line Tools，脚本使用已安装 Xcode 的 XCTest 框架；不会修改系统开发工具选择或许可证状态。
可通过 `MEETING_XCODE_DEVELOPER_DIR` 指定其他 Xcode 的 `Contents/Developer` 路径。

当前已实现明确模型路由、兼容生成接口的 HTTP 基础层、Qwen 本机 ONNX adapter 和 FunASR 常驻 CPU worker。Qwen / FunASR 已用同一组三语言短合成音频完成真实转写，证据与限制见 `docs/verification/2026-10-15-real-asr-smoke.md`。这不代表长会议、原生流式、真实模型生成服务或桌面工作流已验收。

## 本机 ASR 开发入口

- Qwen runtime：`scripts/setup-sherpa.sh` 校验官方固定版本后安装到 `.build/native/`。
- FunASR 环境：`scripts/setup-funasr.sh` 创建独立 `.venv/funasr`；详细管道配置见 `Runtime/FunASR/README.md`。
- 模型需另行下载并核对版本与摘要，放在被忽略的 `models/` 或显式本机目录；不提交权重和环境。
- Qwen CLI：`swift run MeetingASRCheck --runtime <绝对dylib路径> --model <模型目录> --wav <PCM16/16k/mono WAV> --revision <固定版本>`。可加 `--manifest <JSON路径>` 校验六份必需模型文件。实际用于长文件前仍需分块、音频转换和版本层。

当前没有可交付的桌面 `.app`。完整模型设置、会议录音、知识库、引用问答与其余 v0.2 工作流继续实现。
