#!/usr/bin/env python3
"""On-demand headless/mixed plugins: routing, CLI, shortcuts, cancellation and supervision."""
import concurrent.futures
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / '.derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal'
CLI = APP.parent.parent / 'Helpers/slate-term'
ARTIFACTS = ROOT / 'artifacts'
ARTIFACTS.mkdir(exist_ok=True)


def eventually(label, condition, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(.05)
    raise AssertionError(label)


def running(pid):
    result = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True, timeout=2)
    return result.returncode == 0 and result.stdout.strip() and not result.stdout.strip().startswith('Z')


with tempfile.TemporaryDirectory(prefix='slate-commands-', dir='/tmp') as temporary:
    directory = pathlib.Path(temporary)
    ready = directory / 'ready'
    config = directory / 'config.toml'
    config.write_text('[keybind]\n"cmd+shift+j" = "plugin.tools.inspect"\n[plugins.tools]\nwidth = 0.25\nside = "left"\n')
    script = directory / 'command.py'
    script.write_text('''import json,os,pathlib,subprocess,sys,time
mode=sys.argv[1]
env={k:v for k,v in os.environ.items() if k.startswith('SLATE_TERM_')}
if mode=='inspect':
 context=json.loads(subprocess.check_output([os.environ['SLATE_TERM_CLI'],'context','get']))
 print(json.dumps(dict(environment=env,context=context,cwd=os.getcwd(),args=sys.argv[2:])),flush=True)
elif mode=='split':
 time.sleep(.4)
 subprocess.run([os.environ['SLATE_TERM_CLI'],'command','run','split.left'],check=True)
elif mode=='slow':
 time.sleep(31);print('SLOW_DONE',flush=True)
elif mode=='signal':
 os.kill(os.getpid(),15)
elif mode=='fail':
 print('intentional failure',file=sys.stderr,flush=True);sys.exit(23)
elif mode=='flood':
 print('x'*200000);print('TAIL',flush=True)
elif mode=='wait':
 child=subprocess.Popen(['/bin/sleep','60'])
 pathlib.Path(sys.argv[2]).write_text(json.dumps(dict(pid=os.getpid(),child=child.pid,group=os.getpgrp())))
 print('WAITING',flush=True);time.sleep(60)
''')
    env = {k: v for k, v in os.environ.items() if not k.startswith('SLATE_TERM_')}
    env.update(SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary,
               SLATE_TERM_SOCKET_FILE=str(ready), SLATE_TERM_CONFIG_FILE=str(config), SLATE_TERM_TOKEN='parent-secret')
    log = (ARTIFACTS / 'plugin-commands-process.log').open('w')
    app = None

    def start():
        global app
        ready.unlink(missing_ok=True)
        app = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=log, start_new_session=True)
        eventually('App ready', lambda: ready.exists() and app.poll() is None)
        env['SLATE_TERM_SOCKET'] = ready.read_text().strip()

    def cli(*args, fail=False):
        result = subprocess.run([str(CLI), *args, '--json'], env=env, capture_output=True, text=True, timeout=35)
        if fail:
            assert result.returncode != 0, result.stdout
            return result.stderr
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    def rpc(method, fail=False, **params):
        return cli('rpc', method, '--params', json.dumps(params), fail=fail)

    def statuses(plugin='tools'):
        return cli('plugins', 'status', plugin)

    def register(plugin='tools', commands=None, **extra):
        manifest = dict(id=plugin, title=plugin.title(), commands=commands or [
            dict(id='inspect', title='Inspect Context', executable=sys.executable,
                 arguments=[str(script), 'inspect', 'literal $HOME; not shell'], directory=temporary,
                 environment={'SLATE_TERM_SOCKET': 'spoof', 'SLATE_TERM_PANE_ID': 'p999', 'SLATE_TERM_TOKEN': 'manifest-secret'}),
            dict(id='split', title='Split Left', executable=sys.executable, arguments=[str(script), 'split']),
            dict(id='fail', title='Fail', executable=sys.executable, arguments=[str(script), 'fail']),
            dict(id='flood', title='Output', executable=sys.executable, arguments=[str(script), 'flood']),
            dict(id='wait', title='Wait', executable=sys.executable, arguments=[str(script), 'wait', str(directory / 'wait.json')], timeoutSeconds=10),
            dict(id='timeout', title='Timeout', executable=sys.executable, arguments=[str(script), 'wait', str(directory / 'timeout.json')], timeoutSeconds=.3),
            dict(id='missing', title='Missing', executable='/nonexistent/slate-command'),
        ], **extra)
        path = directory / (plugin + '.json')
        path.write_text(json.dumps(manifest))
        cli('plugins', 'register', '--manifest', str(path))
        return manifest

    def capture(name):
        time.sleep(.3)
        rpc('debug.screenshot', settings=True, path=str(ARTIFACTS / name))

    try:
        start()
        assert rpc('config.get')['error'] is None
        assert rpc('config.get')['unavailableCommands'] == ['plugin.tools.inspect']
        assert 'Key was not handled' in rpc('debug.key', chord='cmd+shift+j', workspaceOnly=True, fail=True)
        manifest = register()
        assert statuses() == [], 'Registration must not start a process'
        assert rpc('config.get')['unavailableCommands'] == []
        commands = cli('command', 'list')
        assert any(c['id'] == 'plugin.tools.inspect' for c in commands)
        assert not any(item.get('type') == 'tools' for item in rpc('debug.paneTypeMenu'))
        assert 'Unknown pane type' in cli('panes', 'type', '--pane', 'p1', '--type', 'tools', '--force', fail=True)
        result = cli('command', 'run', 'plugin.tools.inspect')
        assert result['state'] == 'succeeded' and result['exitCode'] == 0
        assert result['stderr'] == '', 'Supervisor diagnostics must not contaminate command stderr'
        data = json.loads(result['stdout'])
        assert pathlib.Path(data['cwd']).resolve() == directory.resolve() and data['args'] == ['literal $HOME; not shell'], data
        assert data['environment']['SLATE_TERM_SOCKET'] == env['SLATE_TERM_SOCKET']
        assert data['environment']['SLATE_TERM_PANE_ID'] == 'p1'
        assert 'SLATE_TERM_TOKEN' not in data['environment'] and 'SLATE_TERM_INTEGRATION' not in data['environment']
        assert json.loads(data['environment']['SLATE_TERM_PLUGIN_SETTINGS']) == dict(side='left', width=.25)
        assert data['context']['tabId'] == 't1'
        assert 'literal $HOME' in cli('plugins', 'logs', '--instance-id', result['instanceId'])['text']
        count = len(statuses())
        rpc('debug.key', chord='cmd+shift+j')
        eventually('App shortcut invokes command', lambda: len(statuses()) == count + 1 and statuses()[-1]['state'] == 'succeeded')

        # Freeze a target before a delayed CLI mutation and a concurrent focus change.
        other = cli('tabs', 'new')['tabId']
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(cli, 'command', 'run', 'plugin.tools.split', '--pane', 'p1', '--tab', 't1')
            eventually('Split handler started', lambda: any(r['commandId'] == 'plugin.tools.split' and r['state'] == 'running' for r in statuses()))
            cli('tabs', 'focus', '--tab', other)
            future.result()
        workspace = rpc('workspace.get')
        tabs = workspace['tabs']
        assert next(t for t in tabs if t['id'] == other)['layout'] == {'kind': 'pane', 'pane': 'p2'}, tabs
        assert len(workspace['panes']) == 3
        assert 'Pane does not belong' in cli('command', 'run', 'plugin.tools.inspect', '--pane', 'p1', '--tab', other, fail=True)
        # Explicit pane-only routing must override an inherited tab, too.
        env['SLATE_TERM_TAB_ID'] = 't1'
        env['SLATE_TERM_PANE_ID'] = 'p1'
        try:
            assert cli('command', 'run', 'plugin.tools.inspect', '--pane', 'p2')['tabId'] == other
            assert cli('command', 'run', 'plugin.tools.inspect', '--tab', other)['paneId'] == 'p2'
        finally:
            env.pop('SLATE_TERM_TAB_ID'); env.pop('SLATE_TERM_PANE_ID')
        assert 'code 23' in cli('command', 'run', 'plugin.tools.fail', fail=True)
        assert 'valid exit report' in cli('command', 'run', 'plugin.tools.missing', fail=True)
        flood = cli('command', 'run', 'plugin.tools.flood')
        assert len(flood['stdout'].encode()) <= 65_536 and flood['stdout'].endswith('TAIL\n')
        assert 'exceeded' in cli('command', 'run', 'plugin.tools.timeout', fail=True)
        timed = json.loads((directory / 'timeout.json').read_text())
        eventually('Timeout cleans group', lambda: all(not running(p) for p in timed.values()))

        # Disconnect cancels; duplicate invocations do not queue.
        sock = socket.socket(socket.AF_UNIX)
        sock.connect(env['SLATE_TERM_SOCKET'])
        sock.sendall(b'{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}\n')
        sock.recv(4096)
        sock.sendall(b'{"jsonrpc":"2.0","id":2,"method":"command.run","params":{"id":"plugin.tools.wait"}}\n')
        eventually('Wait started', lambda: (directory / 'wait.json').exists())
        waiting = json.loads((directory / 'wait.json').read_text())
        assert 'already running' in cli('command', 'run', 'plugin.tools.wait', fail=True)
        sock.close()
        eventually('Disconnect kills owned group', lambda: all(not running(p) for p in waiting.values()))
        eventually('Cancelled status', lambda: any(r['commandId'] == 'plugin.tools.wait' and r['state'] == 'cancelled' for r in statuses()))

        # Mixed panel+command plugin: bridge invocation and live settings.
        assets = directory / 'assets'
        assets.mkdir()
        (assets / 'index.html').write_text('<!doctype html><title>Mixed Plugin</title><p>Command bridge fixture</p>')
        register('mixed', commands=[
                     dict(id='inspect', title='Inspect Context', executable=sys.executable, arguments=[str(script), 'inspect']),
                     dict(id='slow', title='Slow Command', executable=sys.executable, arguments=[str(script), 'slow'], timeoutSeconds=40),
                     dict(id='signal', title='Signal Exit', executable=sys.executable, arguments=[str(script), 'signal'])],
                 source=dict(kind='directory', path=str(assets), entry='index.html'))
        pane = cli('panes', 'split', '--down', '--pane', 'p1')['paneId']
        cli('panes', 'type', '--pane', pane, '--type', 'mixed', '--force')
        eventually('Panel ready', lambda: rpc('debug.pluginEval', pane=pane, script="typeof workspace === 'object'"))
        assert rpc('debug.pluginEval', pane=pane, script='workspace.settings()') == {}
        bridge = rpc('debug.pluginEval', pane=pane, script="workspace.command('plugin.tools.inspect')")
        assert bridge['state'] == 'succeeded' and bridge['paneId'] == pane
        assert rpc('debug.pluginEval', pane=pane, script="workspace.command('plugin.tools.inspect',{pane:'p2'})")['tabId'] == other
        assert rpc('debug.pluginEval', pane=pane, script=f"workspace.command('plugin.tools.inspect',{{tab:'{other}'}})")['paneId'] == 'p2'
        assert 'signal 15' in cli('command', 'run', 'plugin.mixed.signal', fail=True)
        rpc('debug.pluginEval', pane=pane, script="(window.longResult=null,workspace.command('plugin.mixed.slow').then(r=>window.longResult=r.state,e=>window.longResult=String(e)),true)")
        eventually('Bridge honors command deadline beyond 30 seconds', lambda: rpc('debug.pluginEval', pane=pane, script='window.longResult') is not None, timeout=45)
        assert rpc('debug.pluginEval', pane=pane, script='window.longResult') == 'succeeded'
        config.write_text(config.read_text() + '\n[plugins.mixed]\nanswer = 42\n')
        rpc('config.reload')
        assert rpc('debug.pluginEval', pane=pane, script='workspace.settings()') == {'answer': 42}
        count = len(statuses())
        rpc('debug.key', chord='cmd+shift+j')
        eventually('Shortcut from plugin pane', lambda: len(statuses()) == count + 1 and statuses()[-1]['state'] == 'succeeded')
        cli('panes', 'type', '--pane', pane, '--type', 'browser', '--force')
        count = len(statuses())
        rpc('debug.key', chord='cmd+shift+j')
        eventually('Shortcut from browser pane', lambda: len(statuses()) == count + 1 and statuses()[-1]['state'] == 'succeeded')

        rpc('debug.settings', section='Plugins')
        capture('plugin-commands-settings.png')
        state = rpc('debug.settings', section='Keyboard Shortcuts')
        assert 'plugin.tools.inspect' in state['commands']
        capture('plugin-commands-shortcuts.png')
        rpc('debug.settings', recordAction='Tools: Inspect Context', recordPrevious='cmd+shift+j')
        rpc('debug.key', settings=True, chord='cmd+alt+shift+j', dispatch=True)
        assert rpc('debug.settings', apply=True)['error'] is None
        assert rpc('config.get')['current']['keybind']['cmd+shift+alt+j'] == 'plugin.tools.inspect'
        rpc('debug.settings', resetAction='plugin.tools.inspect', apply=True)
        assert 'plugin.tools.inspect' not in rpc('config.get')['current']['keybind'].values()
        # Restore the fixture binding for the unregister/restart checks.
        text = config.read_text().replace('\"cmd+shift+j\" = \"unbound\"', '\"cmd+shift+j\" = \"plugin.tools.inspect\"')
        config.write_text(text)
        rpc('config.reload')
        rpc('debug.menuPreview', menu='Workspace', submenu='Plugin Commands', path=str(ARTIFACTS / 'plugin-commands-menu.png'))

        # Unregister cancels active jobs and retains inactive keybindings; registration survives restart.
        (directory / 'wait.json').unlink()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(cli, 'command', 'run', 'plugin.tools.wait', fail=True)
            eventually('Second wait started', lambda: (directory / 'wait.json').exists())
            waiting = json.loads((directory / 'wait.json').read_text())
            active = next(r for r in statuses() if r['commandId'] == 'plugin.tools.wait' and r['state'] == 'running')
            cli('plugins', 'unregister', 'tools')
            assert 'unregistered or replaced' in future.result()
            assert 'WAITING' in cli('plugins', 'logs', '--instance-id', active['instanceId'])['text']
        eventually('Unregister kills group', lambda: all(not running(p) for p in waiting.values()))
        assert rpc('config.get')['unavailableCommands'] == ['plugin.tools.inspect']
        assert 'Key was not handled' in rpc('debug.key', chord='cmd+shift+j', workspaceOnly=True, fail=True)
        register()
        app.terminate(); app.wait(timeout=10)
        start()
        assert any(c['id'] == 'plugin.tools.inspect' for c in cli('command', 'list'))
        assert cli('command', 'run', 'plugin.tools.inspect')['state'] == 'succeeded'

        # Supervisor removes command descendants even when the app is killed abruptly.
        (directory / 'wait.json').unlink()
        process = subprocess.Popen([str(CLI), 'command', 'run', 'plugin.tools.wait'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            eventually('Crash fixture started', lambda: (directory / 'wait.json').exists())
            waiting = json.loads((directory / 'wait.json').read_text())
            app.kill(); app.wait(timeout=10)
            eventually('App crash kills command group', lambda: all(not running(p) for p in waiting.values()))
        finally:
            process.communicate(timeout=10)
        print('Plugin commands verified: manifest/catalog, CLI, routing, settings, shortcuts across panes, bridge, errors, logs, cancellation, timeout, restart, crash cleanup.')
    finally:
        if app and app.poll() is None:
            app.terminate()
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill(); app.wait()
        log.close()
