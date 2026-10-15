# Qwen ASR 原生运行时准备

2026-10-14，在当前 Apple Silicon Mac 上检查 sherpa-onnx v1.13.7 的官方 ARM64 shared no-TTS 发行包。

- 官方来源：https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.7
- 资产：`sherpa-onnx-v1.13.7-osx-arm64-shared-no-tts-lib.tar.bz2`
- 下载文件 SHA-256：`b3a5484f071094d3a922062e6793aca3e0ccc7388bfa5797959fa51fabffc906`。已与官方 release API 的资产 digest 一致核对；这不是独立签名认证。
- 包内包含 C/C++ API 和 ONNX Runtime 动态库，不含模型权重或 C 头文件。
- 对应 tag 的 `sherpa-onnx/c-api/c-api.h` 有 `SherpaOnnxOfflineQwen3ASRModelConfig`，需要固定匹配版本，不能套用其他版本的结构体布局。
- 本机通过动态加载成功打开 C API dylib；确认 create recognizer/stream、decode、result 和 destroy 五个接口可解析。
- C API dylib SHA-256：`ab52d37d6452fd18cfe6398cd5a150695c28da089dd38c1c768986426e06e017`。
- 实际加载库返回 sherpa-onnx `1.13.7`、ONNX Runtime `1.28.1`。
- 固定版本 C 头文件 SHA-256：`426db2c6acfb51e02143aece67c45779fae699d961c7c26ccf6f1388fdeaa2df`；对应上游 LICENSE 已获取，后续适配时一并保留。

这仅证明原生依赖能在当前 Mac 加载。尚未创建带真实权重的识别器，没有 ASR 文本、质量或性能证据。模型文件校验、Swift/C 适配器、VAD、时间映射、资源限制以及应用内打包仍待实现。下载文件暂存于系统临时目录，不作为项目长期依赖，也不提交 Git。

## 0.6B 权重来源核验

GitHub 官方 `asr-models` release API 返回以下已存在资产，修正 MAC-record 配置中的 2025 年链接。

- 名称：`sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2`
- 来源：https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2
- 大小：878,702,423 bytes。
- 上游 API digest：`sha256:393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96`。

下载进行中；必须完整下载并核对摘要才能解压/使用。此处没有将模型标为下载完成或识别就绪。
