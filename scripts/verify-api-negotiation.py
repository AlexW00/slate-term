#!/usr/bin/env python3
"""A guarded CLI must not send a mutation to a peer that cannot enforce its preconditions."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
from api_fixture import CLI


def exercise(capabilities, params, expected_error=None):
    seen, errors = [], []
    stop = threading.Event()
    with tempfile.TemporaryDirectory(prefix='slate-negotiate-', dir='/tmp') as temporary:
        path = str(Path(temporary) / 'peer.sock')
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            listener.listen()
            listener.settimeout(.1)

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
                                method = request['method']
                                if method == 'hello':
                                    result = {'protocolVersion': 1}
                                else:
                                    seen.append(request)
                                    result = capabilities if method == 'api.describe' else {'received': request['params']}
                                peer.sendall(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}).encode() + b'\n')
                except BaseException as error:
                    errors.append(error)

            worker = threading.Thread(target=serve)
            worker.start()
            try:
                environment = {k: v for k, v in os.environ.items() if not k.startswith('SLATE_TERM_')}
                result = subprocess.run([str(CLI), 'rpc', 'command.run', '--params', json.dumps(params), '--socket', path, '--json'],
                                        env=environment, capture_output=True, text=True, timeout=10)
            finally:
                stop.set()
                worker.join(timeout=3)
            assert not worker.is_alive() and not errors, errors
        mutations = [r for r in seen if r['method'] == 'command.run']
        if expected_error is not None:
            assert result.returncode != 0 and not result.stdout, result
            assert json.loads(result.stderr)['error']['code'] == expected_error, result.stderr
            assert not mutations, 'A rejected guard still reached mutation dispatch'
        else:
            assert result.returncode == 0, result.stderr
            assert len(mutations) == 1 and mutations[0]['params'] == params
            assert json.loads(result.stdout)['received'] == params
        return seen


legacy = {'apiVersion': 1, 'identityGuards': True, 'workspaceRevisions': True,
          'surface': 'administrative', 'methods': ['config.patch']}
exercise(legacy, {'id': 'window.new', 'expectedWorkspaceRevision': 'captured'})
exercise(legacy, {'id': 'window.new', 'expectedWriteRevision': 'new-guard'}, -32053)
exercise({'identityGuards': True}, {'id': 'window.new', 'expectedInstanceId': 'old'}, -32053)
exercise(legacy | {'guards': ['expectedInstanceId']}, {'id': 'window.new', 'expectedWorkspaceRevision': 'captured'}, -32053)
seen = exercise({}, {'id': 'plugin.demo.inspect', 'expectedCustomResult': 'author-owned argument'})
assert [r['method'] for r in seen] == ['command.run'], seen
print('Guard negotiation: legacy compatibility, explicit advertisement and no unsafe mutation dispatch passed')
