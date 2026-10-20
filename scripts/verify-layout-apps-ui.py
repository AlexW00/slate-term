#!/usr/bin/env python3
"""Capture owned native layout-app UI states in the VM for independent review."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import plistlib
from pathlib import Path
import struct
import subprocess
import time
import uuid

from api_fixture import AppFixture, ROOT, eventually
from plugin_package_fixture import package_fixture

spec = importlib.util.spec_from_file_location('layout_apps_ui_fixture', Path(__file__).with_name('verify-layout-apps.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

ARTIFACTS = ROOT / 'artifacts/layout-apps-ui'


def png_evidence(path):
    content = path.read_bytes()
    assert content[:8] == b'\x89PNG\r\n\x1a\n', ('Missing native PNG capture', path)
    width, height = struct.unpack('>II', content[16:24])
    assert width > 200 and height > 200, ('Unexpected capture geometry', width, height)
    return {'file': path.name, 'pixelWidth': width, 'pixelHeight': height,
            'sha256': hashlib.sha256(content).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--external-save-input', action='store_true',
                        help='Wait for real external native Create clicks in three save panels (30 seconds each).')
    args = parser.parse_args()
    fixture.require_vm()
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    evidence = {'captures': [], 'observations': {}, 'visualReview': 'pending-independent-review',
                'interactionLimitations': ['Icon buttons and save-panel cancellation use integration hooks; save confirmation requires external native input.',
                    'Override reset uses the production API; the Reset button hit target is not exercised.']}

    def capture(app, name, section, width=1060, height=720):
        if isinstance(app, fixture.LayoutApp):
            environment = {key: value for key, value in app.env.items() if key != 'SLATE_TERM_SOCKET'}
            launched = json.loads(fixture.jxa(fixture.LAUNCH.replace('configuration.activates = false;',
                'configuration.activates = true;'), app.bundle, json.dumps(environment)))
            assert launched.get('pid') == app.pid, launched
        else:
            fixture.jxa("""ObjC.import('AppKit'); function run(args) {
                var app=$.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(args[0]));
                return String(app.activateWithOptions(3));
            }""", app.process.pid)
        app.rpc('debug.activate')
        state = app.rpc('debug.settings', section=section, width=width, height=height)
        assert state['error'] is None and not state['dirty'], state
        eventually('owned Settings visible', lambda: app.rpc('debug.settings', inspectOnly=True)['visible'])
        def active_settings():
            visibility = app.rpc('debug.notifications')
            return visibility['appActive'] and visibility['settingsKey']
        eventually('owned Settings active and key', active_settings)
        # Give AppKit and SwiftUI a display turn before capturing the on-screen window.
        time.sleep(.4)
        path = ARTIFACTS / (name + '.png')
        subprocess.run(['/usr/sbin/screencapture', '-x', str(path)], check=True, capture_output=True)
        evidence['captures'].append(dict(png_evidence(path), section=section,
                                        requestedContentWidth=width, requestedContentHeight=height))
        return state

    def dialog(parent, name, icon):
        path = ARTIFACTS / (name + '.png')
        before = parent.rpc('layoutApps.list')
        details = parent.rpc('debug.layoutDialogs', launcher=True, name='Research', icon=icon,
                             confirm=False, screenshot=str(path))
        assert details['message'] == 'Create App', details
        assert details['editableFields'] == 0 and details['previewPresent'], details
        assert details['previewChanged'] == (icon != 'slate'), details
        assert parent.rpc('layoutApps.list') == before, 'Cancelling the dialog created an app'
        evidence['captures'].append(dict(png_evidence(path), section='Create App', selectedIcon=icon))
        evidence['observations'][name] = {'dialog': details, 'cancelPreservedAppCatalog': True}

    def native_creation(parent, layout_id):
        before = parent.rpc('layoutApps.list')
        destination = parent.root / 'Chosen Location' / 'Custom App Name.app'
        destination.parent.mkdir()
        common = dict(launcher=True, layoutID=layout_id, icon='folder', destination=str(destination),
                      timeoutScreenshot=str(ARTIFACTS / 'create-app-save-timeout.png'),
                      externalInput=args.external_save_input)
        options_cancel = parent.rpc('debug.layoutDialogs', **common, confirm=False)
        assert 'savePanel' not in options_cancel and not destination.exists(), options_cancel
        save_path = ARTIFACTS / 'create-app-save-panel.png'
        save_cancel = parent.rpc('debug.layoutDialogs', **common, confirm=True,
                                 saveConfirm=False, saveScreenshot=str(save_path))
        assert not save_cancel['savePanel']['accepted'] and not save_cancel['savePanel']['timedOut'], save_cancel
        assert save_cancel['savePanel']['action'] == 'cancel' and not destination.exists(), save_cancel
        assert parent.rpc('layoutApps.list') == before, 'Cancelling creation changed the app catalog'
        evidence['captures'].append(dict(png_evidence(save_path), section='Create App save panel'))
        if not args.external_save_input:
            record = parent.rpc('layouts.launcher', id=layout_id, path=str(destination),
                                name='Custom App Name', icon='folder')
            evidence['observations']['creation'] = {
                'optionsCancelPreservedCatalog': True, 'saveCancelPreservedCatalog': True,
                'fixtureCreation': 'production layouts.launcher API',
                'nativeSaveConfirmation': 'not exercised; run --external-save-input with real native input'}
            return record
        def external_confirmation(step, purpose, **params):
            ready = parent.root / f'native-save-{step}.ready'
            screenshot = ARTIFACTS / f'create-app-external-save-{step}.png'
            with ThreadPoolExecutor(max_workers=1) as pool:
                request = pool.submit(parent.rpc, 'debug.layoutDialogs', **common, confirm=True,
                                      saveConfirm=True, readyPath=str(ready), saveScreenshot=str(screenshot), **params)
                eventually('native save panel ready', lambda: ready.exists() or request.done(), timeout=10)
                if not ready.exists():
                    result = request.result()
                    raise AssertionError(('Save panel did not become ready', result))
                print(f'EXTERNAL SAVE INPUT READY {step}/3: {purpose}; click Create now (30-second watchdog).', flush=True)
                result = request.result(timeout=35)
            evidence['captures'].append(dict(png_evidence(screenshot), section=f'External native save: {purpose}'))
            return result

        original = parent.rpc('layouts.get', id=layout_id)
        external_confirmation(1, 'stale source', staleDuringSave=True, error=-32050)
        assert not destination.exists() and parent.rpc('layoutApps.list') == before
        changed = parent.rpc('layouts.get', id=layout_id)
        parent.rpc('layouts.update', definition=original['definition'], expectedSavedLayoutRevision=changed['revision'])
        external_confirmation(2, 'destination collision', occupyDestination=True, error=-32602)
        marker = destination / 'collision-marker'
        assert marker.read_text() == 'Keep existing destination'
        assert parent.rpc('layoutApps.list') == before
        marker.unlink()
        destination.rmdir()
        result = external_confirmation(3, 'create Custom App Name.app')
        assert result['savePanel']['accepted'] and not result['savePanel']['timedOut'], result
        assert result['savePanel']['action'] == 'externalInput' and result['savePanel']['prepared'], result
        assert result['savePanel']['path'] == str(destination), result
        info = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleDisplayName'] == 'Custom App Name' and info['SlateLauncherIcon'] == 'folder', info
        record = next(row for row in parent.rpc('layoutApps.list') if row['path'] == str(destination))
        evidence['observations']['nativeCreation'] = {
            'optionsCancelPreservedCatalog': True, 'saveCancelPreservedCatalog': True,
            'staleSourceRejected': True, 'destinationCollisionPreserved': True,
            'chosenName': info['CFBundleDisplayName'], 'chosenPath': record['path'], 'icon': info['SlateLauncherIcon'],
            'savePanel': result['savePanel'], 'confirmation': 'external native input'}
        return record

    def readonly_layout(parent, child):
        definition = {'version': 1, 'id': str(uuid.uuid4()), 'name': 'Read-only layout', 'tabs': [
            {'name': 'Research', 'layout': {'kind': 'pane', 'pane': 'p1'},
             'panes': [{'id': 'p1', 'type': 'terminal', 'configuration': {'directory': str(parent.root)}}]},
            {'name': 'Reference', 'layout': {'kind': 'pane', 'pane': 'p2'},
             'panes': [{'id': 'p2', 'type': 'browser', 'configuration': {'url': 'https://example.com'}}]}]}
        entry = child.rpc('layouts.create', definition=definition)
        state = child.rpc('debug.savedLayouts', file=entry['file'])
        baseline = state['definition']
        attempts = [dict(name='Changed'), dict(type='browser'), dict(title='Changed'),
                    dict(configuration={'directory': '/'}), dict(headerVisible=False),
                    dict(split='right'), dict(remove=True), dict(addTab=True), dict(removeTab=0),
                    dict(moveTab=0, toTab=1), dict(dropTab=state['tabDragID'], toTab=1),
                    dict(create=True), dict(save=True)]
        for attempt in attempts:
            state = child.rpc('debug.savedLayouts', **attempt)
            assert state['definition'] == baseline and not state['dirty'], (attempt, state)
            assert state['file'] == entry['file'], (attempt, state)
        assert len(child.rpc('layouts.list')) == 1
        assert child.rpc('layouts.get', id=definition['id'])['revision'] == entry['revision']
        state = child.rpc('debug.savedLayouts', selectTab=1)
        assert state['selectedTab'] == 1 and state['definition'] == baseline, state
        capture(child, 'child-layouts-readonly-browser', 'Layouts', width=1000, height=560)
        child.rpc('debug.savedLayouts', selectTab=0)
        capture(child, 'child-layouts-readonly-terminal', 'Layouts', width=1000, height=560)
        evidence['observations']['childLayoutEditing'] = {
            'mutationAttemptsIgnored': len(attempts), 'definitionUnchanged': True,
            'savedRevisionUnchanged': True, 'tabBrowsingAvailable': True}

    configuration = '[appearance]\ntheme = "light"\n[terminal]\nshell = "/bin/zsh"\nfont_size = 14\n'
    with AppFixture('layout-apps-ui', configuration, startup_timeout=40) as parent:
        child = None
        try:
            layout_id = str(uuid.uuid4())
            definition = {'version': 1, 'id': layout_id, 'name': 'Research Workspace', 'tabs': [{
                'name': 'Research', 'layout': {'kind': 'pane', 'pane': 'p1'},
                'panes': [{'id': 'p1', 'type': 'terminal', 'configuration': {'directory': str(parent.root)}}]}]}
            parent.rpc('layouts.create', definition=definition)
            package = package_fixture({'id': 'layout-ui-notes', 'title': 'Workspace Notes',
                'commands': [{'id': 'open', 'title': 'Open Notes', 'executable': '/usr/bin/true'}]}, parent.root)
            parent.rpc('plugins.register', packagePath=str(package))
            parent.rpc('debug.settings', section='Layouts')
            first = native_creation(parent, layout_id)
            parent.rpc('layouts.launcher', id=layout_id, path=str(parent.root / 'Writing.app'),
                       name='Writing', icon='folder', copyPluginData=False)
            eventually('created apps appear in Settings', lambda: len(
                parent.rpc('debug.settings', inspectOnly=True)['layoutApps']) == 2)
            capture(parent, 'parent-generated-apps-light', 'Layouts')
            dialog(parent, 'create-app-slate-light', 'slate')
            dialog(parent, 'create-app-folder-light', 'folder')
            child = fixture.LayoutApp(parent, first, 'ui').start()
            rows = parent.rpc('layoutApps.list')
            assert len(rows) == 2 and sum(row['running'] for row in rows) == 1, rows
            evidence['observations']['generatedApps'] = rows
            eventually('visible Generated Apps follows child launch', lambda: sum(
                row['running'] for row in parent.rpc('debug.settings', inspectOnly=True)['layoutApps']) == 1)
            capture(parent, 'parent-generated-apps-running', 'Layouts', width=1000, height=560)
            capture(child, 'child-summary-light', 'Layout app')
            status = child.rpc('config.get')
            child.rpc('config.patch', expectedSourceRevision=status['sourceRevision'],
                      values={'terminal.font_size': 18, 'terminal.padding_x': 12})
            state = capture(child, 'child-terminal-overrides', 'Terminal', height=760)
            assert float(state['fontSize']) == 18, state
            assert parent.rpc('config.get')['current']['terminal']['font_size'] == 14
            capture(child, 'child-terminal-overrides-compact', 'Terminal', width=1000, height=560)
            before = child.rpc('config.get')
            child.rpc('config.resetOverrides', expectedSourceRevision=before['sourceRevision'],
                      keys=['terminal.font_size', 'terminal.padding_x'])
            assert child.rpc('config.get')['current']['terminal']['font_size'] == 14
            evidence['observations']['resetInheritedFontSize'] = 14
            capture(child, 'child-terminal-reset', 'Terminal', height=760)
            state = capture(child, 'child-plugins-managed', 'Plugins')
            assert 'layout-ui-notes' in state['pluginEnabled'], state
            capture(child, 'child-plugins-managed-compact', 'Plugins', width=1000, height=560)
            parent_plugins = (parent.root / 'plugins/registry.json').read_bytes()
            initial_plugin = next(row for row in child.rpc('plugins.list') if row['id'] == 'layout-ui-notes')
            assert initial_plugin['enabled'] and initial_plugin['enabledOverride'] is None, initial_plugin
            state = child.rpc('debug.settings', section='Plugins', changePlugin='layout-ui-notes',
                              pluginAction='disable', confirmPluginChange=True)
            assert not state['pluginEnabled']['layout-ui-notes'] and state['error'] is None, state
            disabled_plugin = next(row for row in child.rpc('plugins.list') if row['id'] == 'layout-ui-notes')
            assert not disabled_plugin['enabled'] and disabled_plugin['enabledOverride'] is False, disabled_plugin
            capture(child, 'child-plugins-local-disabled', 'Plugins', width=1000, height=560)
            state = child.rpc('debug.settings', section='Plugins', changePlugin='layout-ui-notes', pluginAction='enable')
            assert state['pluginEnabled']['layout-ui-notes'] and state['error'] is None, state
            enabled_plugin = next(row for row in child.rpc('plugins.list') if row['id'] == 'layout-ui-notes')
            assert enabled_plugin['enabled'] and enabled_plugin['enabledOverride'] is True, enabled_plugin
            assert (parent.root / 'plugins/registry.json').read_bytes() == parent_plugins
            capture(child, 'child-plugins-local-enabled', 'Plugins', width=1000, height=560)
            evidence['observations']['childPluginToggle'] = {
                'nativeDisableCreatedPrivateOverride': True, 'nativeEnableCreatedPrivateOverride': True,
                'parentRegistryUnchanged': True}
            readonly_layout(parent, child)
            current = parent.rpc('config.get')
            parent.rpc('config.patch', expectedSourceRevision=current['sourceRevision'], values={'appearance.theme': 'dark'})
            eventually('child inherits parent dark theme',
                       lambda: child.rpc('config.get')['current']['appearance']['theme'] == 'dark')
            capture(parent, 'parent-generated-apps-dark', 'Layouts')
            dialog(parent, 'create-app-folder-dark', 'folder')
            capture(child, 'child-summary-dark', 'Layout app')
            capture(child, 'child-plugins-managed-dark', 'Plugins')
            registry = json.loads((parent.root / 'plugins/registry.json').read_text())
            registration = next(row for row in registry['plugins'] if row['id'] == 'layout-ui-notes')
            archive = parent.root / 'plugins/packages/layout-ui-notes' / registration['installationID'].lower() / 'package.zip'
            original_archive = archive.read_bytes()
            try:
                archive.write_bytes(b'owned invalid package fixture')
                dialog(parent, 'create-app-unavailable-plugin-dark', 'folder')
                current = parent.rpc('config.get')
                parent.rpc('config.patch', expectedSourceRevision=current['sourceRevision'], values={'appearance.theme': 'light'})
                dialog(parent, 'create-app-unavailable-plugin-light', 'folder')
            finally:
                archive.write_bytes(original_archive)
            evidence['completed'] = True
            print('PASS native layout-app UI evidence captured; independent visual review and hit-target checks remain separate', flush=True)
        finally:
            (ARTIFACTS / 'manifest.json').write_text(json.dumps(evidence, indent=2) + '\n')
            if child is not None:
                try:
                    child.cleanup()
                except Exception:
                    parent.preserve_for_children = True
                    raise


if __name__ == '__main__':
    main()
