# Meeting Mac

最新要求：先审阅完整产品Spec v0.7；本次只授权上传规格和资料到GitHub，不恢复产品开发。当前基线为docs/spec/product-v0.7.md，状态为待审阅、implementation_authorized=false。暂停产品代码修改、模型下载、构建、安装及实机验收，保留未完成工作，等待用户明确执行。旧文档的执行授权不覆盖这一要求。

采用Foresight用户截图布局；默认SenseVoice/VAD、Google embedding及可选DeepSeek生成，P0/P1/P2完整范围详见spec。规格要求和文档校验不得当作实现或应用验收证明。

使用原生SwiftUI/AppKit客户端与可测试MeetingCore，ASR后端独立适配。模型权重不提交Git。凭据存Keychain，导出与日志不含Key。禁止失效模型选择列表第一项，禁止本地任务失败隐式上传云端。

测试、构建、运行与人工验收分开记录；保留MAC-record MIT归属。公开静态证据中的疑似凭据须脱敏，保留脱敏范围和原件hash适用边界，原始业务Prompt及其独立hash保持不变。

