"""Exercise the installed Codex TUI with a local response fixture and no account access."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import threading
import time

from api_fixture import ROOT, AppFixture, eventually


def check_codex_shutdown(directory, prompt, quit_normally, saved_output):
    binary = shutil.which('codex') or str(Path.home() / '.local/bin/codex')
    if not Path(binary).is_file():
        print('SKIP installed Codex shutdown: Codex CLI is unavailable; raw-mode regression still runs', flush=True)
        return

    class ResponseFixture(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', 0)))
            part = dict(type='output_text', text='CODEX_SHUTDOWN_FIXTURE_REPLY', annotations=[])
            message = dict(id='msg_shutdown', type='message', role='assistant', status='completed', content=[part])
            response = dict(id='resp_shutdown', object='response', status='completed', output=[message],
                            usage=dict(input_tokens=10, output_tokens=5, total_tokens=15))
            events = [
                dict(type='response.created', response=dict(response, status='in_progress', output=[])),
                dict(type='response.output_item.added', output_index=0, item=dict(message, status='in_progress', content=[])),
                dict(type='response.content_part.added', output_index=0, content_index=0,
                     item_id=message['id'], part=dict(part, text='')),
                dict(type='response.output_text.delta', output_index=0, content_index=0,
                     item_id=message['id'], delta=part['text']),
                dict(type='response.output_item.done', output_index=0, item=message),
                dict(type='response.completed', response=response),
            ]
            body = ''.join('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n' for event in events).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(('127.0.0.1', 0), ResponseFixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    home = directory / 'codex-home'
    home.mkdir()
    (home / 'config.toml').write_text(
        'model = "gpt-5.4"\nmodel_provider = "shutdown_fixture"\n'
        'check_for_update_on_startup = false\napproval_policy = "never"\nsandbox_mode = "read-only"\n'
        '[model_providers.shutdown_fixture]\nname = "Shutdown fixture"\nwire_api = "responses"\n'
        f'base_url = "http://127.0.0.1:{server.server_port}/v1"\nrequires_openai_auth = false\n'
        f'[projects.{json.dumps(str(directory.resolve()))}]\ntrust_level = "trusted"\n')
    try:
        with AppFixture('terminal-recovery-codex-manual', environment={'CODEX_HOME': str(home)}) as app:
            prompt(app)
            command = shlex.join([binary, '--no-daemon', '--no-alt-screen', '-C', str(directory),
                                  'Reply with the fixture greeting. Do not use tools.'])
            app.rpc('terminal.send', pane='p1', text=command + '\r')
            eventually('Codex manual baseline response',
                       lambda: 'CODEX_SHUTDOWN_FIXTURE_REPLY' in app.rpc('terminal.capture', pane='p1')['text'], timeout=45)
            app.rpc('terminal.key', pane='p1', key='ctrl+c')
            time.sleep(1)
            baseline = app.rpc('terminal.capture', pane='p1')['text']
            (ROOT / 'artifacts/terminal-recovery-codex-first-interrupt.txt').write_text(baseline)
            if 'codex resume ' not in baseline:
                app.rpc('terminal.key', pane='p1', key='ctrl+c')
            try:
                eventually('Codex manual resume command',
                           lambda: 'codex resume ' in app.rpc('terminal.capture', pane='p1')['text'], timeout=5)
            finally:
                (ROOT / 'artifacts/terminal-recovery-codex-manual.txt').write_text(app.rpc('terminal.capture', pane='p1')['text'])
            quit_normally(app)
        print('PASS actual Codex manual Ctrl-C baseline prints a resume command', flush=True)

        with AppFixture('terminal-recovery-codex', environment={'CODEX_HOME': str(home)}) as app:
            prompt(app)
            command = shlex.join([binary, '--no-daemon', '--no-alt-screen', '-C', str(directory),
                                  'Reply with the fixture greeting. Do not use tools.'])
            app.rpc('terminal.send', pane='p1', text=command + '\r')
            try:
                eventually('Codex local fixture response',
                           lambda: 'CODEX_SHUTDOWN_FIXTURE_REPLY' in app.rpc('terminal.capture', pane='p1')['text'], timeout=45)
                app.rpc('debug.screenshot', pane='p1', path=str(ROOT / 'artifacts/terminal-recovery-codex-before.png'))
                quit_normally(app)
                stored = saved_output(app)['text']
                assert 'codex resume ' in stored, 'Actual Codex exit did not preserve its resume command'
                assert stored.count('CODEX_SHUTDOWN_FIXTURE_REPLY') == 1, 'Actual Codex transcript was duplicated'
                (ROOT / 'artifacts/terminal-recovery-codex-saved.txt').write_text(stored)
                source = (app.root / 'state/workspace.json').read_text()
            except BaseException:
                if app.process.poll() is None:
                    (ROOT / 'artifacts/terminal-recovery-codex-failure.txt').write_text(app.rpc('terminal.capture', pane='p1')['text'])
                raise
        with AppFixture('terminal-recovery-codex-load', workspace_source=source) as app:
            prompt(app)
            restored = app.rpc('terminal.capture', pane='p1')['text']
            assert 'codex resume ' in restored and restored.count('CODEX_SHUTDOWN_FIXTURE_REPLY') == 1
            app.rpc('debug.screenshot', pane='p1', path=str(ROOT / 'artifacts/terminal-recovery-codex-restored.png'))
        version = subprocess.check_output([binary, '--version'], text=True).strip()
        print(f'PASS actual {version}: isolated local response, graceful exit, resume command retained once after restart', flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
