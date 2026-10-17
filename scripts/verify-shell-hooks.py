#!/usr/bin/env python3
"""Shell hooks in real pseudo-terminals against a fake host: zsh, Apple bash 3.2, bash 5.2/5.3 and fish.
Covers reports, run claims, draft and continuation refusals, vi mode, history and startup files.
Run only through verify-vm.py."""
import json
import os
import pty
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / '.derived/Build/Products/Debug/Slate Terminal.app'
CLI = APP / 'Contents/Helpers/slate-term'
GHOSTTY = APP / 'Contents/Resources/ghostty'
SHELLS = ROOT / '.build/test-shells'
BASH_BOOTSTRAP = 'builtin source "$SLATE_TERM_BASH_INIT"'
FISH_RUN_KEY = '\U0010FFFD'

assert subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip().startswith('VirtualMac'), 'Run this gate through scripts/verify-vm.py'


def ansi_quote(command):
    return ''.join('\\x%02x' % ord(c) if ord(c) < 32 or ord(c) == 127 or c in "'\\" else c for c in command)


def fish_quote(command):
    out, open_ = '', False
    for c in command:
        if ord(c) < 32 or ord(c) == 127:
            if open_:
                out += "'"
                open_ = False
            out += '\\x%02x' % ord(c)
            continue
        if not open_:
            out += "'"
            open_ = True
        out += ('\\' + c) if c in "'\\" else c
    return out + ("'" if open_ else '')


def run_line(kind, command):
    marker_id = str(uuid.uuid4()).upper()
    if kind == 'fish':
        marker = 'true __SLATE_RUN_%s;' % marker_id
        return marker, '%s eval %s' % (marker, fish_quote(command))
    marker = ': __SLATE_RUN_%s;' % marker_id
    return marker, "%s builtin eval $'%s'" % (marker, ansi_quote(command))


class FakeHost:
    """Speaks the control protocol for shell.update and shell.runInput only."""

    def __init__(self, directory, token, pane):
        self.path = str(directory / 'host.sock')
        self.token, self.pane = token, pane
        self.reports, self.claims = [], []
        self.pending = None
        self.lock = threading.Lock()
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(self.path)
        self.server.listen(64)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()

    def handle(self, connection):
        buffer = b''
        with connection:
            while True:
                data = connection.recv(65536)
                if not data:
                    return
                buffer += data
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    request = json.loads(line)
                    reply = self.dispatch(request)
                    if 'id' in request:
                        connection.sendall(json.dumps(dict(reply, jsonrpc='2.0', id=request['id'])).encode() + b'\n')

    def dispatch(self, request):
        method, params = request['method'], request.get('params') or {}
        if method == 'hello':
            return {'result': {'protocolVersion': 1}}
        if params.get('token') != self.token or params.get('pane') != self.pane:
            return {'error': {'code': -32040, 'message': 'bad token'}}
        with self.lock:
            if method == 'shell.update':
                self.reports.append(dict(params, arrived=time.time()))
                return {'result': {'sequence': params['sequence']}}
            if method == 'shell.runInput':
                self.claims.append(params)
                if self.pending is None:
                    return {'error': {'code': -32042, 'message': 'no run'}}
                line, self.pending = self.pending, None
                if not params.get('emptyBuffer'):
                    return {'error': {'code': -32042, 'message': 'Terminal editing buffer is not empty'}}
                return {'result': line}
        return {'error': {'code': -32601, 'message': 'unknown'}}

    def sorted_reports(self):
        with self.lock:
            return sorted(self.reports, key=lambda r: r['sequence'])

    def close(self):
        self.server.close()


class Terminal:
    def __init__(self, argv, env, cwd):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execve(argv[0], argv, env)
        self.output = b''
        self.lock = threading.Lock()
        threading.Thread(target=self.pump, daemon=True).start()

    def pump(self):
        while True:
            try:
                ready, _, _ = select.select([self.fd], [], [], 0.2)
                if ready:
                    data = os.read(self.fd, 65536)
                    if not data:
                        return
                    with self.lock:
                        self.output += data
            except OSError:
                return

    def write(self, text):
        os.write(self.fd, text.encode() if isinstance(text, str) else text)

    def text(self):
        with self.lock:
            return self.output.decode('utf-8', 'replace')

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        os.close(self.fd)


