"""Response evidence stays bounded and cannot capture private calls or arguments."""
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from contract_capture import ContractCapture


class ContractCaptureTests(unittest.TestCase):
    def test_only_catalogued_responses_and_command_selector_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'capture.jsonl'
            capture = ContractCapture(path, {'contracts': {'methods': {'workspace.get': {}, 'command.run': {}}}})
            capture.record('shell.update', {'token': 'PRIVATE_TOKEN'}, {'credential': 'PRIVATE_VALUE'})
            capture.record('debug.pluginEval', {}, 'PRIVATE_BRIDGE')
            capture.record('workspace.get', {'ignored': 'PRIVATE_ARGUMENT'}, {'tabs': []})
            capture.record('command.run', {'id': 'pane.split', 'ignored': 'PRIVATE_ARGUMENT'}, {'code': -32602, 'message': 'PRIVATE_MESSAGE'}, error=True, client='bridge')
            text = path.read_text()
            self.assertNotIn('PRIVATE_', text)
            records = [json.loads(line) for line in text.splitlines()]
            self.assertEqual(len(records), 3)
            self.assertEqual(records[-1], dict(kind='response', method='command.run', command='pane.split', client='bridge', errorCode=-32602))
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_limit_rejection_never_partially_writes_an_observation(self):
        for limits in [dict(maximum_bytes=160), dict(maximum_records=1)]:
            with self.subTest(limits=limits), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'capture.jsonl'
                capture = ContractCapture(path, {'contracts': {'methods': {'workspace.get': {}}}}, **limits)
                before = path.read_bytes()
                with self.assertRaisesRegex(AssertionError, 'evidence is incomplete'):
                    capture.record('workspace.get', {}, 'x' * 200)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(capture.records, 1)


if __name__ == '__main__':
    unittest.main()
