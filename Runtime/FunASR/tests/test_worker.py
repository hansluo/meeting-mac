import importlib.util
import io
import json
import tempfile
import subprocess
import struct
import socket
import types
from unittest.mock import patch
import unittest
import wave
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('worker', Path(__file__).parents[1] / 'worker.py')
w = importlib.util.module_from_spec(spec)
if spec.loader and Path(spec.origin).exists():
    spec.loader.exec_module(w)

class WorkerTests(unittest.TestCase):
    def test_reject_protocol_and_bad_job_without_echo(self):
        for request in ({'version': 9, 'job_id': 'secret', 'op': 'probe'}, {'version': 1, 'job_id': '', 'op': 'probe'}):
            reply = w.handle(request, None)
            self.assertEqual(reply['type'], 'error')
            self.assertNotIn('secret', json.dumps(reply))

    def test_requires_local_directory_and_explicit_revision(self):
        for config in ({'model_dir': 'https://secret', 'revision': 'main'}, {'model_dir': '/missing', 'revision': ''}):
            with self.assertRaises(w.WorkerError):
                w.validate_configuration(config)

    def test_wav_validation(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'a.wav'
            for rate, channels, width, frames in [(8000, 1, 2, 20), (16000, 2, 2, 20), (16000, 1, 1, 20), (16000, 1, 2, 480001)]:
                with wave.open(str(path), 'wb') as f:
                    f.setparams((channels, width, rate, 0, 'NONE', 'not compressed'))
                    f.writeframes(b'\0' * frames * channels * width)
                with self.assertRaises(w.WorkerError):
                    w.validate_wav(str(path))

    def test_backend_fields_preserve_raw_no_fabricated_timing(self):
        class Backend:
            def generate(self, **kwargs):
                print('secret noise')
                return [{'text': '<|zh|>你好', 'timestamp': [[0, 1]], 'speaker': 'real'}]
        worker = w.Worker(backend=Backend(), postprocess=lambda s: '你好')
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'a.wav'
            with wave.open(str(path), 'wb') as f:
                f.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                f.writeframes(b'\0\0' * 16)
            result = worker.transcribe(str(path))
        self.assertEqual(result['raw_text'], '<|zh|>你好')
        self.assertEqual(result['text'], '你好')
        self.assertEqual(result['backend_fields'], {'timestamp': [[0, 1]], 'speaker': 'real'})
        self.assertNotIn('words', result)

    def test_backend_failure_sanitized(self):
        class Backend:
            def generate(self, **kwargs): raise ValueError('secret transcript')
        worker = w.Worker(backend=Backend())
        with self.assertRaises(w.WorkerError) as caught:
            worker.transcribe('/missing')
        self.assertNotIn('secret', str(caught.exception))

    def test_real_pipe_rejects_invalid_json_and_protocol(self):
        child = subprocess.Popen([sys.executable, str(Path(__file__).parents[1] / 'worker.py')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(json.loads(child.stdout.readline())['type'], 'started')
            for line in (b'{bad\n', b'{"version":true,"job_id":"secret","op":"probe"}\n'):
                child.stdin.write(line); child.stdin.flush()
                response = child.stdout.readline()
                self.assertEqual(json.loads(response)['type'], 'error')
                self.assertNotIn(b'secret', response)
        finally:
            child.stdin.close(); child.wait(timeout=2)
            self.assertEqual(child.stderr.read(), b'')
            child.stdout.close(); child.stderr.close()

    def test_rejects_forged_riff_size(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'audio.wav'
            with wave.open(str(path), 'wb') as f:
                f.setparams((1, 2, 16000, 0, 'NONE', 'not compressed')); f.writeframes(b'\0\0'*16)
            data = bytearray(path.read_bytes()); data[4:8] = struct.pack('<I', 2); path.write_bytes(data)
            with self.assertRaises(w.WorkerError): w.validate_wav(str(path))

    def test_network_is_denied_even_for_toolkit_implicit_requests(self):
        original = (socket.socket.connect, socket.socket.connect_ex, socket.create_connection)
        try:
            w.enforce_offline()
            with socket.socket() as connection:
                with self.assertRaises(OSError): connection.connect(('127.0.0.1', 1))
        finally: socket.socket.connect, socket.socket.connect_ex, socket.create_connection = original

    def test_load_disables_implicit_auxiliary_models_and_remote_code(self):
        captured = {}
        funasr = types.ModuleType('funasr')
        def constructor(**kwargs): captured.update(kwargs); return object()
        funasr.AutoModel = constructor
        postprocess = types.ModuleType('funasr.utils.postprocess_utils')
        postprocess.rich_transcription_postprocess = lambda s: s
        originals = (socket.socket.connect, socket.socket.connect_ex, socket.create_connection)
        try:
            with tempfile.TemporaryDirectory() as root, patch.dict(sys.modules, {'funasr': funasr, 'funasr.utils.postprocess_utils': postprocess}):
                Path(root, 'config.yaml').write_text('model: SenseVoiceSmall')
                Path(root, 'explicit.pt').write_bytes(b'x')
                w.Worker().load({'model_dir': root, 'checkpoint': 'explicit.pt', 'revision': 'r'})
                self.assertEqual(captured['device'], 'cpu')
                self.assertEqual(captured['init_param'], str(Path(root, 'explicit.pt').resolve()))
                self.assertFalse(captured['trust_remote_code'])
                self.assertTrue(captured['disable_update'])
                for key in ('vad_model', 'punc_model', 'spk_model'): self.assertIn(key, captured); self.assertIsNone(captured[key])
        finally: socket.socket.connect, socket.socket.connect_ex, socket.create_connection = originals

    def test_streaming_capabilities_are_explicitly_false(self):
        self.assertEqual(w.CAPABILITIES, {'batch': True, 'native_streaming': False, 'hotwords': False, 'word_alignment': False, 'diarization': False})

if __name__ == '__main__': unittest.main()
