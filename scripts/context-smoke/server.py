import http.server, threading, subprocess, os, time
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path=='/slow': time.sleep(2)
  self.send_response(500 if self.path=='/fail' else 200); self.send_header('Content-Type','application/json'); self.end_headers()
  try: self.wfile.write(b'{"ok":true,"count":3,"token":"synthetic-secret","message":"test"}')
  except BrokenPipeError: pass
 def log_message(self,*a): pass
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),H)
threading.Thread(target=s.serve_forever,daemon=True).start()
e=os.environ.copy(); e['POSTME_TEST_BASE_URL']='http://127.0.0.1:'+str(s.server_port)
r=subprocess.run([os.environ['POSTME_HARNESS']],env=e)
s.shutdown(); raise SystemExit(r.returncode)
