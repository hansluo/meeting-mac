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

当前仅有明确模型路由的基础实现，真实 ASR、生成服务和桌面工作流继续开发中。
