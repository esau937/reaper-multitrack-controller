"""Windows integration check: real hidden launcher and a local fake receiver."""
import ctypes
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

received = []


class Receiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        time.sleep(0.3)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def log_message(self, *args):
        pass


def visible_windows():
    windows = set()
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    @callback_type
    def callback(hwnd, _):
        if ctypes.windll.user32.IsWindowVisible(hwnd):
            windows.add(hwnd)
        return True

    ctypes.windll.user32.EnumWindows(callback, 0)
    return windows


with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Receiver) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='holyrics hidden test ') as directory:
        request = Path(directory) / 'request.json'
        response = Path(directory) / 'response.json'
        request.write_text(json.dumps({'text': 'Título\nLinha 2'}), encoding='utf-8')
        system = Path(os.environ['SystemRoot']) / 'System32'
        helper = Path(__file__).resolve().parents[1] / 'modules' / 'holyrics_hidden.vbs'
        before = visible_windows()
        process = subprocess.Popen([
            str(system / 'wscript.exe'), '//B', '//NoLogo', str(helper),
            str(system / 'curl.exe'), str(request), str(response),
            f'http://127.0.0.1:{server.server_port}/test',
        ])
        appeared = set()
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            appeared.update(visible_windows() - before)
            time.sleep(0.01)
        assert process.wait(timeout=1) == 0, 'hidden launcher failed'
        assert json.loads(response.read_text())['status'] == 'ok'
        assert received == [{'text': 'Título\nLinha 2'}]
        assert not appeared, f'Unexpected visible windows: {appeared}'
    server.shutdown()
print('holyrics_hidden_test: passed (real POST, Unicode, no new visible windows)')
