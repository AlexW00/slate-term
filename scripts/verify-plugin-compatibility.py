#!/usr/bin/env python3
"""Owned VM app: compatibility admission and stored-registration launch recheck."""
from pathlib import Path
from plugin_package_fixture import package_fixture
import json
import subprocess
from api_fixture import APP, AppFixture, eventually

with AppFixture('plugin-compatibility') as app:
    app.capture_contracts()
    marker = app.root / 'executed'
    manifest = dict(id='compatible.fixture', title='Compatibility fixture', manifestVersion=1, version='1.2.0',
        compatibility=dict(minimumAPIVersion=1, maximumAPIVersion=1,
            requiredMethods=['terminal.capture'], requiredCommands=['terminal.find']),
        commands=[dict(id='run', title='Run', executable='/usr/bin/touch', arguments=[str(marker)])])
    registered = app.rpc('plugins.register', packagePath=package_fixture(manifest, app.root))
    assert registered['version'] == '1.2.0'
    listing = next(p for p in app.rpc('plugins.list') if p['id'] == manifest['id'])
    assert listing['compatibilityStatus']['compatible']
    app.rpc('command.run', id='plugin.compatible.fixture.run')
    assert marker.exists()
    marker.unlink()
    invalid = dict(manifest, compatibility=dict(minimumAPIVersion=2, maximumAPIVersion=2))
    failure = app.rpc('plugins.register', packagePath=package_fixture(invalid, app.root), replace=True, error=-32053)
    assert not failure['data']['compatible']
    assert next(p for p in app.rpc('plugins.list') if p['id'] == manifest['id'])['version'] == '1.2.0'
    assert not marker.exists()
    bad_file = package_fixture(invalid, app.root)
    assert app.cli('plugins', 'validate', '--package', bad_file, error=True)['code'] == -32053
    app.rpc('plugins.validate', packagePath=bad_file, error=-32053)

    # Simulate installed requirements from a newer host. Change only the owned
    # fixture's installed manifest, not its download or registry enabled choice.
    app.process.terminate()
    app.process.wait(timeout=10)
    catalog_file = app.root / 'plugins/registry.json'
    catalog_bytes = catalog_file.read_bytes()
    (Path(registered['packageRoot']) / 'plugin.json').write_text(json.dumps(invalid))
    app.ready.unlink()
    app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
    eventually('restarted owned app', lambda: app.ready.exists() and app.process.poll() is None)
    app.path = app.ready.read_text().strip()
    app.env['SLATE_TERM_SOCKET'] = app.path
    listing = next(p for p in app.rpc('plugins.list') if p['id'] == manifest['id'])
    assert listing['enabled'] and not listing['compatibilityStatus']['compatible']
    assert listing['compatibilityStatus']['reasons']
    assert catalog_file.read_bytes() == catalog_bytes
    commands = {c['id'] for c in app.rpc('command.list')}
    assert 'plugin.compatible.fixture.run' not in commands
    app.rpc('plugins.enable', id=manifest['id'], error=-32053)
    assert not marker.exists()
    app.rpc('plugins.unregister', id=manifest['id'])
    assert all(p['id'] != manifest['id'] for p in app.rpc('plugins.list'))
print('PASS plugin compatibility registration, replacement, offline validation and launch revalidation')
