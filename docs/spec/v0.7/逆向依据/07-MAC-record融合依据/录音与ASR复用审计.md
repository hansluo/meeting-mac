# MAC-record 录音与 ASR 复用审计

结论：**Foresight 继续作为产品主线，MAC-record 可复用录音、音频增强、Qwen 离线识别封装、文件转录与语音输入流程。FunASR 需要新增适配器。现有“实时”是 VAD 分段后调用 offline decoder，不是真正逐帧保留解码状态的 streaming decoder。现有录音入口是麦克风与系统音频二选一，不能直接承诺双轨同步录音。**

范围为只读 `/private/tmp/mac-record-spec-20261014` 选择性源码快照，已校验仓库 `hansluo/MAC-record`、commit `ad53c5740e59498d6c9869c04027c2daddd1b48d`。没有构建、运行、下载模型或改源码。30个快照文件的 Git blob SHA-1 已与指定commit获取的sha逐一校验一致，JSON保存对比；源码范围仍是选择性30文件，不是完整项目构建。

**观察**来自源码；**推断**为源码含义；**自主方案**为融合建议；**未知**为缺失调用代码或运行表现。以下短路径均相对快照根，具体源码片段和行号已保存到同名 JSON。

## 已有实现与复用边界

| 能力 | 观察证据 | 融合边界 |
|---|---|---|
| Qwen 模型族 | `MacRecord/Services/ModelRegistry.swift:5-18,130-162` 注册 Qwen3-ASR 0.6B/1.7B INT8；1.7B有固定revision、多文件尺寸/SHA声明 `:85-94` | 可复用注册/路径/加载封装；注册存在不代表文件已下载、地址当前有效、decoder兼容或性能达标 |
| Qwen加载 | `SherpaOnnxWrapper.swift:104-128` 配置conv frontend/encoder/decoder/tokenizer；max_total_len4096、max_new_tokens1024、temperature0、top_p1、seed0 | 这是ASR decoder参数，不是Foresight聊天token预算；默认CPU4线程16kHz/80维见 `NativeASRService.swift:140-156` |
| 段级实时ASR | `SherpaOnnxWrapper.swift:140-160` 使用CreateOfflineStream/AcceptWaveformOffline/DecodeOfflineStream；`NativeASRService.swift:52-86,547-579` 等VAD成段后增强再识别 | 保留“边录边出段”体验；不得宣称真正streaming decoder或低延迟逐字partial。延迟取决于语音结束/VAD/段长度/推理耗时 |
| VAD与文件识别 | `NativeASRService.swift:338-361` 文件识别最大块10s；`SherpaOnnxVADWrapper.swift:8-26` 默认静音0.3s、min speech0.25s、threshold0.5、最长语音10s、512window；voice input静音0.2s见 `:533-543`；`:605-663` stop时补齐与flush尾段 | 保留Silero VAD也可行；切换ASR不等于必须切换VAD。长句不能丢，强制切块要补上下文与时间 |
| 麦克风 | `AudioRecorder.swift:49-136` AVAudioEngine采集、转换16kHz mono Float32、持久化音频；boost位于文件写入之后 | 可复用采集/重采样/电平/暂停；原始持久化音频与增强输入路径须分清；write错误存在try?，应增加显式错误状态 |
| 系统音频 | `SystemAudioRecorder.swift:95-152` ScreenCaptureKit，capturesAudio=true，排除本进程音频，16kHz/mono | 不是原生混录麦克风。`App/AppState+Recording.swift:32-54` 为互斥分支。须新做双来源时钟、同步、持久化与混音；来源标签不能当说话人身份 |
| 睡眠唤醒 | `SystemAudioRecorder.swift:183-252` 暂停SCStream、保留文件后重建 | 有可复用处理；不能视为所有设备场景已验证。系统音频写入失败、设备切换、时钟间断需验收 |
| 音频增强 | `AudioEnhancer.swift:16-35,73-85` 80Hz高通、谱减、动态压缩；短于1s段做轻增强 | 不是神经分离或说话人分离；Qwen/FunASR须比较增强前后字错率，不能默认增强必然提升 |
| 说话人分离 | `NativeASRService.swift:185-310` 找pyannote segmentation与CAM++ embedding，整段离线diarization后按speaker段识别；`SherpaOnnxDiarizationWrapper.swift:41-63` 是offline diarization | 有独立离线模块，但它需要单独权重；不能说Qwen自带diarization。普通native capabilities还声明不支持speaker labels |
| 文件统一结果 | `NativeASRBackend.swift:9-36` 返回text但segments=[]、modelVersion=nil、elapsed=nil；hotwords参数未传下去、cancel为空 | Foresight引用跳转/问题定位需要段时间，现有输出契约不足。复用前补齐timestamp/source/revision与实际取消能力 |
| 录音保存 | `RecordingPersistenceCoordinator.swift:12-53,56-78,87-131` 音频存储、SwiftData、导入回滚、processing/completed/failed、启动标记中断、取消可重转录 | 保留可靠原音频为重转录基础；模型身份/版本/参数须随结果保存。正常录音保存调用在停止后，不能假设录制中已有完整事务检查点 |
| 重转录 | coordinator能取回audio URL/markProcessing/apply与失败状态 | `App/AppState.swift:275-428` 已有startRetranscription、任务队列、generation保护、取消后等待当前段结束；可复用，完整UI入口与运行表现未验证 |
| 语音输入 | `VoiceInputService.swift:138-199,228-288` lite mic采集→nativeASR→300ms轮询→光标文本注入/替换→stop flush→可选LLM纠错；`AudioRecorder.swift:237-301` lite不写音频文件 | 复用独立输入模式；`TextInjector.swift:10-88` 有辅助功能权限/剪贴板备份恢复/本次注入app PID检查；`RealtimeAudioPump.swift:9-35` 容量32、bufferingNewest并记录丢失；仍未运行验证安全字段/焦点变化/输入法。实时capability硬依赖nativeASR服务 |

