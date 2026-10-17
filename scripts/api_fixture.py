"""Owned app fixture for production-API gates; never discovers a user's running app."""
import json
import os
from pathlib import Path
import signal
import shlex
import shutil
import sys
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / '.derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal'
CLI = APP.parent.parent / 'Helpers/slate-term'


def eventually(label, condition, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(.04)
    raise AssertionError(f'Timed out: {label}')


class AppFixture:
    def __init__(self, name, configuration='[terminal]\nshell = "/bin/zsh"\n', *, workspace_source=None, environment=None):
        self.name, self.configuration = name, configuration
        self.extra_environment = environment or {}
        self.workspace_source = workspace_source

    def __enter__(self):
        self.root = Path(tempfile.mkdtemp(prefix='slate-api-', dir='/tmp'))
        self.config = self.root / 'config.toml'
        self.config.write_text(self.configuration)
        if self.workspace_source is not None:
            state = self.root / 'state'
            state.mkdir(mode=0o700)
            snapshot = state / 'workspace.json'
            snapshot.write_text(self.workspace_source)
            snapshot.chmod(0o600)
        startup = self.root / 'startup'
        startup.mkdir()
        (startup / '.zshenv').write_text('export HISTFILE=/dev/null\n')
        # Preserve the hook's behavior/deadline; retain otherwise-suppressed failures for diagnosis.
        trace = shlex.quote(str(self.root / 'shell-reports.log'))
        recording = '''
if (( ${+functions[_slate_context_precmd]} )); then
    _slate_fixture_body=${functions[_slate_context_precmd]}
    _slate_fixture_old='> /dev/null 2>&1'
    _slate_fixture_new='>> TRACE_PATH 2>&1; print -r -- "end $EPOCHREALTIME" >> TRACE_PATH'
    _slate_fixture_body=${_slate_fixture_body//$_slate_fixture_old/$_slate_fixture_new}
    _slate_fixture_body=${_slate_fixture_body//'"$SLATE_TERM_CLI" shell update'/'print -r -- "start $EPOCHREALTIME" >> TRACE_PATH; "$SLATE_TERM_CLI" shell update'}
    functions[_slate_context_precmd]=$_slate_fixture_body
    unset _slate_fixture_body _slate_fixture_old _slate_fixture_new
fi
'''.replace('TRACE_PATH', trace)
        (startup / '.zshrc').write_text('zmodload zsh/datetime; HISTSIZE=0; SAVEHIST=0; PS1="API_TEST> "; RPS1=""; RPROMPT=""\n' + recording)
        self.ready = self.root / 'ready'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('SLATE_TERM_')}
        self.env.update(SLATE_TERM_INTEGRATION='1', SLATE_TERM_TEST_REAL_SHELL='1',
                        SLATE_TERM_STATE_DIR=str(self.root), SLATE_TERM_CONFIG_FILE=str(self.config),
                        SLATE_TERM_SOCKET_FILE=str(self.ready), ZDOTDIR=str(startup))
        self.env.update(self.extra_environment)
        self.log = (ROOT / f'artifacts/{self.name}-process.log').open('w')
        self.process = subprocess.Popen([str(APP)], env=self.env, stdout=self.log, stderr=self.log, start_new_session=True)
        try:
            eventually('owned fixture ready', lambda: self.ready.exists() and self.process.poll() is None)
            self.path = self.ready.read_text().strip()
            self.env['SLATE_TERM_SOCKET'] = self.path
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self, *unused):
        if unused and unused[0] is not None:
            diagnostics = ROOT / f'artifacts/{self.name}-diagnostic'
            diagnostics.mkdir(exist_ok=True)
            for name in ['config.toml', 'state/workspace.json', 'shell-reports.log']:
                source = self.root / name
                if source.is_file():
                    shutil.copy2(source, diagnostics / source.name)
            (diagnostics / 'liveness.json').write_text(json.dumps(dict(pid=self.process.pid,
                exitCode=self.process.poll(), ready=self.ready.exists())) + '\n')
            if self.process.poll() is None:
                try:
                    subprocess.run(['/usr/bin/sample', str(self.process.pid), '1', '-file', str(diagnostics / 'app-sample.txt')],
                                   stdout=self.log, stderr=self.log, timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    pass
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        cleaned = False
        try:
            # Named WebKit profiles live outside the temporary state directory.
            # Remove only this fixture's profile, after all its web views/processes exit.
            profile = self.root / 'state/browser-profile.json'
            if profile.exists():
                cleanup = subprocess.run([str(APP), '--remove-test-browser-profile'], env=self.env,
                                         stdout=self.log, stderr=self.log, timeout=20)
                assert cleanup.returncode == 0, f'Fixture browser profile cleanup failed ({cleanup.returncode}); metadata: {self.root}'
            cleaned = True
        finally:
            self.log.close()
            if cleaned:
                shutil.rmtree(self.root)
            else:
                print(f'Preserved fixture ownership metadata: {self.root}', file=sys.stderr)

    def rpc(self, method, *, error=None, request_metadata=None, **params):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(35)
            client.connect(self.path)
            with client.makefile('rb') as stream:
                client.sendall(json.dumps(dict(jsonrpc='2.0', id=1, method='hello', params={'protocolVersion': 1})).encode() + b'\n')
                hello = json.loads(stream.readline(2**20))
                assert 'error' not in hello, hello
                request = dict(jsonrpc='2.0', id=2, method=method, params=params)
                if request_metadata is not None:
                    request['metadata'] = request_metadata
                client.sendall(json.dumps(request).encode() + b'\n')
                response = json.loads(stream.readline(2**20))
        if error is not None:
            assert response.get('error', {}).get('code') == error, response
            return response['error']
        assert 'error' not in response, response
        return response['result']

    def cli(self, *args, env=None, error=False):
        result = subprocess.run([str(CLI), *args, '--json'], env=env or self.env, text=True,
                                capture_output=True, timeout=35)
        if error:
            assert result.returncode != 0 and not result.stdout, result
            return json.loads(result.stderr)['error']
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
