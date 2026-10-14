#!/usr/bin/env python3
"""Private protocol v1 NDJSON worker. Never accepts remote model/audio identifiers."""
import contextlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import sys
import socket
import wave

VERSION = 1
MAX_LINE = 65536
CAPABILITIES = {'batch': True, 'native_streaming': False, 'hotwords': False, 'word_alignment': False, 'diarization': False}

class WorkerError(Exception):
    pass

@contextlib.contextmanager
def quiet():
    # Suppress Python and native-library stdout/stderr; neither contains IPC.
    sys.stdout.flush()
    saved = [os.dup(1), os.dup(2)]
    with open(os.devnull, 'w') as sink:
        try:
            os.dup2(sink.fileno(), 1)
            os.dup2(sink.fileno(), 2)
            with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
                yield
        finally:
            os.dup2(saved[0], 1)
            os.dup2(saved[1], 2)
            for fd in saved: os.close(fd)

def enforce_offline():
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['MODELSCOPE_OFFLINE'] = '1'
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    def denied(*args, **kwargs): raise OSError('offline_worker')
    # Enforce offline mode even if a toolkit dependency ignores hub flags.
    socket.socket.connect = denied
    socket.socket.connect_ex = denied
    socket.create_connection = denied

def validate_configuration(config):
    path = config.get('model_dir')
    revision = config.get('revision')
    if not isinstance(path, str) or not Path(path).is_absolute() or '\0' in path or not Path(path).is_dir():
        raise WorkerError('invalid_configuration')
    if not isinstance(revision, str) or not revision.strip() or len(revision) > 256 or '\0' in revision:
        raise WorkerError('invalid_configuration')
    # An explicit checkpoint is required: no directory-name based fallback/download.
    checkpoint = config.get('checkpoint')
    if not isinstance(checkpoint, str) or not checkpoint or Path(checkpoint).is_absolute() or '..' in Path(checkpoint).parts:
        raise WorkerError('invalid_configuration')
    file = Path(path) / checkpoint
    if not file.is_file() or file.stat().st_size == 0 or not file.resolve().is_relative_to(Path(path).resolve()):
        raise WorkerError('missing_checkpoint')
    if not (Path(path) / 'config.yaml').is_file(): raise WorkerError('missing_configuration')
    return str(Path(path).resolve()), str(file.resolve()), revision

def validate_wav(path):
    if not isinstance(path, str) or not Path(path).is_absolute() or '\0' in path:
        raise WorkerError('invalid_audio')
    try:
        if Path(path).stat().st_size > 1000000: raise WorkerError('invalid_audio')
        with wave.open(path, 'rb') as f:
            if (f.getnchannels(), f.getsampwidth(), f.getframerate(), f.getcomptype()) != (1, 2, 16000, 'NONE') or not 0 < f.getnframes() <= 480000:
                raise WorkerError('invalid_audio')
            count = f.getnframes()
            if len(f.readframes(count)) != count * 2: raise WorkerError('invalid_audio')
            return count
    except (OSError, wave.Error, EOFError): raise WorkerError('invalid_audio') from None

class Worker:
    def __init__(self, backend=None, postprocess=None):
        self.backend = backend
        self.postprocess = postprocess

    def load(self, config):
        directory, checkpoint, revision = validate_configuration(config)
        enforce_offline()
        with quiet():
            try:
                from funasr import AutoModel
                from funasr.utils.postprocess_utils import rich_transcription_postprocess
                self.backend = AutoModel(model=directory, init_param=checkpoint, device='cpu', disable_update=True, trust_remote_code=False, vad_model=None, punc_model=None, spk_model=None)
                self.postprocess = rich_transcription_postprocess
            except Exception: raise WorkerError('model_load_failed') from None
        return {'model_dir': directory, 'checkpoint': config['checkpoint'], 'revision': revision, 'capabilities': CAPABILITIES}

    def transcribe(self, path):
        count = validate_wav(path)
        if self.backend is None: raise WorkerError('model_not_loaded')
        with quiet():
            try:
                result = self.backend.generate(input=path, batch_size_s=30)
                if not isinstance(result, list) or len(result) != 1 or not isinstance(result[0], dict) or not isinstance(result[0].get('text'), str):
                    raise WorkerError('invalid_backend_result')
                raw = result[0]['text']
                text = self.postprocess(raw) if self.postprocess else raw
                if not isinstance(text, str): raise WorkerError('invalid_backend_result')
                # Only actual toolkit fields; no interpretation as word alignment/diarization.
                fields = {k: result[0][k] for k in ('timestamp', 'sentence_info', 'speaker') if k in result[0]}
                output = {'text': text, 'raw_text': raw, 'backend_fields': fields, 'sample_count': count}
                json.dumps(output, allow_nan=False)
                return output
            except WorkerError: raise
            except Exception: raise WorkerError('transcription_failed') from None

def reply(job, kind, **fields): return {'version': VERSION, 'job_id': job, 'type': kind, **fields}

def handle(request, worker):
    if not isinstance(request, dict) or type(request.get('version')) is not int or request['version'] != VERSION or not isinstance(request.get('job_id'), str) or not re.fullmatch(r'[a-f0-9-]{36}', request['job_id']):
        return reply(None, 'error', code='invalid_protocol')
    job = request['job_id']
    try:
        op = request.get('op')
        if op == 'probe':
            with quiet():
                try:
                    import funasr
                    import torch
                    version = importlib.metadata.version('funasr')
                except Exception: raise WorkerError('runtime_unavailable') from None
            return reply(job, 'probe', package_version=version, device='cpu', model_loaded=worker.backend is not None, asr_verified=False, capabilities=CAPABILITIES)
        if op == 'load': return reply(job, 'ready', **worker.load(request))
        if op == 'transcribe': return reply(job, 'result', **worker.transcribe(request.get('audio_path')))
        raise WorkerError('unsupported_operation')
    except WorkerError as error: return reply(job, 'error', code=str(error))
    except Exception: return reply(job, 'error', code='worker_failed')

def emit(message):
    try:
        data = json.dumps(message, ensure_ascii=False, allow_nan=False, separators=(',', ':'))
        if len(data.encode()) > MAX_LINE: data = json.dumps(reply(message.get('job_id'), 'error', code='result_too_large'))
        sys.stdout.write(data + '\n')
        sys.stdout.flush()
    except (BrokenPipeError, OSError): raise SystemExit(0)

def main():
    emit(reply(None, 'started'))
    enforce_offline()
    worker = Worker()
    while True:
        line = sys.stdin.buffer.readline(MAX_LINE + 1)
        if not line: return
        if len(line) > MAX_LINE or not line.endswith(b'\n'):
            emit(reply(None, 'error', code='line_too_large'))
            return
        try: request = json.loads(line)
        except (ValueError, UnicodeError):
            emit(reply(None, 'error', code='invalid_json'))
            continue
        emit(handle(request, worker))

if __name__ == '__main__': main()
