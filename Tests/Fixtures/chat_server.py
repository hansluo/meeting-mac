#!/usr/bin/env python3
import json, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

records = []
lock = threading.Lock()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/records':
            with lock: payload = list(records)
            self.reply(200, payload)
            return
        self.handle_request()
    def do_POST(self): self.handle_request()
    def reply(self, status, payload, headers=None):
        body = json.dumps(payload).encode() if not isinstance(payload, bytes) else payload
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def handle_request(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        record = dict(path=self.path, method=self.command, headers=dict(self.headers), body=json.loads(body) if body else None)
        with lock: records.append(record)
        mode = self.path.split('/')[1]
        if mode == 'slow': time.sleep(3)
        if mode in ('401', '429', '500'):
            self.reply(int(mode), {'error': 'secret-server-body secret-key'})
        elif mode == 'redirect':
            self.reply(302, {}, {'Location': '/redirect-target'})
        elif mode == 'malformed': self.reply(200, b'not json secret-key')
        elif mode == 'empty': self.reply(200, {'choices': []})
        elif mode == 'bad-models': self.reply(200, {'data': [{'id': ''}], 'models': [{'name': ''}]})
        elif mode == 'minimal': self.reply(200, {'choices': [{'message': {'role': 'assistant', 'content': 'answer'}}]})
        elif mode in ('missing-content', 'wrong-role', 'null-content', 'blank-content', 'malformed-usage'):
            message = {'role': 'assistant', 'content': 'answer'}
            if mode == 'missing-content': del message['content']
            if mode == 'wrong-role': message['role'] = 'user'
            if mode == 'null-content': message['content'] = None
            if mode == 'blank-content': message['content'] = '   '
            payload = {'choices': [{'message': message}]}
            if mode == 'malformed-usage': payload['usage'] = {'total_tokens': 'invalid'}
            self.reply(200, payload)
        elif self.path.endswith('/api/tags'):
            self.reply(200, {'models': [{'name': 'qwen:local'}, {'name': 'other'}]})
        elif self.path.endswith('/models'):
            if mode == 'manual': self.reply(404, {})
            else: self.reply(200, {'data': [{'id': 'chosen'}, {'id': 'other'}]})
        else:
            self.reply(200, {'model': 'chosen', 'choices': [{'message': {'role': 'assistant', 'content': 'answer'}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 3, 'completion_tokens': 2, 'total_tokens': 5}})
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()
