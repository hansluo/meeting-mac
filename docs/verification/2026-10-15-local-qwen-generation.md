# Controlled local Qwen generation — 2026-10-15

The production `ChatClient` discovered and generated against a real local GGUF model, rather than the loopback test fixture. The request selected `meeting-qwen3-0.6b-q4` explicitly; discovery was checked for that ID, not used to select the first model. `finish_reason:stop`, returned model alias and actual usage were captured. The synthetic meeting sentence preserved time, amount and responsible person's name. A single short extraction prompt is not summary-quality acceptance.

## Runtime identity

Official Ollama release `v0.40.4`, asset `ollama-darwin.tgz` (GitHub asset638733391),167884528bytes, SHA256 `a4ceae4b2aaf18df37ebcbfb56ba3a37a87838631112d66c2be07268693c8d58`, verified before extracting with Python3.12 tar data filter. The executable used was its bundled **llama-server**, not an Ollama daemon or desktop application. It reports `0.6.0-dev (build1, commitb42b7e6d3)`, AppleClang21 arm64. Exact executable hash is retained in `local-qwen-generation-smoke-20261015.json`.

Model bytes came from the official Ollama registry's `qwen3:0.6b` manifest. Manifest SHA256 `7df6b6e09427a769808717c0a93cadc4ae99ed4eb8bf5ca557c90846becea435`; GGUF522640096bytes, SHA256 `7f4030143c1c477224c5434f8272c662a8b042079a0a584f0a27a1684fe2e1fa`, checked after complete download. Quantization reported by the loaded service is Q4_K Medium. This small model was selected for a bounded transport smoke, not a default model or quality recommendation.

The runtime/model are under ignored `.build/local-llm/` and `models/qwen3-0.6b-q4/`. No global installation, startup service, user account, user credentials or home-directory override was used. Child environment contained only PATH.

## Controlled service and request

The owned process was started with:

```text
llama-server --model <verified-model.gguf> --alias meeting-qwen3-0.6b-q4
  --ctx-size 4096 --parallel 1 --threads 4 --reasoning off --offline
  --no-webui --host 127.0.0.1 --port <unused-loopback-port>
```

The explicit local file loaded successfully, and the process listened only on loopback. Model discovery and summary generation used the project `ChatClient`, `ChatEndpoint` and `RouteResolver` source. The ephemeral probe profile supplied the controlled process's model/location/capability assertions to exercise the formal request path; it was never saved as app readiness. Arbitrary external localhost services are not proven local by this experiment.

Only standard model/messages/stream=false/max_tokens/temperature request fields were sent. Thinking was disabled on the controlled server, not by a provider-specific field forced into the client request. Host was Apple M4,16GiB RAM,macOS26.6.2. Device placement was not separately captured, so no CPU/GPU benchmark is claimed. One observed request took0.357seconds; no repetition or performance acceptance was conducted.

After the probe, the owned server was terminated normally, the exec session ended exit0, and the health endpoint refused connection. No permanent app profile/configuration was changed. The real-model service is not left running for the user.

Primary sources: [official release](https://github.com/ollama/ollama/releases/tag/v0.40.4), [registry manifest](https://registry.ollama.ai/v2/library/qwen3/manifests/0.6b). The mutable tag is accompanied by the captured manifest/blob digests above.

Remaining: full task-specific prompts and output validation, long-meeting token budgeting, SSE and cancellation acceptance with real models, connection/Keychain UI, configuration-bound probe evidence, cloud-provider acceptance and full MeetingMac v0.2 workflows.
