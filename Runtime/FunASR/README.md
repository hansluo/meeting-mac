# FunASR local CPU worker (protocol v1)

This is the batch foundation for the native macOS ASR dispatcher. It is **not** a
completed meeting workflow or a verified speech recognition model. No model
weights are included or downloaded by setup. Fixtures are test-only and cannot be
selected by the production worker.

## Environment

Run `scripts/setup-funasr.sh` on macOS arm64 with Homebrew Python 3.12 and uv.
The script creates the ignored `.venv/funasr` environment and synchronizes the
hash-locked dependencies. Re-running is idempotent; no global pip installation.
`requirements.in` pins FunASR 1.4.16 and the paired torch/torchaudio 2.8.0 packages.
`requirements.lock` was resolved against Python 3.12 on macOS arm64. Hashes verify
PyPI distribution bytes, not the trustworthiness of arbitrary model checkpoints.

The caller must separately obtain and verify a local toolkit-compatible model
(e.g. a registered SenseVoiceSmall architecture), then pass an absolute directory,
explicit checkpoint filename, and nonempty revision identifier. The directory
must include `config.yaml` and that checkpoint. Revision is provenance supplied
by the caller, **not** a claim that model bytes were cryptographically verified.
Models stay under ignored `models/` or another explicit local directory.

## Swift integration

Create `FunASRWorker(configuration: FunASRConfiguration(...))` with the environment's
Python executable, the absolute `worker.py` path, model directory, checkpoint and
revision. `probeRuntime()` imports the installed toolkit and returns package
version, CPU device provenance through the protocol, and `asrVerified == false`.
A probe does not initialize a model or transcribe audio. `transcribe(wavURL:)`
loads the selected local model once, then reuses that resident worker for sequential
jobs. `shutdown()` kills and waits for process termination. Deinitialization also
cleans up. One in-flight operation is allowed; a concurrent operation gets `busy`.

Input must be local RIFF/WAVE PCM16 little endian, 16 kHz, mono, nonempty and at
most 30 seconds. Swift reuses `QwenPCM16WAV`/PCM validation. There is no resampling,
remote audio URL, default checkpoint, cloud fallback or HTTP service. Python hub
offline flags and denied socket connection methods prevent implicit Python network
fetches. This is a controlled subprocess, not an OS sandbox for hostile model code.
Only trusted local checkpoints/configurations should be supplied.

Startup, import probe, model ready and transcription result are separate states.
Each request has protocol version 1 and a fresh UUID; responses must match the
active job and internal worker generation. Malformed JSON, stdout noise, oversized
lines, unknown jobs and unknown error codes fail closed. IPC uses private stdin /
stdout pipes; third-party stdout/stderr is suppressed. Diagnostics never retain
audio, transcript text, traceback or exception bodies. Swift permits only stable
error codes. Result strings exist solely in the returned result.

Startup and request deadlines are independent. Cancellation or timeout kills the
owned worker even when a CPU inference call cannot interrupt; the task completes
after Foundation reports child termination/reaping. A later request starts a fresh
worker with the same immutable configuration. Cleanup uses a termination signal;
`Process.waitUntilExit()` can hang on a background RunLoop during repeated launch
and teardown on macOS. No worker is kept after a protocol/backend failure.

## Wire protocol

The worker emits `{"version":1,"job_id":null,"type":"started"}` after process
startup. Messages are bounded NDJSON (64 KiB output lines, 4 KiB Swift requests).
Requests use UUID `job_id` and `op`:

- `probe`: response `probe` with package version, CPU, model-loaded state and
  `asr_verified:false`.
- `load`: explicit `model_dir`, `checkpoint`, `revision`; response `ready` only
  after toolkit initialization succeeds.
- `transcribe`: absolute `audio_path`; response `result` containing `raw_text`,
  display `text`, actual `backend_fields` and `sample_count`.

Error replies contain stable `code` values only. Invalid protocol IDs are returned
as null, without reflecting request content. Raw text is retained separately from
optional `rich_transcription_postprocess` output. Only actual toolkit timestamp,
sentence-info and speaker fields are passed through; they are not promoted into
verified word alignment or diarization capabilities.

Only `batch` is supported. Native streaming, hotwords, word alignment and diarization
are explicitly false. Live FSMN/VAD and streaming require separate implementation
and verification; a toolkit/model family name does not establish these capabilities.

## Tests and provenance

Run `python3 -m unittest discover -s Runtime/FunASR/tests` and
`scripts/test-core.sh`. Python tests inject backend objects into internal unit tests;
there is no production CLI backend bypass. Swift tests launch the separate
`Tests/Fixtures/funasr_test_worker.py` through real private pipes and verify reuse,
errors, deadlines, cancellation, reaping and restart. Fixture text is not ASR
acceptance evidence. Real model transcription requires separately verified weights.

Primary dependency sources, checked 2026-10-14:

- [FunASR PyPI metadata](https://pypi.org/pypi/funasr/1.4.16/json), version 1.4.16.
- [FunASR official repository](https://github.com/modelscope/FunASR): official
  AutoModel CPU / SenseVoiceSmall examples and toolkit source.
- [PyTorch installation](https://pytorch.org/get-started/locally/): paired CPU
  PyTorch / torchaudio packages for macOS.

The backend uses `AutoModel(model=local_directory, init_param=explicit_checkpoint,
device="cpu", disable_update=True, trust_remote_code=False)`. It accepts local
registered toolkit architectures rather than fetching remote code. Original
FunASR toolkit/license remains upstream; this repository's worker is an adapter.
