#!/usr/bin/env python3
"""Capture owned native layout-app UI states in the VM for independent review."""
import hashlib
import importlib.util
import json
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
    fixture.require_vm()
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    evidence = {'captures': [], 'observations': {}, 'visualReview': 'pending-independent-review',
                'interactionLimitations': ['Icon selection is set through the existing dialog test hook.',
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
        assert details['message'] == 'Create Layout App', details
        assert parent.rpc('layoutApps.list') == before, 'Cancelling the dialog created an app'
        evidence['captures'].append(dict(png_evidence(path), section='Create Layout App', selectedIcon=icon))
        evidence['observations'][name] = {'dialog': details, 'cancelPreservedAppCatalog': True}

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
            first = parent.rpc('layouts.launcher', id=layout_id, path=str(parent.root / 'Research.app'),
                               name='Research', icon='book', copyPluginData=True)
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
            capture(child, 'child-layouts-managed', 'Layouts', width=1000, height=560)
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
