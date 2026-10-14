#include "CSherpaBridge.h"
#include "../../ThirdParty/sherpa-onnx/c-api.h"
#include <dlfcn.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <exception>

struct MMQwen {
  void *library = nullptr;
  const SherpaOnnxOfflineRecognizer *recognizer = nullptr;
  decltype(&SherpaOnnxGetVersionStr) version = nullptr;
  decltype(&SherpaOnnxCreateOfflineRecognizer) create = nullptr;
  decltype(&SherpaOnnxDestroyOfflineRecognizer) destroy = nullptr;
  decltype(&SherpaOnnxCreateOfflineStream) stream = nullptr;
  decltype(&SherpaOnnxDestroyOfflineStream) destroy_stream = nullptr;
  decltype(&SherpaOnnxAcceptWaveformOffline) accept = nullptr;
  decltype(&SherpaOnnxDecodeOfflineStream) decode = nullptr;
  decltype(&SherpaOnnxGetOfflineStreamResult) result = nullptr;
  decltype(&SherpaOnnxDestroyOfflineRecognizerResult) destroy_result = nullptr;
  ~MMQwen() { if (recognizer && destroy) destroy(recognizer); if (library) dlclose(library); }
};
static int fail(int code, const char *message, char *error, int32_t capacity) {
  if (error && capacity > 0) snprintf(error, capacity, "%s", message ? message : "Native failure");
  return code;
}
static int load(MMQwen &q, const char *path, char *error, int32_t capacity) {
  if (!path || path[0] != '/') return fail(1, "Runtime path must be absolute", error, capacity);
  q.library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!q.library) return fail(1, dlerror(), error, capacity);
#define RESOLVE(field, symbol) q.field = reinterpret_cast<decltype(q.field)>(dlsym(q.library, #symbol)); if (!q.field) return fail(2, "Missing symbol: " #symbol, error, capacity)
  RESOLVE(version, SherpaOnnxGetVersionStr);
  RESOLVE(create, SherpaOnnxCreateOfflineRecognizer);
  RESOLVE(destroy, SherpaOnnxDestroyOfflineRecognizer);
  RESOLVE(stream, SherpaOnnxCreateOfflineStream);
  RESOLVE(destroy_stream, SherpaOnnxDestroyOfflineStream);
  RESOLVE(accept, SherpaOnnxAcceptWaveformOffline);
  RESOLVE(decode, SherpaOnnxDecodeOfflineStream);
  RESOLVE(result, SherpaOnnxGetOfflineStreamResult);
  RESOLVE(destroy_result, SherpaOnnxDestroyOfflineRecognizerResult);
#undef RESOLVE
  const char *v = q.version();
  if (!v || strcmp(v, "1.13.7")) return fail(3, "Runtime version must equal 1.13.7", error, capacity);
  return 0;
}
extern "C" int mm_qwen_probe(const char *path, char *error, int32_t capacity) {
  try { MMQwen q; return load(q, path, error, capacity); }
  catch (...) { return fail(5, "Native exception probing runtime", error, capacity); }
}
extern "C" MMQwen *mm_qwen_create(const char *path, const char *frontend, const char *encoder,
    const char *decoder, const char *tokenizer, int32_t threads, int32_t *code, char *error, int32_t capacity) {
  if (code) *code = 0;
  try {
    auto q = std::make_unique<MMQwen>();
    int status = load(*q, path, error, capacity);
    if (status) { if (code) *code = status; return nullptr; }
    if (!frontend || !encoder || !decoder || !tokenizer || threads < 1 || threads > 8) {
      if (code) *code = fail(4, "Invalid Qwen configuration", error, capacity); return nullptr;
    }
    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.num_threads = threads;
    config.model_config.provider = "cpu";
    config.decoding_method = "greedy_search";
    auto &m = config.model_config.qwen3_asr;
    m.conv_frontend = frontend; m.encoder = encoder; m.decoder = decoder; m.tokenizer = tokenizer;
    m.max_total_len = 4096; m.max_new_tokens = 1024; m.temperature = 0; m.top_p = 1; m.seed = 0;
    q->recognizer = q->create(&config);
    if (!q->recognizer) { if (code) *code = fail(5, "Recognizer creation failed", error, capacity); return nullptr; }
    return q.release();
  } catch (const std::exception &e) { if (code) *code = fail(5, e.what(), error, capacity); }
    catch (...) { if (code) *code = fail(5, "Native exception creating recognizer", error, capacity); }
  return nullptr;
}
extern "C" int mm_qwen_decode(MMQwen *q, const float *samples, int32_t count, char **text, MMQwenCancelled cancelled, void *context, char *error, int32_t capacity) {
  if (text) *text = nullptr;
  if (!q || !q->recognizer || !samples || count <= 0 || !text) return fail(4, "Invalid decode input", error, capacity);
  const SherpaOnnxOfflineStream *stream = nullptr;
  const SherpaOnnxOfflineRecognizerResult *result = nullptr;
  int status = 0;
  auto is_cancelled = [&]() { return cancelled && cancelled(context); };
  try {
    if (is_cancelled()) status = 6;
    else {
      stream = q->stream(q->recognizer);
      if (is_cancelled()) status = 6;
      else if (!stream) status = fail(5, "Stream creation failed", error, capacity);
      else {
        q->accept(stream, 16000, samples, count);
        if (is_cancelled()) status = 6;
        else {
          q->decode(q->recognizer, stream);
          if (is_cancelled()) status = 6;
          else {
            result = q->result(stream);
            if (is_cancelled()) status = 6;
            else if (!result || !result->text) status = fail(5, "Result unavailable", error, capacity);
            else if (!(*text = strdup(result->text))) status = fail(5, "Result allocation failed", error, capacity);
          }
        }
      }
    }
  } catch (const std::exception &e) { status = fail(5, e.what(), error, capacity); }
    catch (...) { status = fail(5, "Native exception decoding", error, capacity); }
  if (result) q->destroy_result(result);
  if (stream) q->destroy_stream(stream);
  return status;
}
extern "C" void mm_qwen_destroy(MMQwen *q) { delete q; }
extern "C" void mm_qwen_free_text(char *text) { free(text); }
