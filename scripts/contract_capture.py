"""Bounded, opt-in response evidence from owned API fixtures, not application logging."""
import json
import threading


class ContractCapture:
    def __init__(self, path, description, *, maximum_bytes=32 * 1024 * 1024, maximum_records=4000):
        self.path = path
        self.methods = frozenset(description['contracts']['methods'])
        self.maximum_bytes = maximum_bytes
        self.maximum_records = maximum_records
        self.bytes = 0
        self.records = 0
        self.lock = threading.Lock()
        # Capture files contain fixture results only. Never save caller parameters,
        # bridge credentials, hello/session environment, or private/debug responses.
        with path.open('w'):
            path.chmod(0o600)
        self._append(dict(kind='description', value=description))

    def _append(self, value):
        encoded = (json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf-8')
        with self.lock:
            assert self.bytes + len(encoded) <= self.maximum_bytes, 'Contract capture byte limit exceeded; evidence is incomplete'
            assert self.records < self.maximum_records, 'Contract capture record limit exceeded; evidence is incomplete'
            with self.path.open('ab') as output:
                output.write(encoded)
            self.bytes += len(encoded)
            self.records += 1

    def record(self, method, params, value, *, error=False, client='socket'):
        if method not in self.methods:
            return
        observation = dict(kind='response', method=method, client=client)
        if method == 'command.run' and isinstance(params.get('id'), str):
            observation['command'] = params['id']
        if error:
            observation['errorCode'] = value['code']
        else:
            observation['result'] = value
        self._append(observation)
