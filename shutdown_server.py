from http.server import HTTPServer, BaseHTTPRequestHandler
import subprocess

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/shutdown':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
            subprocess.Popen('shutdown /s /t 5', shell=True)
        elif self.path == '/status':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'ONLINE')
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        pass  # ログ出力を抑制

print("Doge Power Server 起動中... ポート8765")
HTTPServer(('0.0.0.0', 8765), Handler).serve_forever()
