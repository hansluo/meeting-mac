# RAG 描述符提取与独立复核

两份脚本仅使用 Python 标准库，读取已安装程序的 tar 资源成员，不运行目标、不联网、不安装依赖，不输出 Helper 可执行文件副本。

```sh
python3 '05-证据与复现/extract-rag-descriptor.py' --output /tmp/foresight-descriptor-reproduction
python3 '05-证据与复现/verify-rag-descriptor.py' --reproduced /tmp/foresight-descriptor-reproduction
```

在交付包根目录运行。第一份脚本默认读取 `/Applications/Foresight.app/Contents/Resources/ForesightHelper_tar.tar` 内的 `research/xeno/labs/foresight/launch_agent/ForesightHelper`。可用 `--app` 指定 app 路径，或 `--helper` 指定已解包 Helper。读取内容先验证完整 SHA-256 为 `c96e3fbbd5769932dc5dac04b95a185af06f9e40eb2b51a7168841b7c69c1a0e`；其他构建拒绝继续。

描述符起点是 Helper 字节偏移 `0x3138698`，长度 3578，结束偏移（不包含）`0x3139492`。描述符 SHA-256 为 `cfe21cde2beef249413a8fb90ea4de10e4ffc1e8ab438ca4a5cc6e794f84446a`。第一份脚本重生成原始描述符、结构化 JSON 和可读 proto。

第二份脚本使用独立 BytesIO wire reader，逐层消费 descriptor/message/field/service/method 记录到末尾。已核对全部 22 个消息、45 个字段的名称/编号/标量类型/引用类型/repeated/oneof，以及 11 个 RPC 的名称、输入、输出、streaming。消息名、每个消息的字段名/编号、RPC 名均无重复，JSON 无漏项。已核对已安装 tar 成员、交付描述符和复现描述符字节完全相同，并核对复现 proto 与交付文本相同。337 个结构 wire 记录被消费，结果见 `rag-descriptor-verification.json`。

edition 原值为 1001。可读 proto 曾误标为 2023，现已依据[官方 descriptor 定义](https://raw.githubusercontent.com/protocolbuffers/protobuf/main/src/google/protobuf/descriptor.proto)修正为 `edition = "2024"`。官方定义 `EDITION_2023 = 1000`、`EDITION_2024 = 1001`。原始描述符始终保存数值 1001。

可读 proto 是简化重建，没有重建 custom options、注释和未知语义，不保证与原作者源码相同；未执行 protoc 编译验证。原始 `.bin` 是精确提取，可读 `.proto` 不替代它。
