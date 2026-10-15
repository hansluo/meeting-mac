# Qwen 本机适配器验证

基础提交 `f5521ee`，修正提交 `86d5c71`。规格与质量审查通过。父任务重新运行 `scripts/test-core.sh`：47 项测试全部通过；`swift build` 成功。

实际 `.build/native` 动态库经 `MeetingASRCheck --runtime` 加载，返回 `runtimeVersion: 1.13.7` 和 `evidence: symbol-version-probe-only`。这没有初始化有效的模型，也没有识别语音。

受控坏模型测试调用实际 ONNX Runtime，返回退出码 1 与 `nativeFailure`，错误为 conv_frontend ONNX 的 Protobuf 解析失败。这个测试没有发生 signal/abort；它不能证明所有原生故障都能隔离。

测试覆盖模型文件/manifest校验、WAV/PCM边界、运行时版本和符号、并发busy、取消与资源释放。ABI假库只证明调用契约和异常处理，不作为真实识别证据。安装脚本用真实8MB归档验证了调用者相对路径，并确认错误SHA不替换已有安装。

耗时采用单调时钟。当前引擎每任务加载并销毁recognizer，属于离线识别基础；录音session常驻模型、实时VAD、长文件分块和应用接线还未实现。原生调用本身不可中断，取消等待调用结束和清理。

真实checkpoint权重仍在下载；成功转写、CER/WER、延迟、内存和离线网络场景尚未验收。FR-001/014/015及整体产品均保持未完成。
