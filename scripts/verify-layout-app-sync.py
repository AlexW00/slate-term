#!/usr/bin/env python3
"""VM-only live plugin synchronization, startup preservation and bootstrap leases."""
import ctypes
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import uuid

import api_fixture
from api_fixture import AppFixture, ROOT, eventually
from plugin_package_fixture import package_fixture

spec = importlib.util.spec_from_file_location('layout_app_sync_fixture', Path(__file__).with_name('verify-layout-apps.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
PLUGIN = 'sync-fixture'


def package(parent, version, *, commands=False):
    assets = parent.root / ('sync-' + version)
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Sync fixture</title><script>window.syncVersion=' + json.dumps(version) + '</script><p>Owned sync fixture</p>')
    manifest = {'id': PLUGIN, 'title': 'Sync Fixture', 'version': version,
        'scope': 'global', 'source': {'kind': 'directory', 'path': str(assets)}}
    if commands:
        manifest['commands'] = [{'id': 'noop', 'title': 'No-op', 'executable': '/usr/bin/true'}]
    return package_fixture(manifest, parent.root)


def plugin(app):
    return next((row for row in app.rpc('plugins.list') if row['id'] == PLUGIN), None)


def wait_plugin(app, predicate, label):
    eventually(label, lambda: predicate(plugin(app)), timeout=20)


def open_panel(app, version):
    pane = app.rpc('command.run', id='split.right', pane=app.pane('terminal'))['paneId']
    app.rpc('command.run', id='pane.type', pane=pane, type=PLUGIN, force=True)
    eventually('rendered plugin generation ' + version,
        lambda: app.rpc('debug.pluginEval', pane=pane, script='window.syncVersion') == version)
    return pane


def retains(app, installed, pane=None, version=None, duration=4.5):
    """Observe retention after separately establishing deferral or a synchronization failure."""
    deadline = time.monotonic() + duration
    observations = 0
    while time.monotonic() < deadline:
        current = plugin(app)
        assert current is not None and current['installationID'] == installed['installationID'], current
        assert current['enabled'] == installed['enabled'] and current['available'], current
        assert Path(current['packageRoot']).is_dir()
        if pane is not None:
            assert app.rpc('debug.pluginEval', pane=pane, script='window.syncVersion') == version
        observations += 1
        time.sleep(.1)
    return observations



def prepared_plugin_sync(child):
    status = {}
    def paused():
        status.update(child.rpc('debug.layoutPluginPreparation', action='status'))
        return status['phase'] == 'paused'
    eventually('live plugin preparation paused before publication', paused, timeout=60)
    assert len(status['packages']) == 1 and status['packages'][0]['id'] == PLUGIN, status
    directory = Path(status['packages'][0]['directory'])
    assert directory.is_dir() and directory.resolve().is_relative_to((child.root / 'plugins/.staging').resolve()), status
    return status


def plugin_sync_finished(child):
    eventually('live plugin synchronization completed',
               lambda: not child.rpc('debug.layoutPluginPreparation', action='status')['running'], timeout=30)



def plugin_sync_deferred(child):
    status = {}
    def deferred():
        status.update(child.rpc('debug.layoutPluginPreparation', action='status'))
        return not status['running'] and status['deferredCount'] > 0 and status['diagnostic'] is None
    eventually('live synchronization deferred an active plugin change', deferred, timeout=30)
    return status


def local_registry_retry(parent, child, evidence):
    plugin_sync_finished(child)
    baseline = child.rpc('debug.layoutPluginPreparation', action='status')
    assert baseline['diagnostic'] is None, baseline
    registry = child.root / 'plugins/registry.json'
    original_mode = registry.stat().st_mode & 0o777
    try:
        registry.chmod(0o400)
        parent.rpc('plugins.enable', id=PLUGIN)
        parent_snapshot = (parent.root / 'plugins/registry.json').read_bytes()
        failure = {}
        def failed():
            failure.update(child.rpc('debug.layoutPluginPreparation', action='status'))
            return failure['retryPending'] and failure['diagnostic'] is not None and not failure['running']
        eventually('local registry write failure schedules retry', failed, timeout=30)
        assert not plugin(child)['enabled']
        registry.chmod(original_mode)
        recovered = {}
        def retried():
            recovered.update(child.rpc('debug.layoutPluginPreparation', action='status'))
            return (recovered['retryCount'] > baseline['retryCount'] and recovered['diagnostic'] is None
                    and not recovered['retryPending'] and not recovered['running'] and plugin(child)['enabled'])
        eventually('timer retries local failure without another parent edit', retried, timeout=30)
        assert (parent.root / 'plugins/registry.json').read_bytes() == parent_snapshot
        evidence['checks']['local-registry-failure-retried'] = {
            'failure': failure['diagnostic'], 'timerRetries': recovered['retryCount'] - baseline['retryCount'],
            'parentInventoryUnchanged': True, 'enabledAfterRepair': True}
    finally:
        registry.chmod(original_mode)


def pane_opened_during_preparation(parent, child, installed, evidence):
    try:
        child.rpc('debug.layoutPluginPreparation', action='arm')
        parent.rpc('plugins.register', packagePath=package(parent, '2.0.0'), replace=True)
        paused = prepared_plugin_sync(child)
        assert child.rpc('version')
        assert child.rpc('workspace.snapshot')
        pane = open_panel(child, '1.0.0')
        child.rpc('debug.layoutPluginPreparation', action='release')
        plugin_sync_finished(child)
        status = child.rpc('debug.layoutPluginPreparation', action='status')
        assert PLUGIN in status['pendingPlugins'], status
        assert status['deferredCount'] > 0 and status['diagnostic'] is None, status
        assert plugin(child)['installationID'] == installed['installationID'] and plugin(child)['enabled']
        assert child.rpc('debug.pluginEval', pane=pane, script='window.syncVersion') == '1.0.0'
        evidence['checks']['pane-opened-during-preparation-deferred'] = {
            'pane': pane, 'preparation': paused, 'versionAndWorkspaceResponsive': True,
            'retainedInstallationID': installed['installationID']}
        return pane
    finally:
        child.rpc('debug.layoutPluginPreparation', action='release')


def changed_parent_during_preparation(parent, child, evidence):
    parent.rpc('plugins.register', packagePath=package(parent, '5.0.0'))
    wait_plugin(child, lambda row: row is not None and row['version'] == '5.0.0', 'plugin installed for parent-change check')
    cursor = child.rpc('events.head')['cursor']
    try:
        child.rpc('debug.layoutPluginPreparation', action='arm')
        parent.rpc('plugins.register', packagePath=package(parent, '6.0.0'), replace=True)
        paused = prepared_plugin_sync(child)
        prepared = paused['packages'][0]
        parent.rpc('plugins.register', packagePath=package(parent, '7.0.0'), replace=True)
        parent.rpc('plugins.disable', id=PLUGIN)
        child.rpc('debug.layoutPluginPreparation', action='release')
        wait_plugin(child, lambda row: row is not None and row['version'] == '7.0.0' and not row['enabled'],
                    'coalesced parent package and enabled state applied')
        plugin_sync_finished(child)
        assert not Path(prepared['directory']).exists(), 'Stale package preparation leaked staging files'
        assert plugin(child)['installationID'] != prepared['installationID']
        events = child.rpc('events.poll', after=cursor, topics=['host.plugins.changed'],
                           recipient='all', scope='global', waitMilliseconds=0)['events']
        assert all(row['payload'].get('installationID') != prepared['installationID'] for row in events), events
        evidence['checks']['parent-changed-during-preparation-retried'] = {
            'discardedPreparation': prepared, 'appliedVersion': '7.0.0', 'enabled': False,
            'staleGenerationPublished': False, 'stagingRemoved': True}
    finally:
        child.rpc('debug.layoutPluginPreparation', action='release')
    local_registry_retry(parent, child, evidence)
    parent.rpc('plugins.unregister', id=PLUGIN)
    wait_plugin(child, lambda row: row is None, 'parent-change fixture removed')


def stopped_plugin_changes(parent, child, evidence):
    parent.rpc('plugins.register', packagePath=package(parent, '4.0.0'))
    wait_plugin(child, lambda row: row is not None and row['version'] == '4.0.0', 'plugin installed for stopped-app checks')
    for change in ['disable', 'replace', 'unregister']:
        installed = plugin(child)
        pane = open_panel(child, installed['version'])
        child.stop()
        state = child.root / 'state/workspace.json'
        snapshot = state.read_bytes()
        if change == 'replace':
            parent.rpc('plugins.register', packagePath=package(parent, '4.1.0'), replace=True)
        else:
            parent.rpc('plugins.' + change, id=PLUGIN)
        assert state.read_bytes() == snapshot, 'Parent plugin change modified the stopped child workspace'
        child.start()
        assert any(row['id'] == pane and row['type'] == {'registered': {'_0': PLUGIN}} for row in child.panes()), child.panes()
        eventually('restored plugin document ready after ' + change,
                  lambda: child.rpc('debug.pluginEval', pane=pane, script='window.syncVersion') == installed['version'])
        deferred = plugin_sync_deferred(child)
        observations = retains(child, installed, pane, installed['version'])
        child.rpc('command.run', id='pane.close', pane=pane, force=True)
        if change == 'disable':
            wait_plugin(child, lambda row: row is not None and not row['enabled'], 'stopped-app disable applied after restored pane closes')
            parent.rpc('plugins.enable', id=PLUGIN)
            wait_plugin(child, lambda row: row is not None and row['enabled'], 'stopped-app plugin re-enabled')
        elif change == 'replace':
            wait_plugin(child, lambda row: row is not None and row['version'] == '4.1.0' and row['installationID'] != installed['installationID'],
                        'stopped-app update applied after restored pane closes')
            eventually('stopped-app old generation retired', lambda: not Path(installed['packageRoot']).exists())
        else:
            wait_plugin(child, lambda row: row is None, 'stopped-app removal applied after restored pane closes')
            eventually('stopped-app removed generation retired', lambda: not Path(installed['packageRoot']).exists())
        evidence['checks']['stopped-' + change + '-deferred'] = {
            'restoredPane': pane, 'retainedInstallationID': installed['installationID'],
            'retainedVersion': installed['version'], 'deferredCount': deferred['deferredCount'],
            'samples': observations, 'appliedAfterPaneClosed': True}



def stopped_without_plugin_panes(parent, child, evidence):
    def cleanup_rows():
        return [row for row in child.rpc('plugins.status', id=PLUGIN) if row.get('kind') == 'packageCleanup']
    parent.rpc('plugins.register', packagePath=package(parent, '8.0.0'))
    wait_plugin(child, lambda row: row is not None and row['version'] == '8.0.0', 'no-pane startup fixture installed')
    previous = plugin(child)
    child.stop()
    parent.rpc('plugins.register', packagePath=package(parent, '9.0.0'), replace=True)
    child.start()
    assert plugin(child)['version'] == '9.0.0'
    assert not Path(previous['packageRoot']).exists(), 'Startup replacement retained a known panel-only generation'
    eventually('startup replacement has no cleanup diagnostic', lambda: cleanup_rows() == [])
    evidence['checks']['stopped-no-pane-replacement-retired'] = {'removedRoot': previous['packageRoot'], 'cleanupPending': False}

    previous = plugin(child)
    child.stop()
    orphan_generation = Path(previous['packageRoot']).parent.parent / str(uuid.uuid4())
    orphan_generation.mkdir(mode=0o700)
    orphan = orphan_generation / 'contents'
    orphan.mkdir(mode=0o700)
    marker = orphan / 'unknown-prior-owner'
    marker.write_bytes(b'Preserve this pre-existing orphan generation.\n')
    marker.chmod(0o600)
    parent.rpc('plugins.unregister', id=PLUGIN)
    child.start()
    assert plugin(child) is None
    assert not Path(previous['packageRoot']).exists(), 'Startup removal retained a known panel-only generation'
    assert marker.read_bytes() == b'Preserve this pre-existing orphan generation.\n'
    assert {Path(row['packageRoot']).resolve() for row in cleanup_rows()} == {orphan.resolve()}
    evidence['checks']['stopped-no-pane-removal-retired'] = {
        'removedRoot': previous['packageRoot'], 'preexistingOrphanRetained': str(orphan)}

    parent.rpc('plugins.register', packagePath=package(parent, '10.0.0', commands=True))
    wait_plugin(child, lambda row: row is not None and row['version'] == '10.0.0', 'process-capable startup fixture installed')
    previous = plugin(child)
    child.stop()
    parent.rpc('plugins.unregister', id=PLUGIN)
    child.start()
    assert plugin(child) is None and Path(previous['packageRoot']).is_dir()
    assert {Path(row['packageRoot']).resolve() for row in cleanup_rows()} == {orphan.resolve(), Path(previous['packageRoot']).resolve()}
    evidence['checks']['stopped-process-capable-generation-retained'] = {
        'retainedRoot': previous['packageRoot'], 'reason': 'Previous-session process cleanup cannot be confirmed'}


def child_environment(app):
    return {key: value for key, value in app.env.items() if key != 'SLATE_TERM_SOCKET'}


def run_shell(app, arguments=()):
    return subprocess.run([str(app.executable), *arguments], env=child_environment(app), capture_output=True, text=True, timeout=40)


class NativeWindows:
    """Read WindowServer's actual windows without activating or controlling another app."""
    def __init__(self):
        self.cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        self.cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
        self.cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
        self.cf.CFPropertyListCreateData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_ulong, ctypes.c_void_p]
        self.cf.CFPropertyListCreateData.restype = ctypes.c_void_p
        self.cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
        self.cf.CFDataGetLength.restype = ctypes.c_long
        self.cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
        self.cf.CFDataGetBytePtr.restype = ctypes.c_void_p
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]

    def owned(self, pid):
        array = self.cg.CGWindowListCopyWindowInfo(0, 0)
        assert array, 'WindowServer window enumeration unavailable'
        data = None
        try:
            data = self.cf.CFPropertyListCreateData(None, array, 100, 0, None)
            assert data, 'WindowServer window serialization unavailable'
            rows = plistlib.loads(ctypes.string_at(self.cf.CFDataGetBytePtr(data), self.cf.CFDataGetLength(data)))
            return [row for row in rows if row.get('kCGWindowOwnerPID') == pid and row.get('kCGWindowLayer') == 0]
        finally:
            if data:
                self.cf.CFRelease(data)
            self.cf.CFRelease(array)


