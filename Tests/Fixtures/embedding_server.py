#!/usr/bin/python3
"""Controlled owned-child fixture. Never used by the production application."""
import argparse, json, os, time, signal
from http.server import BaseHTTPRequestHandler, HTTPServer
p=argparse.ArgumentParser()
p.add_argument('--model');p.add_argument('--port',type=int);p.add_argument('--api-key-file')
a,extra=p.parse_known_args()
root=os.path.dirname(a.model)
mode_path=os.path.join(root,'mode')
def mode():
    try:
        with open(mode_path) as f: return f.read()
    except FileNotFoundError: return ''
with open(os.path.join(root,'pid'),'w') as f: f.write(str(os.getpid()))
with open(os.path.join(root,'environment'),'w') as f: json.dump(dict(os.environ),f)
with open(os.path.join(root,'arguments'),'w') as f: json.dump(extra,f)
with open(a.api_key_file) as f: key=f.read().strip()
if mode()=='slow': signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode()=='startup': time.sleep(10)
if mode()=='startupcrash': os._exit(2)
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def send(self,body,status=200):
        data=json.dumps(body).encode();self.send_response(status);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_GET(self):
        if mode()!='unauthenticated' and self.headers.get('Authorization')!='Bearer '+key:return self.send({},401)
        self.send({'data':[{'id':'wrong' if mode()=='badready' else 'meeting-embeddinggemma300m'}]})
    def do_POST(self):
        if self.headers.get('Authorization')!='Bearer '+key:return self.send({},401)
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with open(os.path.join(root,'records'),'a') as f:f.write(json.dumps({'path':self.path,'body':body})+'\n')
        m=mode()
        if m=='crash': os._exit(1)
        if m=='slow':time.sleep(10)
        if m=='trickle':
            self.send_response(200);self.send_header('Content-Length','10000');self.end_headers()
            for _ in range(100):self.wfile.write(b' ');self.wfile.flush();time.sleep(.1)
            return
        if m=='redirect':
            self.send_response(302);self.send_header('Location','http://127.0.0.1:1/secret');self.end_headers();return
        if m=='status':return self.send({'secret':'PRIVATE'},500)
        if m=='oversize':
            self.send_response(200);self.send_header('Content-Length','999999');self.end_headers();self.wfile.write(b' '*999999);return
        if self.path=='/tokenize':return self.send({'tokens':[1]*(2047 if m=='context' else 12)})
        v=[0.0]*768;v[0]=3;v[1]=4
        if m=='zero':v=[0.0]*768
        if m=='dimension':v=[1.0]
        if m=='nan':v[0]=float('nan')
        data=[{'index':1 if m=='index' else 0,'embedding':v}]
        if m=='missing':data=[]
        if m=='duplicate':data=data*2
        self.send({'model':'wrong' if m=='model' else 'meeting-embeddinggemma300m','data':data})
HTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
