# Meeting Mac

以docs/spec/product-v0.3.md为完整产品目标。用户授权实现与提交到hansluo/meeting-mac，不能把首批基础功能当作完整产品。

使用原生SwiftUI桌面客户端与可测试的MeetingCore，ASR后端独立适配。模型权重不提交Git。凭据存Keychain，导出与日志不含Key。禁止失效模型默认选择列表第一项，禁止本地任务失败隐式上传云端。

每次迭代更新docs/implementation-status.json的真实证据和剩余工作。测试、构建、运行与人工验收分开标记，不凭模型名称声明能力。已有MAC-record源码可以适配，但必须保留MIT归属和修复已确认的融合缺口。

2026-10-15用户目标刷新：完整Foresight界面/功能和中文体验；内置并自动准备Google embedding与MAC-record默认SenseVoice INT8 ASR，默认DeepSeek云端生成。普通用户只填云API配置，不要求手动模型/Python/运行库路径。不得把短WAV工作台或模型下载说明当成最终交付。v0.2其余完整范围继续有效，默认冲突以v0.3为准。
