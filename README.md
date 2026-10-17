# Meeting Mac

原生 macOS 会议与个人资料助手，参考 Foresight 布局与流程，融合 MAC-record 的音频能力。

## 最新完整规格 v0.7（待审阅）

- [完整产品 Spec](docs/spec/product-v0.7.md)
- [界面与交互](docs/spec/v0.7/界面与交互规格.md) · [Prompt 与生成契约](docs/spec/v0.7/提示词与生成契约.md)
- [实施 Plan](docs/spec/v0.7/实施Plan与交付门禁.md) · [架构与数据](docs/spec/v0.7/架构与数据契约.md)
- [完整资料包 ZIP](docs/spec/packages/Foresight-v0.7-complete-spec-public-20261017.zip) · [SHA256](docs/spec/packages/Foresight-v0.7-complete-spec-public-20261017.zip.sha256)
- [需求与验收索引](docs/spec/requirements-v0.7.json) · [文档校验报告](docs/spec/verification-v0.7.json)

含用户提供的两张 Foresight 原图、18 项功能要求、8 项非功能要求、12 项 UI 要求、38 项验收场景、20 项原始 Prompt 和12项中文任务契约。

默认设计为本地 SenseVoice ASR/VAD、Google EmbeddingGemma 文本检索、用户主动配置的 DeepSeek 生成；P1/P2 保留千问/FunASR、本地生成和完整工作流扩展。

当前仅发布规格资料，产品开发、模型下载、构建与安装暂停，待用户明确要求按本版执行。规格和文档校验不是应用完成或实机验收证明，当前仓库代码也不代表已经实现本规格。

公开版已遮蔽原始静态字符串中的4处疑似 Google API Key。原始 Prompt、截图和规格未改，详情见 [公开上传说明](docs/spec/v0.7/公开上传说明.md)。大型符号表与字符串集合在 ZIP 中完整保留其脱敏版本。

## 既有开发

此前的实现和验证状态见 `docs/implementation-status.json`（历史进度，不代表v0.7已实施）。模型权重、用户录音和账号凭据不入库；MAC-record参考源码保留其MIT归属。

