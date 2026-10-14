# Active goal — user revision 2026-10-15

开发完整 Meeting Mac 并提交 https://github.com/hansluo/meeting-mac 。以 `docs/spec/product-v0.3.md` 为当前权威范围，v0.2需求身份和未被覆盖的全部功能继续有效。

用户目标：Foresight式完整界面和功能，中文可用；本地 Google embedding 与 MAC-record 路线 Qwen ASR 由开发方下载、校验、集成，普通用户不配置路径或Python；对话、资料整理、会议纪要Prompt模板等默认DeepSeek云端，地址/模型预填、用户填自己的Key。可选FunASR及本地生成保留高级入口。

成功必须包括：默认模型正常准备且真实可用、麦克风/系统/双来源录音、转写/回放/重转录、资料索引/引用问答、会议纪要/行动项/笔记、备会/历史/同步/语音输入及原spec完整验收。界面中文且参考Foresight整体流程，不以短WAV工作台、CLI、下载脚本或绿测试代替最终产品。

云Key不写入源码/导出/日志，不从其他应用私自提取。缺Key期间完成所有可独立推进的开发；真实云调用由用户在成品设置中填写Key后验证。ASR与embedding保持本机，云生成只发送任务所需文本和检索片段；原音频不自动上传。

目标仍未完成。实现/构建/运行/人工交互验收分别记录到 `docs/implementation-status.json`。
