#!/usr/bin/env python3
"""
Cloudflare Tunnel Test Server
Simple HTTP server for testing tunnel connectivity
"""

import http.server
import socketserver
import os
import signal
import sys
import argparse
from datetime import datetime

class TestHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            
            # Read the HTML file
            try:
                with open('test_page.html', 'r') as f:
                    content = f.read()
                # Replace placeholder with current time and port
                content = content.replace('{{TIMESTAMP}}', datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC'))
                content = content.replace('{{PORT}}', str(self.server.server_address[1]))
                self.wfile.write(content.encode())
            except FileNotFoundError:
                # Fallback if HTML file doesn't exist
                fallback_content = """
<!DOCTYPE html>
<html>
<head><title>Tunnel Test</title></head>
<body>
    <h1>🎉 Tunnel Test Success!</h1>
    <p>Port {} is working via Cloudflare Tunnel</p>
    <p>Time: {}</p>
    <p><em>test_page.html not found, using fallback content</em></p>
</body>
</html>
                """.format(self.server.server_address[1], datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC'))
                self.wfile.write(fallback_content.encode())
        else:
            super().do_GET()
    
    def log_message(self, format, *args):
        print(f"[{self.log_date_time_string()}] {format % args}")

def signal_handler(sig, frame):
    print('\nShutting down test server...')
    sys.exit(0)

def main():
    parser = argparse.ArgumentParser(description='Cloudflare Tunnel Test Server')
    parser.add_argument('port', nargs='?', type=int, default=10101, 
                       help='Port to listen on (default: 10101)')
    args = parser.parse_args()
    
    PORT = args.port
    
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    try:
        with socketserver.TCPServer(("", PORT), TestHandler) as httpd:
            print(f"Cloudflare Tunnel Test Server")
            print(f"Port: {PORT}")
            print(f"Directory: {os.getcwd()}")
            print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            print("Press Ctrl+C to stop")
            print("-" * 40)
            httpd.serve_forever()
    except OSError as e:
        print(f"Error: {e}")
        if "Address already in use" in str(e):
            print(f"Port {PORT} is already in use. Try a different port.")
        sys.exit(1)
    except KeyboardInterrupt:
        print('\nTest server stopped')

if __name__ == "__main__":
    main()