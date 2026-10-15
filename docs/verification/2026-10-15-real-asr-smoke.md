# Actual local ASR smoke — 2026-10-15

## Scope and result

Both production adapters transcribed the same three short synthetic WAVs on Apple M4, 16GiB RAM, macOS26.6.2. This establishes working local inference for these exact model/runtime combinations. It does not establish meeting quality, segmentation, microphone/system capture, native streaming, long-file handling, word timestamps or diarization.

No private recording or microphone input was used. macOS `say` voices Tingting / Samantha / Sinji produced Mandarin / English / Cantonese. `afconvert` converted each AIFF to PCM16LE,16kHz,mono WAV. References and actual output are retained in the JSON evidence.

| Clip | Audio seconds | Qwen cold load+decode seconds | Qwen decode only seconds | FunASR job seconds |
|---|---:|---:|---:|---:|
| Mandarin | 7.318 | 2.535 | 0.765 | 7.450 |
| English | 7.584 | 2.189 | 0.789 | 0.480 |
| Cantonese | 5.853 | 1.948 | 0.529 | 0.460 |

Qwen starts a fresh process/model for every row. FunASR uses the same Swift worker instance and PID; first row includes process/import/model startup, later rows reuse the model. These columns measure different lifecycle boundaries and must not be used as a direct model-speed ranking. Neither run controls thermal state, competing load, repetition or distribution percentiles.

Mandarin names, time and amount survived both routes on this sample. Qwen preserved the English currency unit `dollars`; FunASR omitted it and normalized the number. Cantonese outputs use simplified characters, so script differences should not be counted as lexical errors without an explicit normalization policy. No aggregate CER/WER is claimed from three synthetic clips. A separate 5-second all-zero PCM input returned empty Qwen text (see `qwen-silence-smoke-20261015.json`), a narrow silence smoke rather than a false-positive benchmark.

## Model bytes and environment

Qwen archive `sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2`, 878702423 bytes, SHA256 `393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96`, matches the official GitHub release-asset record. Runtime sherpa-onnx1.13.7, CPU4threads. All six required model/tokenizer hashes were computed from this verified archive; each CLI run supplied that manifest and returned `integrityManifestVerified:true`. Model hashes are in `qwen-synthetic-smoke-20261015.json`.

FunASR1.4.16 with torch/torchaudio2.8.0 in the project's ignored Python environment. SenseVoiceSmall revision `3847d57b6bdf2dd8875cb1508d2af43d80a16bf7`; checkpoint936291369bytes, SHA256 `833ca2dcfdf8ec91bd4f31cfac36d6124e0c459074d5e909aec9cabe6204a3ea`. HuggingFace transfer timed out; the official ModelScope mirror returned the same linked digest, and complete downloaded bytes matched the fixed HuggingFace revision digest. The mutable mirror URL alone is not treated as a pinned identity. Tokenizer/config/configuration were separately checked against the fixed revision LFS SHA or Git blob SHA.

The production worker used explicit local paths, CPU, `trust_remote_code=False`, `disable_update=True`, no VAD/punctuation/speaker models, hub-offline flags and its Python socket-denial guard. Calls went through the real Swift `FunASRWorker`, private pipes and production `Runtime/FunASR/worker.py`; no injected backend or fixture returned the transcript. No transcript alignment/speaker fields were present. Successful transcription does not establish those capabilities.

## Resident Qwen lifecycle

A separate Swift harness imported the built MeetingCore module and used the same verified model manifest. It transcribed Mandarin twice on one engine, called `await shutdown()`, transcribed a third time and called shutdown again. All outputs matched. `reusedRecognizer` was `[false,true,false]`; second-call load time was0 and total0.874s; after shutdown it reloaded in1.372s. Captured stderr was empty for all Qwen and FunASR probes.

Evidence files:

- `qwen-synthetic-smoke-20261015.json`: cold-load multilingual results/reference/sample counts/model hashes.
- `qwen-resident-smoke-20261015.json`: same-engine reuse/shutdown/reload results.
- `funasr-runtime-probe-20261015.json`: import probe only; intentionally retains `asr_verified:false`.
- `funasr-synthetic-smoke-20261015.json`: real Swift-to-worker same-PID results, raw and display text separate.

The probe's `asr_verified:false` is not rewritten by this experiment. Readiness in the eventual app must be tied to configuration and test evidence, not inferred permanently from these checked-in examples.

## Reproduction boundaries

Use `scripts/setup-sherpa.sh` and `scripts/setup-funasr.sh` for runtime installation. Download/verify the above explicit model revisions separately; weights/environments remain ignored and are not shipped by this commit. For Qwen use `.build/debug/MeetingASRCheck --runtime <absolute-dylib> --model <absolute-model-directory> --wav <absolute-wav> --revision <revision> --manifest <six-file-sha256-json>`.

FunASR uses `FunASRWorker(configuration:)` pointing at the installed Python, repository worker, fixed model directory and `model.pt`; call `transcribe(wavURL:)` sequentially and `shutdown()` when finished. Reproduction requires the actual model assets; checked-in output is historical evidence, not a substitute for running inference.

Parent verification: `scripts/test-core.sh`66/66, Python unit tests10/10, `swift build` passed. Independent Task3C1 spec review passed. Independent Task3C1 quality review passed and reran66/66. Symlink-switch and cancelled-shutdown-caller dedicated tests were suggested as nonblocking follow-ups; no defect observed in those implementation paths. The whole v0.2 product remains incomplete.