def startup_failure(app, name, windows):
    log = ROOT / ('artifacts/layout-app-sync-' + name + '.log')
    observations = 0
    with log.open('w') as output:
        process = subprocess.Popen([str(app.executable)], env=child_environment(app), stdout=output, stderr=output)
        try:
            deadline = time.monotonic() + 30
            while process.poll() is None:
                assert not windows.owned(process.pid), 'Failed startup published a native window'
                observations += 1
                assert time.monotonic() < deadline, 'Failed startup did not terminate'
                time.sleep(.01)
            assert process.returncode == 1, (process.returncode, log.read_text())
            assert not windows.owned(process.pid)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    text = log.read_text()
    assert 'startup failed:' in text and 'initial workspace reconciled' not in text, text
    assert 'creating terminal surface' not in text, text
    assert not list((app.root / 'control').glob('*.sock')), 'Failed startup retained a control endpoint'
    return {'exitCode': process.returncode, 'windowSamples': observations, 'log': log.name,
            'workspacePublicationReached': False, 'nativeWindowsObserved': 0}



def maintenance_contention(app, windows, evidence):
    expected_panes = [(row['id'], row['type']) for row in app.panes()]
    app.stop()
    state = app.root / 'state/workspace.json'
    runtime = app.bundle / 'Contents/Frameworks/SlateRuntime.framework/SlateRuntime'
    lock = app.root / 'maintenance.lock'
    revision = hashlib.sha256(runtime.read_bytes()).hexdigest()
    before = state.read_bytes()
    with lock.open('r+b') as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        busy = run_shell(app, ['--slate-refresh-only', '--expected-bundle-revision', revision])
        assert busy.returncode == 75, (busy.returncode, busy.stderr)
    assert state.read_bytes() == before
    assert hashlib.sha256(runtime.read_bytes()).hexdigest() == revision
    evidence['checks']['maintenance-lease-refused-without-mutation'] = 'passed'

    for outcome in ['released', 'timeout']:
        before = state.read_bytes()
        log = ROOT / ('artifacts/layout-app-sync-maintenance-' + outcome + '.log')
        process = None
        samples = 0
        with lock.open('r+b') as held, log.open('w') as output:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                process = subprocess.Popen([str(app.executable)], env=child_environment(app), stdout=output, stderr=output)
                def waiting():
                    assert process.poll() is None, (process.returncode, log.read_text())
                    return 'layout app waiting for maintenance lease' in log.read_text()
                eventually('ordinary launch reached maintenance contention', waiting, timeout=15)
                wait_observed = time.monotonic()
                def unpublished():
                    assert not windows.owned(process.pid), 'Waiting bootstrap published a native window'
                    assert not list((app.root / 'control').glob('*.sock')), 'Waiting bootstrap published a control endpoint'
                    assert 'creating workspace host' not in log.read_text(), log.read_text()
                unpublished()
                samples += 1
                assert state.read_bytes() == before
                assert hashlib.sha256(runtime.read_bytes()).hexdigest() == revision
                if outcome == 'released':
                    # Start the hold from observed contention, beyond the former ten-second limit.
                    while time.monotonic() - wait_observed < 12:
                        assert process.poll() is None, (process.returncode, log.read_text())
                        unpublished()
                        samples += 1
                        time.sleep(.1)
                    waited_seconds = time.monotonic() - wait_observed
                    fcntl.flock(held, fcntl.LOCK_UN)
                    app.pid = process.pid
                    def restored():
                        assert process.poll() is None, (process.returncode, log.read_text())
                        sockets = list((app.root / 'control').glob('*.sock'))
                        if len(sockets) != 1:
                            return False
                        app.path = str(sockets[0])
                        try:
                            description = app.rpc('api.describe')
                            assert description['layoutAppID'] == app.record['layoutAppID'], description
                            return bool(app.rpc('workspace.get')['panes']) and bool(app.rpc('window.list')['windows'])
                        except (OSError, ValueError):
                            return False
                    eventually('ordinary launch resumed after maintenance release', restored, timeout=40)
                    app.env['SLATE_TERM_SOCKET'] = app.path
                    assert [(row['id'], row['type']) for row in app.panes()] == expected_panes
                    fixture.jxa(fixture.TERMINATE, process.pid, app.bundle.resolve())
                    assert process.wait(timeout=20) == 0, log.read_text()
                    app.pid = None
                else:
                    deadline = wait_observed + 75
                    while process.poll() is None:
                        unpublished()
                        samples += 1
                        assert time.monotonic() < deadline, 'Maintenance wait did not time out'
                        time.sleep(.1)
                    waited_seconds = time.monotonic() - wait_observed
                    assert 59 <= waited_seconds < 75, ('Expected bounded sixty-second wait', waited_seconds)
                    assert process.returncode == 75, (process.returncode, log.read_text())
                    unpublished()
                    assert state.read_bytes() == before
                assert hashlib.sha256(runtime.read_bytes()).hexdigest() == revision
                evidence['checks']['ordinary-maintenance-' + outcome] = {
                    'contentionObserved': True, 'waitedSecondsAfterObservation': waited_seconds,
                    'normalWaitLimitSeconds': 60, 'windowSamplesWhileHeld': samples, 'nativeWindowsWhileHeld': 0,
                    'restoredPaneIDs': [pane for pane, _ in expected_panes] if outcome == 'released' else None,
                    'exitCode': process.returncode, 'log': log.name}
            finally:
                if process is not None:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                    if app.pid == process.pid:
                        app.pid = None
    app.start()


