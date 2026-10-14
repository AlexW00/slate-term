"""Owned app fixture for production-API gates; never discovers a user's running app."""
import json
import os
from pathlib import Path
import signal
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
    def __init__(self, name, configuration='[terminal]\nshell = "/bin/zsh"\n'):
        self.name, self.configuration = name, configuration

    def __enter__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='slate-api-', dir='/tmp')
        self.root = Path(self.temporary.name)
        self.config = self.root / 'config.toml'
        self.config.write_text(self.configuration)
        startup = self.root / 'startup'
        startup.mkdir()
        (startup / '.zshenv').write_text('export HISTFILE=/dev/null\n')
        (startup / '.zshrc').write_text('HISTSIZE=0; SAVEHIST=0; PS1="API_TEST> "\n')
        self.ready = self.root / 'ready'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('SLATE_TERM_')}
        self.env.update(SLATE_TERM_INTEGRATION='1', SLATE_TERM_TEST_REAL_SHELL='1',
                        SLATE_TERM_STATE_DIR=str(self.root), SLATE_TERM_CONFIG_FILE=str(self.config),
                        SLATE_TERM_SOCKET_FILE=str(self.ready), ZDOTDIR=str(startup))
        self.log = (ROOT / f'artifacts/{self.name}-process.log').open('w')
        self.process = subprocess.Popen([str(APP)], env=self.env, stdout=self.log, stderr=self.log, start_new_session=True)
        try:
            eventually('owned fixture ready', lambda: self.ready.exists() and self.process.poll() is None)
            self.path = self.ready.read_text().strip()
            self.env['SLATE_TERM_SOCKET'] = self.path
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *unused):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.log.close()
        self.temporary.cleanup()

    def rpc(self, method, *, error=None, **params):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(35)
            client.connect(self.path)
            with client.makefile('rb') as stream:
                client.sendall(json.dumps(dict(jsonrpc='2.0', id=1, method='hello', params={'protocolVersion': 1})).encode() + b'\n')
                hello = json.loads(stream.readline(2**20))
                assert 'error' not in hello, hello
                client.sendall(json.dumps(dict(jsonrpc='2.0', id=2, method=method, params=params)).encode() + b'\n')
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