def eventually(label, condition, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError('Timed out: ' + label)


def never(label, condition, duration=1.5):
    deadline = time.time() + duration
    while time.time() < deadline:
        assert not condition(), label
        time.sleep(0.05)


class Session:
    """One shell in a pseudo-terminal, wired like a Slate pane."""

    def __init__(self, name, kind, executable, profile='', setup=None):
        self.name, self.kind = name, kind
        self.root = Path(tempfile.mkdtemp(prefix='slate-hooks-', dir='/tmp'))
        self.home = self.root / 'home'
        self.home.mkdir()
        self.token, self.pane = str(uuid.uuid4()), 'p1'
        self.session_id = str(uuid.uuid4()).upper()
        self.host = FakeHost(self.root, self.token, self.pane)
        env = {
            'PATH': str(CLI.parent) + ':/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(self.home), 'TERM': 'xterm-256color',
            'LANG': 'en_US.UTF-8', 'SLATE_TERM_SOCKET': self.host.path, 'SLATE_TERM_PANE_ID': self.pane,
            'SLATE_TERM_CONTEXT_TOKEN': self.token, 'SLATE_TERM_CLI': str(CLI), 'SLATE_TERM_SHELL_PID': '',
            'SLATE_TERM_RUN_KEY': '\x1b[slate-run-%s~' % self.session_id, 'GHOSTTY_RESOURCES_DIR': str(GHOSTTY),
        }
        hooks = subprocess.check_output([str(CLI), 'shell', 'integration', '--shell', kind], text=True)
        if kind == 'zsh':
            zdot = self.root / 'zdot'
            zdot.mkdir()
            (zdot / '.zshrc').write_text(profile + '\n' + hooks)
            env['ZDOTDIR'] = str(zdot)
            argv = [executable, '-l']
        elif kind == 'bash':
            init = self.root / 'init.bash'
            init.write_text(hooks)
            (self.home / '.bash_profile').write_text(profile)
            env.update(PROMPT_COMMAND=BASH_BOOTSTRAP, SLATE_TERM_BASH_INIT=str(init))
            argv = [executable, '-l']
        else:
            init = self.root / 'init.fish'
            init.write_text(hooks)
            config = self.home / '.config/fish'
            config.mkdir(parents=True)
            (config / 'config.fish').write_text(profile)
            argv = [executable, '-l', '-C', "source '%s'" % init]
        if setup:
            setup(env)
        self.terminal = Terminal(argv, env, str(self.home))

    def reports(self):
        return self.host.sorted_reports()

    def last(self):
        reports = self.reports()
        return reports[-1] if reports else None

    def wait_prompt(self, after=0, label='prompt'):
        return eventually(self.name + ' ' + label, lambda: next(
            (r for r in self.reports() if r['state'] == 'prompt' and r['sequence'] > after), None))

    def type_line(self, text):
        self.terminal.write(text + '\r')

    def close(self):
        self.terminal.close()
        self.host.close()
        shutil.rmtree(self.root, ignore_errors=True)


def run_key(kind, session):
    return FISH_RUN_KEY if kind == 'fish' else '\x1b[slate-run-%s~' % session.session_id


def check_reports(s, runs):
    first = s.wait_prompt(label='first prompt')
    assert first['shell'] == s.kind and first['runInput'] == runs, first
    assert int(first['pid']) > 0 and first['exitCode'] == 0, first
    never(s.name + ' prompt hooks reported as a command', lambda: [r for r in s.reports() if r['state'] == 'running'], duration=1.0)
    # Startup files still load, and the very first command already reports its start.
    s.type_line('echo PROFILE-$FROM_PROFILE')
    eventually(s.name + ' profile', lambda: 'PROFILE-yes' in s.terminal.text())
    base = s.wait_prompt(first['sequence'])['sequence']
    started = [r for r in s.reports() if r['state'] == 'running' and first['sequence'] < r['sequence'] < base]
    assert [r['command'] for r in started] == ['echo PROFILE-$FROM_PROFILE'], started
    s.type_line('cd /tmp && false')
    done = s.wait_prompt(base, 'after failing command')
    running = [r for r in s.reports() if r['state'] == 'running' and base < r['sequence'] < done['sequence']]
    assert len(running) == 1 and running[0]['command'] == 'cd /tmp && false', running
    assert done['sequence'] == running[0]['sequence'] + 1, (running, done)
    assert done['exitCode'] == 1 and done['cwd'] in ('/tmp', '/private/tmp'), done
    # An empty line is a prompt without a command.
    s.type_line('')
    empty = s.wait_prompt(done['sequence'], 'empty line')
    assert not [r for r in s.reports() if r['state'] == 'running' and r['sequence'] > done['sequence']], s.reports()
    # Multi-line commands report their whole text.
    s.type_line('for i in 1 2; do echo LOOP$i; done' if s.kind != 'fish' else 'for i in 1 2; echo LOOP$i; end')
    looped = s.wait_prompt(empty['sequence'], 'loop')
    command = [r for r in s.reports() if r['state'] == 'running' and r['sequence'] > empty['sequence']][0]['command']
    assert 'LOOP' in command, command
    return looped['sequence']


def check_run(s, after, prefix=''):
    marker, line = run_line(s.kind, 'printf "RUN-%s\\n" ok')
    s.host.pending = line
    if prefix:
        # Let the line editor finish the mode switch before the run key arrives.
        s.terminal.write(prefix)
        time.sleep(0.8)
    s.terminal.write(run_key(s.kind, s))
    eventually(s.name + ' run output', lambda: 'RUN-ok' in s.terminal.text())
    running = eventually(s.name + ' run running report', lambda: next(
        (r for r in s.reports() if r['state'] == 'running' and r['command'].startswith(marker)), None))
    prompt = s.wait_prompt(running['sequence'], 'run completion')
    assert prompt['sequence'] == running['sequence'] + 1 and prompt['exitCode'] == 0, (running, prompt)
    assert s.host.claims[-1]['emptyBuffer'] is True, s.host.claims[-1]
    return prompt['sequence']


def check_draft_refusal(s, after):
    s.terminal.write('echo DRAFT-KEPT')
    eventually(s.name + ' draft echoed', lambda: 'echo DRAFT-KEPT' in s.terminal.text())
    claims = len(s.host.claims)
    s.host.pending = run_line(s.kind, 'echo MUST-NOT-RUN')[1]
    s.terminal.write(run_key(s.kind, s))
    eventually(s.name + ' refused claim', lambda: len(s.host.claims) > claims)
    assert s.host.claims[-1].get('emptyBuffer') is not True, s.host.claims[-1]
    never(s.name + ' refused run submitted something', lambda: [r for r in s.reports() if r['sequence'] > after])
    assert 'MUST-NOT-RUN' not in s.terminal.text()
    s.terminal.write('\r')
    prompt = s.wait_prompt(after, 'draft submitted by the user')
    command = [r for r in s.reports() if r['state'] == 'running' and r['sequence'] > after][0]['command']
    assert command == 'echo DRAFT-KEPT', 'The draft was changed: %r' % command
    return prompt['sequence']


def check_continuation_refusal(s, after):
    s.terminal.write('echo CONT \\\r')
    time.sleep(0.5)
    claims = len(s.host.claims)
    s.host.pending = run_line(s.kind, 'echo MUST-NOT-RUN')[1]
    s.terminal.write(run_key(s.kind, s))
    eventually(s.name + ' continuation claim', lambda: len(s.host.claims) > claims)
    assert s.host.claims[-1].get('emptyBuffer') is not True, 'Run claimed at a continuation prompt'
    never(s.name + ' continuation submitted something', lambda: [r for r in s.reports() if r['sequence'] > after])
    s.terminal.write('\x03')
    return s.wait_prompt(after, 'after cancelling continuation')['sequence']


def check_dash(s, after):
    """Command text starting with a dash is a value, never an option of the reporting CLI."""
    s.type_line('-x 2>/dev/null; echo DASH-OK')
    eventually(s.name + ' dash command', lambda: 'DASH-OK' in s.terminal.text().split('echo DASH-OK')[-1])
    prompt = s.wait_prompt(after, 'after dash command')
    texts = [r['command'] for r in s.reports() if r['state'] == 'running' and r['sequence'] > after]
    assert texts == ['-x 2>/dev/null; echo DASH-OK'], texts
    return prompt['sequence']


def check_read_refusal(s, after):
    """A program reading a line with the shell's own editor is not a prompt."""
    s.type_line('read -e -p "answer? " x; echo "GOT=[$x]"' if s.kind == 'bash' else 'read x; echo "GOT=[$x]"')
    time.sleep(1.0)
    claims = len(s.host.claims)
    s.host.pending = run_line(s.kind, 'echo MUST-NOT-RUN')[1]
    s.terminal.write(run_key(s.kind, s))
    eventually(s.name + ' claim inside read', lambda: len(s.host.claims) > claims)
    assert s.host.claims[-1].get('emptyBuffer') is not True, 'Run claimed inside read'
    s.type_line('typed')
    eventually(s.name + ' read result', lambda: 'GOT=[typed]' in s.terminal.text())
    assert 'MUST-NOT-RUN' not in s.terminal.text() and '__SLATE_RUN_' not in s.terminal.text().split('GOT=')[-1]
    return s.wait_prompt(after, 'after read')['sequence']


def check_nested(s, executable, after):
    pids = {r['pid'] for r in s.reports()}
    s.type_line(executable + (' -i' if s.kind != 'fish' else ''))
    time.sleep(1.5)
    s.type_line('echo NESTED-$$')
    eventually(s.name + ' nested shell', lambda: 'NESTED-' in s.terminal.text().split('echo NESTED-')[-1])
    s.type_line('exit')
    prompt = s.wait_prompt(after, 'after nested shell')
    assert {r['pid'] for r in s.reports()} == pids, 'A nested shell reported for the pane'
    return prompt['sequence']


def shells():
    found = [('zsh', 'zsh', '/bin/zsh', True), ('bash-3.2', 'bash', '/bin/bash', False)]
    for name in ['bash-5.2', 'bash-5.3']:
        found.append((name, 'bash', str(SHELLS / name / 'bash'), True))
    fish = SHELLS / 'fish-4' / 'fish'
    if (SHELLS / 'WITHOUT_FISH').is_file():
        print('NOT TESTED fish: the host run opted out with SLATE_TEST_SHELLS_WITHOUT_FISH=1', flush=True)
    else:
        found.append(('fish-4', 'fish', str(fish), True))
    for _, _, path, _ in found:
        assert os.access(path, os.X_OK), 'Missing test shell %s; run scripts/build-test-shells.sh on the host' % path
    return found


PROFILES = {
    'zsh': 'export FROM_PROFILE=yes\n',
    'bash': 'export FROM_PROFILE=yes\n'
            # A user hook that reads $? must still see the command's status.
            '_user_status() { echo "USER-STATUS=$?" >> "$HOME/status.log"; }\n'
            'PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}_user_status"\n',
    'fish': 'set -gx FROM_PROFILE yes\n',
}
VI = {'zsh': 'bindkey -v\n', 'bash': 'set -o vi\n', 'fish': 'fish_vi_key_bindings\n'}

for name, kind, executable, runs in shells():
    print('== ' + name, flush=True)
    s = Session(name, kind, executable, PROFILES[kind])
    try:
        after = check_reports(s, runs)
        if kind == 'bash':
            statuses = (s.home / 'status.log').read_text()
            assert 'USER-STATUS=1' in statuses, 'User PROMPT_COMMAND lost the status: ' + statuses
        if runs:
            after = check_run(s, after)
            after = check_draft_refusal(s, after)
            after = check_continuation_refusal(s, after)
            after = check_run(s, after)
        else:
            # bash 3.2 never claims input: the host refuses runs before sending a key.
            assert not s.host.claims
            assert '\x1b]133;A' in s.terminal.text(), 'bash 3.2 lacks prompt marks from the bundled script'
        if kind == 'bash':
            # A command missing from history must not report the previous entry's text.
            s.type_line('set +o history')
            after = s.wait_prompt(after)['sequence']
            s.type_line('echo NOHIST')
            after = s.wait_prompt(after)['sequence']
            texts = [r['command'] for r in s.reports() if r['state'] == 'running']
            assert texts[-1] in ('', 'echo NOHIST') and texts[-1] != 'set +o history', texts
            if runs:
                after = check_run(s, after)
        after = check_dash(s, after)
        if runs and kind != 'zsh':
            after = check_read_refusal(s, after)
        after = check_nested(s, executable, after)
        seqs = [r['sequence'] for r in s.reports()]
        assert len(seqs) == len(set(seqs)), 'Duplicate sequence numbers: %s' % seqs
        print('PASS %s reports, runs=%s' % (name, runs), flush=True)
    except BaseException:
        print(s.terminal.text()[-4000:], file=sys.stderr)
        print(json.dumps(s.reports(), indent=1)[-4000:], file=sys.stderr)
        raise
    finally:
        s.close()

    if runs:
        # vi insert and command mode both accept the run key.
        s = Session(name + ' vi', kind, executable, PROFILES[kind] + VI[kind])
        try:
            after = s.wait_prompt(label='first prompt')['sequence']
            after = check_run(s, after)
            after = check_run(s, after, prefix='\x1b')
            print('PASS %s vi insert and command mode' % name, flush=True)
        except BaseException:
            print(s.terminal.text()[-4000:], file=sys.stderr)
            raise
        finally:
            s.close()

    if kind == 'bash':
        # Strict users and prompt frameworks: set -u, extdebug, and a hook that rewrites
        # PS0, PS1 and PS2 at every prompt after Slate's first hook.
        strict = PROFILES[kind] + ('set -u\nshopt -s extdebug\n'
                                   "_fw() { PS1='fw$ '; PS2='fw> '; PS0=''; }\n"
                                   'PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}_fw"\n')
        s = Session(name + ' strict', kind, executable, strict)
        try:
            after = s.wait_prompt(label='first prompt')['sequence']
            s.type_line('true')
            after = s.wait_prompt(after)['sequence']
            after = check_dash(s, after)
            if runs:
                after = check_run(s, after)
                after = check_continuation_refusal(s, after)
                after = check_read_refusal(s, after)
                after = check_run(s, after)
            assert 'unbound variable' not in s.terminal.text(), s.terminal.text()[-2000:]
            print('PASS %s set -u, extdebug and a prompt framework' % name, flush=True)
        except BaseException:
            print(s.terminal.text()[-4000:], file=sys.stderr)
            print(json.dumps(s.reports(), indent=1)[-3000:], file=sys.stderr)
            raise
        finally:
            s.close()

        # A profile that replaces PROMPT_COMMAND removes the integration; the shell still works.
        s = Session(name + ' replaced', kind, executable, "export FROM_PROFILE=yes\nPROMPT_COMMAND='true'\n")
        try:
            s.type_line('echo ALIVE')
            eventually('shell works without integration', lambda: 'ALIVE' in s.terminal.text().split('echo ALIVE')[-1])
            never('reports without integration', lambda: s.reports(), duration=1.0)
            print('PASS %s replaced PROMPT_COMMAND means no integration' % name, flush=True)
        finally:
            s.close()

print('shell hooks ok')
