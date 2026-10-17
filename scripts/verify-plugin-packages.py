#!/usr/bin/env python3
"""Managed ZIPs survive source deletion/restart; registry, runtime paths and cleanup."""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import zipfile
from api_fixture import AppFixture, APP, eventually


def package(directory, version):
    directory.mkdir(parents=True)
    manifest = dict(id='packaged', title='Managed fixture', source=dict(kind='directory', path='web'),
                    commands=[dict(id='read', title='Read resource', executable='/bin/sh',
                                   arguments=['{pluginRoot}/read.sh'])],
                    service=dict(executable='/bin/sh', arguments=['{pluginRoot}/service.sh']))
    (directory / 'plugin.json').write_text(json.dumps(manifest))
    (directory / 'web').mkdir()
    (directory / 'web/index.html').write_text('<!doctype html><title>Packaged</title><script type="module" src="./app.js"></script>')
    (directory / 'web/app.js').write_text('window.packageReady = "' + version + '";')
    (directory / 'data.txt').write_text(version)
    (directory / 'read.sh').write_text('set -eu\ntest . -ef "$SLATE_TERM_PLUGIN_ROOT"\ncat "$SLATE_TERM_PLUGIN_ROOT/data.txt"\n')
    (directory / 'service.sh').write_text('set -eu\ntest -f "$SLATE_TERM_PLUGIN_ROOT/data.txt"\n"$SLATE_TERM_CLI" rpc service.ready --params \'{"version":1}\' >/dev/null\nwhile :; do sleep 1; done\n')
    archive = directory.parent / (directory.name + '.zip')
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
        for path in directory.rglob('*'):
            if path.is_file():
                output.write(path, path.relative_to(directory).as_posix())
    return archive


def http_package(directory):
    directory.mkdir()
    manifest = dict(id='zipserver', title='Packaged HTTP', source=dict(kind='url', url='http://127.0.0.1:0/'),
                    process=dict(executable=sys.executable, arguments=['{pluginRoot}/server.py', '{port}']))
    (directory / 'plugin.json').write_text(json.dumps(manifest))
    (directory / 'index.html').write_text('<!doctype html><title>Packaged HTTP</title><script>window.managedHTTP="from-zip";</script>')
    (directory / 'server.py').write_text('import http.server,sys\nhttp.server.ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),http.server.SimpleHTTPRequestHandler).serve_forever()\n')
    archive = directory.parent / 'http.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
        for path in directory.iterdir():
            output.write(path, path.name)
    return archive


with tempfile.TemporaryDirectory(prefix='slate-downloads-') as temporary, AppFixture('plugin-packages') as app:
    downloads = Path(temporary)
    archive = package(downloads / 'original', 'first')
    assert app.cli('plugins', 'validate', '--package', str(archive))['valid']
    assert app.rpc('plugins.validate', packagePath=str(archive))['valid']
    app.rpc('plugins.register', manifest={}, error=-32602)
    installed = app.cli('plugins', 'register', '--package', str(archive))
    root = Path(installed['packageRoot'])
    assert root.is_relative_to(app.root / 'plugins/packages')
    assert (root.parent / 'package.zip').is_file()
    registry = app.root / 'plugins/registry.json'
    records = json.loads(registry.read_text())
    assert records['schemaVersion'] == 1 and records['plugins'][0]['enabled']
    assert '\n  "plugins"' in registry.read_text() and str(downloads) not in registry.read_text()
    shutil.rmtree(downloads / 'original')
    archive.unlink()
    assert app.cli('command', 'run', 'plugin.packaged.read')['stdout'] == 'first'
    pane = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=pane, type='packaged', force=True)
    eventually('packaged modules', lambda: app.rpc('debug.pluginEval', pane=pane, script='window.packageReady') == 'first')
    assert app.rpc('debug.pluginEval', pane=pane, script='await workspace.call("plugins.list",{})')[0]['installationID'] == installed['installationID']
    app.rpc('plugins.service.start', id='packaged')
    eventually('packaged manual service', lambda: app.rpc('plugins.service.status', id='packaged')['state'] == 'ready')
    app.rpc('plugins.service.stop', id='packaged')
    http_archive = http_package(downloads / 'http-source')
    http_install = app.rpc('plugins.register', packagePath=str(http_archive))
    http_archive.unlink(); shutil.rmtree(downloads / 'http-source')
    http_pane = app.rpc('command.run', id='split.down', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=http_pane, type='zipserver', force=True)
    eventually('packaged HTTP backend', lambda: app.rpc('debug.pluginEval', pane=http_pane, script='window.managedHTTP') == 'from-zip')
    # Same private app state after restart; there is no source archive left to consult.
    app.process.terminate(); app.process.wait(timeout=10)
    app.ready.unlink()
    app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
    eventually('restart with installed ZIP', lambda: app.ready.exists() and app.process.poll() is None)
    app.path = app.ready.read_text().strip(); app.env['SLATE_TERM_SOCKET'] = app.path
    assert app.rpc('plugins.service.status', id='packaged')['state'] == 'stopped'
    assert app.cli('command', 'run', 'plugin.packaged.read')['stdout'] == 'first'
    eventually('restored packaged panel', lambda: app.rpc('debug.pluginEval', pane=pane, script='window.packageReady') == 'first')
    eventually('restored packaged HTTP backend', lambda: app.rpc('debug.pluginEval', pane=http_pane, script='window.managedHTTP') == 'from-zip')
    second = package(downloads / 'replacement', 'second')
    app.rpc('plugins.register', packagePath=str(second), replace=True, error=-32010)
    assert app.rpc('plugins.list')[0]['installationID'] == installed['installationID']
    app.rpc('plugins.disable', id='packaged', force=True)
    assert root.is_dir()
    replacement = app.rpc('plugins.register', packagePath=str(second), replace=True)
    assert not replacement['enabled'] and replacement['installationID'] != installed['installationID']
    second.unlink(); shutil.rmtree(downloads / 'replacement')
    app.rpc('plugins.enable', id='packaged')
    assert app.cli('command', 'run', 'plugin.packaged.read')['stdout'] == 'second'
    eventually('retired package generation cleanup', lambda: not root.exists())
    new_root = Path(replacement['packageRoot'])
    data = app.rpc('plugins.data.get', id='packaged')
    app.rpc('plugins.data.patch', id='packaged', expectedDataRevision=data['revision'], operations=[dict(op='set', key='retained', value=True)])
    app.rpc('plugins.unregister', id='packaged')
    eventually('uninstalled managed files', lambda: not new_root.exists())
    app.rpc('plugins.unregister', id='zipserver', force=True)
    eventually('uninstalled managed HTTP files', lambda: not Path(http_install['packageRoot']).exists())
    assert not json.loads(registry.read_text())['plugins']
    assert app.rpc('plugins.data.get', id='packaged')['values']['retained']

print('PASS managed ZIP source deletion/restart, portable static/HTTP/command/service resources, registry, replacement, disable and uninstall')
