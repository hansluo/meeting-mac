import http.server, io, tarfile, time
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        route = self.path.strip('/')
        payload = bytes([7])*65536
        if route in ('archive','escape','symlink'):
            buf=io.BytesIO()
            with tarfile.open(fileobj=buf,mode='w:gz') as archive:
                info=tarfile.TarInfo('../escaped' if route=='escape' else 'fixed/model.bin')
                data=b'verified archive'; info.size=len(data)
                if route=='symlink': info.type=tarfile.SYMTYPE;info.linkname='/etc/hosts';info.size=0
                archive.addfile(info,io.BytesIO(data))
                extra=tarfile.TarInfo('fixed/unused');extra.size=100;archive.addfile(extra,io.BytesIO(b'x'*100))
            payload=buf.getvalue()
        if route=='short': payload=payload[:200]
        if route=='wrong': payload=b'x'*65536
        if route=='large': payload=payload*2
        self.send_response(503 if route=='status' else 200)
        self.send_header('Content-Length',str(len(payload)));self.end_headers()
        try:
            if route=='slow':
                for offset in range(0,len(payload),1024): self.wfile.write(payload[offset:offset+1024]);self.wfile.flush();time.sleep(.03)
            else: self.wfile.write(payload)
        except (BrokenPipeError,ConnectionResetError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_address[1],flush=True)
server.serve_forever()