## FunASR 判断

**观察**：当前 Swift 模型族与 wrapper 为 SenseVoice/Qwen；审阅快照未见可运行的 FunASR adapter。`docs/feature-audit.md:5-13` 写的是旧 `~/Desktop/whisper_env/` Python/FastAPI/pywebview/FunASR工作台，不能把该文档描述当作当前 Swift 项目的实现证据。

**自主方案**：新增 FunASR adapter，先明确所用模型、版本、授权、权重、CPU/加速后端、运行方式。FunASR是工具框架/模型生态，SenseVoice是具体模型族，两者不在同一抽象层；仅把现有SenseVoice按钮改名为FunASR不满足“改成Qwen与FunASR”的要求。若用户指 Fun-ASR 模型而非 FunASR 框架，应由主规格明确到具体模型。

**自主方案**：QwenAdapter与FunASRAdapter共同实现与框架无关的ASR契约。文件接口可从FileASRBackend扩展；另设录音会话接口 `start/feed/finish/cancel` 及能力声明，区分 `offline_file / vad_segmented / native_streaming`。后端可选择独立本地worker或原生runtime，但未完成选型与性能验证前不要承诺能直接塞进已有Sherpa wrapper。

## 融合边界

**自主方案**：Foresight侧保留会议、知识库、检索、会前准备、sidecar、笔记、引用和日历的业务主线；MAC-record侧提供AudioCapture、AudioPreprocess、ASREngine、TranscriptionStore、VoiceInput，不把MAC-record现有记录列表或摘要器直接变成新的产品主导航。

统一ASR事件建议包含 `session_id/source_id/segment_id/start_ms/end_ms/text/revision/is_final/engine_id/model_version`；speaker_id可空且与source_id分开。无时间的引擎明确标记能力，不伪造token时间。VAD成段边界可作为段时间，精度应单独声明。final段写库后触发embedding/问题识别，partial段只供预览；重转录生成新的transcript revision并重新生成引用关联。

双来源应优先分别保存 mic/system 原音频及单调时钟时间戳，由上层合并转写视图，混音作为可选派生文件。回声消除、重叠说话人、蓝牙切换、来源重复必须实测；不把“两种录音器都存在”当成双轨已实现。

语音输入作为独立模式：与会议录音互斥或明确资源共享，焦点变化时停止自动替换，保留原ASR与纠错差异，用户选择是否提交。语音输入无需默认进入知识库或上传纠错服务。

## 验收约束（自主方案）

1. Qwen0.6B/1.7B与目标FunASR分别通过模型下载/哈希/初始化/合成样本转写验收；断网或损坏文件不能标ready。不能只凭注册表绿灯。
2. 界面准确显示当前decoder模式；段级实时延迟分别报告VAD等待与推理耗时；长句/无停顿超过10s时无截断、重复或丢尾。
3. 30分钟mic/system并行录音与暂停/合盖/唤醒/耳机切换后，时间轴能对应原音频；若未完成双轨支持，UI不得出现该能力。
4. 每个final段保留时间、来源、模型版本，Foresight引用能回到对应音频范围；普通识别、diarization、重转录三条路径都不落空segments。
5. 增强功能通过安静/低音量/噪声/音乐样本的A/B字错率检查；不因增强而删掉有效语音。
6. diarization依赖缺失时显式降级；至少测多人交叠和同一人跨音源，不把channel或Microphone/Remote映射成真实人名。
7. 任务取消中止后台计算；重转录失败保留旧成功文本；过期任务不能覆盖新版本；异常退出后可回查原音频与状态。
8. voice input测焦点切换、手动编辑、Unicode/emoji、撤销、辅助功能权限缺失、安全输入框、尾段flush；未经验证不宣称兼容所有应用。

这些AC未执行，不是当前源码已经通过的测试。

## 新补齐源码中的融合注意点

**观察**：RealtimeAudioPump采取bufferingNewest(32)，丢buffer后只增加计数。**推断**：推理跟不上时可能漏语音，Foresight会议不能只把低延迟优先当完整性保证；应保留完整原音频并提示实时转写缺口，结束后可补转录。

**观察**：TextInjector每次操作记录当前前台app PID，替换先用Shift+Left选择oldLength字符，再校验PID后粘贴。**推断**：跨次注入未绑定同一输入控件，同app换窗口/光标移动/用户手动编辑仍可能选错范围，焦点变化AC仍有必要。这不是已验证漏洞复现，属于代码暴露的约束。
