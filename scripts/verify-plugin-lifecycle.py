#!/usr/bin/env python3
"""Persistent plugin lifecycle through native callbacks, CLI and registered pages."""
import json
import os
import subprocess
import time
from api_fixture import AppFixture, APP, CLI, ROOT, eventually

with AppFixture('plugin-lifecycle') as app:
    app.rpc('debug.activate')
    assets = app.root / 'panel'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Lifecycle fixture</title><p>Plugin lifecycle</p>')
    manifest = dict(id='lifecycle', title='Lifecycle Fixture', source=dict(kind='directory', path=str(assets)),
                    commands=[dict(id='wait', title='Wait', executable='/bin/sleep', arguments=['20'])],
                    headerButtons=[dict(id='wait', title='Wait', symbol='clock', command='wait')],
                    service=dict(executable='/bin/sleep', arguments=['60']))
    app.rpc('plugins.register', manifest=manifest)
    description = app.rpc('api.describe')
    assert description['pluginManagement']['persisted']
    assert {'plugins.enable', 'plugins.disable'} <= set(description['methods'])
    assert app.cli('plugins', 'list')[0]['enabled']
    assert 'plugin.lifecycle.wait' in {c['id'] for c in app.rpc('command.list')}
    app.rpc('plugins.disable', id='missing', error=-32602)
    app.rpc('plugins.disable', id='lifecycle', force='yes', error=-32602)
    app.rpc('plugins.disable', id='lifecycle', unexpected=True, error=-32602)
    pane = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=pane, type='lifecycle', force=True)
    eventually('plugin document', lambda: app.rpc('web.get', pane=pane).get('documentId'))
    instance = app.rpc('pane.inspect', pane=pane)['pluginInstanceId']
    app.rpc('storage.set', instanceId=instance, key='draft', value='keep me')
    before = app.rpc('workspace.get')
    app.rpc('plugins.disable', id='lifecycle', error=-32010)
    app.rpc('plugins.unregister', id='lifecycle', error=-32010)
    assert app.rpc('workspace.get') == before
    state = app.rpc('debug.settings', section='Plugins', changePlugin='lifecycle', pluginAction='disable')
    assert state['pluginEnabled']['lifecycle'] and app.rpc('workspace.get') == before
    app.rpc('debug.settings', changePlugin='lifecycle', pluginAction='disable', confirmPluginChange=True,
            changeWhileConfirming='stale confirmation')
    assert app.rpc('plugins.list')[0]['enabled'], 'Stale native confirmation must not close panes'
    app.rpc('command.run', id='tab.focus', tab='t1')
    # A failed catalog write must not close panes or remove contributions.
    catalog = app.root / 'state/plugins.json'
    saved = catalog.read_bytes()
    catalog.chmod(0o644)
    try:
        failure = app.cli('plugins', 'disable', 'lifecycle', '--force', error=True)
        assert failure and app.rpc('pane.inspect', pane=pane)['type'] == 'lifecycle'
        assert catalog.read_bytes() == saved and app.rpc('plugins.list')[0]['enabled']
    finally:
        catalog.chmod(0o600)
    service = app.rpc('plugins.service.start', id='lifecycle')
    service_pid = service['pid']
    assert service_pid, service
    def service_exited():
        try:
            os.kill(service_pid, 0)
            return False
        except ProcessLookupError:
            return True
    running = subprocess.Popen([str(CLI), 'command', 'run', 'plugin.lifecycle.wait', '--json'],
                               env=app.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        eventually('command running', lambda: any(s.get('state') == 'running' for s in app.rpc('plugins.status', id='lifecycle')))
        state = app.rpc('debug.settings', section='Plugins', changePlugin='lifecycle', pluginAction='disable',
                        confirmPluginChange=True, confirmationScreenshot=str(ROOT / 'artifacts/settings-plugin-disable-confirmation.png'))
        stdout, stderr = running.communicate(timeout=10)
        assert running.returncode != 0 and not stdout and json.loads(stderr)['error']
        eventually('command cleanup', lambda: all(not s.get('cleanupPending', False) for s in app.rpc('plugins.status', id='lifecycle')))
        assert not app.rpc('plugins.service.list'), 'Disabled service must be unavailable'
        eventually('owned service process exited', service_exited)
        app.rpc('debug.pluginEval', pane=pane, script='await workspace.call("plugins.enable",{id:"lifecycle"})', error=-32602)
    finally:
        if running.poll() is None:
            running.terminate()
            running.wait(timeout=5)
    assert not state['pluginEnabled']['lifecycle'] and state['pluginStatuses'] == ['Disabled']
    assert state['pluginIndicators']['lifecycle'] == 'pause.circle.fill'
    assert pane not in {p['id'] for p in app.rpc('panes.list')}
    assert 'plugin.lifecycle.wait' not in {c['id'] for c in app.rpc('command.list')}
    app.rpc('command.run', id='plugin.lifecycle.wait', error=-32601)
    app.rpc('command.run', id='pane.type', pane='p1', type='lifecycle', force=True, error=-32602)
    app.rpc('plugins.service.start', id='lifecycle', error=-32602)
    cursor = app.rpc('events.head')['cursor']
    unchanged = app.cli('plugins', 'disable', 'lifecycle')
    assert unchanged['outcome'] == 'unchanged'
    assert not app.rpc('events.poll', after=cursor, topics=['host.plugins.changed'], waitMilliseconds=0)['events']
    time.sleep(.3)
    app.rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-plugin-disabled.png'))
    # Restart the owned fixture against the same private state to verify startup filtering.
    app.process.terminate()
    app.process.wait(timeout=10)
    app.ready.unlink()
    app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
    eventually('restarted fixture', lambda: app.ready.exists() and app.process.poll() is None)
    app.path = app.ready.read_text().strip()
    app.env['SLATE_TERM_SOCKET'] = app.path
    app.rpc('debug.activate')
    assert not app.cli('plugins', 'list')[0]['enabled']
    assert 'plugin.lifecycle.wait' not in {c['id'] for c in app.rpc('command.list')}
    assert app.cli('plugins', 'enable', 'lifecycle')['enabled']
    assert not app.rpc('plugins.status'), 'Enable must not activate a panel or command'
    assert app.rpc('plugins.service.status', id='lifecycle')['state'] == 'stopped'
    pane = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=pane, type='lifecycle', force=True)
    eventually('enabled panel', lambda: app.rpc('web.get', pane=pane).get('documentId'))
    # Scoped data files remain on disk even though the original pane was explicitly closed.
    assert any('keep me' in p.read_text() for p in (app.root / 'state/plugin-data').rglob('*.json'))
    controller = dict(id='controller', title='Controller', source=dict(kind='directory', path=str(assets)))
    app.rpc('plugins.register', manifest=controller)
    control_pane = app.rpc('command.run', id='split.down', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=control_pane, type='controller', force=True)
    eventually('controller bridge', lambda: app.rpc('debug.pluginEval', pane=control_pane, script='typeof workspace') == 'object')
    def bridge(method, params):
        return app.rpc('debug.pluginEval', pane=control_pane,
                       script='await workspace.call(' + json.dumps(method) + ',' + json.dumps(params) + ')')
    assert bridge('api.describe', {})['pluginManagement'] == description['pluginManagement']
    cursor = app.rpc('events.head')['cursor']
    bridge('plugins.disable', dict(id='lifecycle', force=True))
    fact = app.rpc('events.poll', after=cursor, topics=['host.plugins.changed'], waitMilliseconds=0)['events'][-1]['payload']
    assert fact['origin']['kind'] == 'plugin' and fact['enabled'] is False and fact['registered']
    bridge('plugins.enable', dict(id='lifecycle'))
    state = app.rpc('debug.settings', section='Plugins', width=740, height=520)
    assert state['pluginEnabled']['lifecycle']
    time.sleep(.3)
    app.rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-plugin-enabled.png'))
    state = app.rpc('debug.settings', changePlugin='lifecycle', pluginAction='remove', confirmPluginChange=True, replaceWhileConfirming=True)
    assert 'lifecycle' in state['pluginEnabled'] and 'registration changed' in state['error'], state
    state = app.rpc('debug.settings', changePlugin='lifecycle', pluginAction='remove')
    assert 'lifecycle' in state['pluginEnabled'], 'Cancel must retain registration'
    state = app.rpc('debug.settings', changePlugin='lifecycle', pluginAction='remove', confirmPluginChange=True)
    assert 'lifecycle' not in state['pluginEnabled']
    app.rpc('plugins.unregister', id='controller', force=True)
    state = app.rpc('debug.settings', section='Plugins')
    assert not state['pluginStatuses']
    time.sleep(.3)
    app.rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-plugin-empty.png'))
    app.rpc('debug.settings', section='Keyboard Shortcuts', width=740, height=520)
    time.sleep(.3)
    app.rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-shortcut-record.png'))
print('PASS plugin lifecycle persistence, native consent/cancellation/stale guards, CLI/page parity, failure atomicity, contribution filtering, saved data and status UI')