def main():
    fixture.require_vm()
    windows = NativeWindows()
    evidence = {'checks': {}}
    try:
        with AppFixture('layout-app-sync', startup_timeout=40) as parent:
            parent.capture_contracts()
            layout_id = str(uuid.uuid4())
            definition = {'version': 1, 'id': layout_id, 'name': 'Sync fixture', 'tabs': [{
                'name': 'Sync', 'layout': {'kind': 'pane', 'pane': 'p1'},
                'panes': [{'id': 'p1', 'type': 'terminal', 'configuration': {'directory': str(parent.root)}}]}]}
            parent.rpc('layouts.create', definition=definition)
            apps = []
            for name in ['sync', 'corrupt', 'missing']:
                record = parent.rpc('layouts.launcher', id=layout_id, name=name, path=str(parent.root / (name + '.app')))
                apps.append(fixture.LayoutApp(parent, record, name))
            child, corrupt, missing = apps
            try:
                child.start()
                assert plugin(child) is None
                plugin_sync_finished(child)
                empty = child.rpc('debug.layoutPluginPreparation', action='status')
                assert empty['diagnostic'] is None and not empty['retryPending'], empty
                assert not (parent.root / 'plugins/registry.json').exists()
                evidence['checks']['never-installed-parent-is-empty'] = empty
                parent.rpc('plugins.register', packagePath=package(parent, '1.0.0'))
                parent.rpc('plugins.disable', id=PLUGIN)
                wait_plugin(child, lambda row: row is not None and row['version'] == '1.0.0' and not row['enabled'], 'live install and disabled state')
                parent.rpc('plugins.enable', id=PLUGIN)
                wait_plugin(child, lambda row: row is not None and row['enabled'], 'parent enable propagated')
                first = plugin(child)
                assert Path(first['packageRoot']).is_relative_to(child.root)
                pane = pane_opened_during_preparation(parent, child, first, evidence)
                child.rpc('command.run', id='pane.close', pane=pane, force=True)
                wait_plugin(child, lambda row: row is not None and row['version'] == '2.0.0' and row['installationID'] != first['installationID'], 'update applied after panel close')
                eventually('old private generation retired', lambda: not Path(first['packageRoot']).exists())
                second = plugin(child)
                pane = open_panel(child, '2.0.0')
                parent.rpc('plugins.disable', id=PLUGIN)
                evidence['checks']['active-disable-deferral'] = plugin_sync_deferred(child)
                evidence['checks']['active-disable-deferred-samples'] = retains(child, second, pane, '2.0.0')
                child.rpc('command.run', id='pane.close', pane=pane, force=True)
                wait_plugin(child, lambda row: row is not None and not row['enabled'], 'disable applied after panel close')
                parent.rpc('plugins.enable', id=PLUGIN)
                wait_plugin(child, lambda row: row is not None and row['enabled'], 're-enable propagated')
                # Suspend only our known child while creating the unavailable package condition.
                os.kill(child.pid, signal.SIGSTOP)
                archive = hidden = None
                try:
                    parent_third = parent.rpc('plugins.register', packagePath=package(parent, '3.0.0'), replace=True)
                    archive = Path(parent_third['packageRoot']).parent / 'package.zip'
                    hidden = archive.with_name('package.fixture-hidden')
                    archive.rename(hidden)
                finally:
                    os.kill(child.pid, signal.SIGCONT)
                try:
                    evidence['checks']['unreadable-parent-package-retained-samples'] = retains(child, plugin(child))
                    assert plugin(child)['installationID'] == second['installationID']
                    pane = open_panel(child, '2.0.0')
                    child.rpc('command.run', id='pane.close', pane=pane, force=True)
                finally:
                    if hidden is not None and hidden.exists():
                        hidden.rename(archive)
                wait_plugin(child, lambda row: row is not None and row['version'] == '3.0.0', 'package sync recovered after readability restored')
                registry = parent.root / 'plugins/registry.json'
                hidden_registry = registry.with_name('registry.fixture-hidden')
                registry.rename(hidden_registry)
                try:
                    evidence['checks']['missing-parent-registry-retained-samples'] = retains(child, plugin(child))
                finally:
                    hidden_registry.rename(registry)
                third = plugin(child)
                pane = open_panel(child, '3.0.0')
                parent.rpc('plugins.unregister', id=PLUGIN)
                evidence['checks']['active-remove-deferral'] = plugin_sync_deferred(child)
                evidence['checks']['active-remove-deferred-samples'] = retains(child, third, pane, '3.0.0')
                child.rpc('command.run', id='pane.close', pane=pane, force=True)
                wait_plugin(child, lambda row: row is None, 'removal applied after panel close')
                eventually('removed private generation retired', lambda: not Path(third['packageRoot']).exists())
                changed_parent_during_preparation(parent, child, evidence)
                stopped_plugin_changes(parent, child, evidence)
                stopped_without_plugin_panes(parent, child, evidence)
                # A duplicate executable invocation must activate the original owner without starting a runtime.
                pid, socket_path = child.pid, child.path
                window_ids = [row['windowId'] for row in child.rpc('window.list')['windows']]
                duplicate = run_shell(child)
                assert duplicate.returncode == 0, duplicate.stderr
                assert 'creating workspace host' not in duplicate.stderr
                os.kill(pid, 0)
                assert child.pid == pid and child.path == socket_path
                assert [row['windowId'] for row in child.rpc('window.list')['windows']] == window_ids
                owner = plistlib.loads((child.root / 'owner.plist').read_bytes())
                assert owner['pid'] == pid
                evidence['checks']['duplicate-owner-reused'] = {'pid': pid, 'socket': socket_path, 'windowIds': window_ids}
                maintenance_contention(child, windows, evidence)
                corrupt.start()
                state = corrupt.root / 'state/workspace.json'
                eventually('saved workspace for corruption fixture', state.exists)
                corrupt.stop()
                saved = state.read_bytes()
                broken = b'{"schemaVersion":2,"fixtureCorruption":'
                state.write_bytes(broken)
                state.chmod(0o600)
                evidence['checks']['corrupt-workspace'] = startup_failure(corrupt, 'corrupt', windows)
                assert state.read_bytes() == broken, 'Failed restore overwrote the original workspace'
                state.write_bytes(saved)
                corrupt.start()
                assert len(corrupt.panes()) == 1
                # The missing-recipe app has never run and has no saved fallback workspace.
                assert not (missing.root / 'state/workspace.json').exists()
                recipes = [path for path in (parent.config.parent / 'layouts').glob('*.json')
                           if json.loads(path.read_text()).get('id', '').lower() == layout_id.lower()]
                assert len(recipes) == 1
                recipe = recipes[0]
                backup = parent.root / 'missing-recipe.fixture-json'
                recipe.rename(backup)
                try:
                    evidence['checks']['missing-fresh-recipe'] = startup_failure(missing, 'missing', windows)
                    assert not (missing.root / 'state/workspace.json').exists(), 'Missing recipe published fallback workspace'
                finally:
                    backup.rename(recipe)
                missing.start()
                assert len(missing.panes()) == 1
                evidence['checks']['startup-failure-leases-released-after-repair'] = 'passed'
                print('PASS live and stopped-app plugin deferral, install/enable/update/disable/removal and unreadable-package retention', flush=True)
                print('PASS duplicate owner reuse, maintenance wait/release/timeout, corrupt/missing startup preservation and successful repair', flush=True)
            finally:
                failures = []
                for app in apps:
                    try:
                        app.cleanup()
                    except BaseException as error:
                        failures.append({'path': str(app.bundle), 'pid': app.pid, 'error': str(error)})
                if failures:
                    parent.preserve_for_children = True
                    evidence['cleanupFailures'] = failures
                    raise AssertionError('Owned sync-app cleanup failed: ' + json.dumps(failures))
    finally:
        (ROOT / 'artifacts/layout-app-sync-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()
