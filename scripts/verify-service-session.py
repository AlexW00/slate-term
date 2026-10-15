#!/usr/bin/env python3
"""Window-free CLI service identity/handshake regression using only fake peers."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
from api_fixture import CLI

parser = argparse.ArgumentParser()
parser.add_argument('--cli', type=Path, default=CLI)
args = parser.parse_args()
identity = {'appInstanceId': 'app-1', 'pluginId': 'example.worker', 'serviceId': 'service-1', 'generation': 'g1'}
hello = {'protocolVersion': 1, 'serviceProtocolVersion': 1, **identity}
token = 'ab' * 32  # Fixture value, not a real credential.
credentials = {'SLATE_TERM_INSTANCE_ID': 'app-1', 'SLATE_TERM_SERVICE_PLUGIN_ID': 'example.worker',
               'SLATE_TERM_SERVICE_ID': 'service-1', 'SLATE_TERM_SERVICE_GENERATION': 'g1', 'SLATE_TERM_SERVICE_TOKEN': token}


def exercise(reply=hello, overrides=None, options=(), error=None, connects=True):
    seen, errors = [], []
    stop = threading.Event()
    with tempfile.TemporaryDirectory(prefix='slate-svc-cli-', dir='/tmp') as directory:
        path = str(Path(directory) / 'peer.sock')
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            listener.listen()
            listener.settimeout(.05)

            def serve():
                try:
                    while not stop.is_set():
                        try:
                            peer, _ = listener.accept()
                        except TimeoutError:
                            continue
                        with peer, peer.makefile('rb') as stream:
                            peer.settimeout(2)
                            while line := stream.readline(65536):
                                request = json.loads(line)
                                seen.append(request)
                                method = request['method']
                                result = reply if method == 'hello' else (
                                    {'identityGuards': True, 'guards': ['expectedInstanceId'],
                                     'causation': {'version': 1}} if method == 'api.describe' else {'ok': True})
                                peer.sendall(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}).encode() + b'\n')
                except BaseException as failure:
                    errors.append(failure)

            worker = threading.Thread(target=serve)
            worker.start()
            try:
                env = {k: v for k, v in os.environ.items() if not k.startswith('SLATE_TERM_')}
                env.update(credentials | {'SLATE_TERM_SOCKET': path, 'SLATE_TERM_PLUGIN_ID': 'other.command-owner'})
                for key, value in (overrides or {}).items():
                    if value is None:
                        env.pop(key, None)
                    else:
                        env[key] = value
                result = subprocess.run([str(args.cli), 'rpc', 'command.run', '--params', '{"id":"pane.copyID","pane":"p1"}',
                                         '--json', *options], env=env, capture_output=True, text=True, timeout=8)
            finally:
                stop.set()
                worker.join(timeout=3)
            assert not worker.is_alive() and not errors, errors
        assert bool(seen) == connects, seen
        if error is not None:
            assert result.returncode and not result.stdout, result
            assert json.loads(result.stderr)['error']['code'] == error, result.stderr
            assert all(r['method'] == 'hello' for r in seen), seen
        else:
            assert result.returncode == 0 and json.loads(result.stdout) == {'ok': True}, result.stderr
            assert [r['method'] for r in seen] == ['hello', 'api.describe', 'command.run'], seen
            assert seen[0]['params'] == {'protocolVersion': 1, 'serviceProtocolVersion': 1,
                                        'serviceId': 'service-1', 'generation': 'g1', 'token': token}, seen[0]
            assert seen[-1]['params']['expectedInstanceId'] == 'app-1'
        return seen


exercise(reply={'protocolVersion': 1}, error=-32059)  # No accidental admin promotion.
exercise()
exercise(reply=hello | {'generation': 'retired'}, error=-32059)
exercise(overrides={'SLATE_TERM_SERVICE_TOKEN': None}, error=-32059, connects=False)
exercise(overrides={'SLATE_TERM_SERVICE_UNKNOWN': 'x'}, error=-32059, connects=False)
exercise(options=('--socket', '/tmp/slate-service-other-endpoint.sock'), error=-32059, connects=False)
exercise(options=('--expected-instance-id', 'other-app'), error=-32059, connects=False)
print('PASS headless service CLI: bound handshake, no admin/cross-app fallback, partial/poisoned context rejection')
