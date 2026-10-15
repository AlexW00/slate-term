#!/usr/bin/env python3
"""Owned production parity for prepared workspace commits and attributed semantic facts."""
import json
import subprocess
from api_fixture import AppFixture, eventually

TOPICS = ['host.pane.*', 'host.tab.*', 'host.tabs.*', 'host.layout.*', 'host.focus.*', 'host.workspace.*']

with AppFixture('semantic-events') as app:
    def head():
        return app.rpc('events.head')['cursor']

    def facts(after):
        return app.rpc('events.poll', after=after, topics=TOPICS, waitMilliseconds=0)['events']

    start = head()
    before = app.rpc('workspace.snapshot')
    result = app.cli('panes', 'split', '--pane', 'p1', '--right')
    assert result['outcome'] == 'committed' and result['operationId']
    emitted = [e for e in facts(start) if e['payload'].get('operationId') == result['operationId']]
    assert [e['topic'] for e in emitted] == ['host.pane.created', 'host.layout.changed', 'host.focus.changed', 'host.workspace.changed'], emitted
    assert all(e['source'] == {'kind': 'host'} and e['payload']['origin'] == {'kind': 'administrative'} for e in emitted)
    assert all(e['payload']['beforeWorkspaceRevision'] == before['workspaceRevision'] for e in emitted)
    assert all(e['payload']['workspaceRevision'] == result['workspaceRevision'] for e in emitted)
    assert emitted[0]['payload']['actionKind'] == 'pane.split' and emitted[0]['payload']['anchor'] == 'p1'
    assert emitted[0]['payload']['newPaneFraction'] == .5

    # Same authoritative operation from a native menu, not a fabricated RPC source field.
    app.rpc('debug.activate')
    start = head()
    app.rpc('debug.key', chord='cmd+d', menu=True)
    native = [e for e in facts(start) if e['topic'] == 'host.pane.created']
    assert len(native) == 1 and native[0]['payload']['origin'] == {'kind': 'native'}, native
    assert native[0]['payload']['actionKind'] == 'pane.split'
    panel = native[0]['pane']

    directory = app.root / 'panel'
    directory.mkdir()
    (directory / 'index.html').write_text('<!doctype html><title>Semantic fixture</title>')
    app.rpc('plugins.register', manifest={'id': 'fixture', 'title': 'Fixture', 'source': {'kind': 'directory', 'path': str(directory)}})
    app.rpc('command.run', id='pane.type', pane=panel, type='fixture', force=True)
    def evaluate(script):
        return app.rpc('debug.pluginEval', pane=panel, script=script)
    eventually('registered page bridge ready', lambda: evaluate('typeof workspace === "object"'))
    identity = evaluate('workspace.plugin')
    contract = evaluate('workspace.call("api.describe")')['workspaceCommit']
    assert contract['version'] == 1 and not contract['additionalMethods']
    start = head()
    page = evaluate('workspace.panes.setTitle("private semantic title")')
    emitted = [e for e in facts(start) if e['payload'].get('operationId') == page['operationId']]
    assert [e['topic'] for e in emitted] == ['host.pane.title.changed', 'host.workspace.changed'], emitted
    expected = {'kind': 'plugin', 'pluginId': 'fixture', 'instanceId': identity['instanceId'], 'viewId': identity['viewId']}
    assert all(e['payload']['origin'] == expected for e in emitted)
    assert 'private semantic title' not in json.dumps(emitted)
    assert emitted[0]['payload']['hasManualTitle'] is True

    # No-op acceptance has correlation but no invented lifecycle changes or revisions.
    start = head()
    before = app.rpc('workspace.snapshot')
    no_op = app.cli('panes', 'clear-title', '--pane', 'p1')
    assert no_op['outcome'] == 'unchanged' and no_op['operationId']
    assert not facts(start)
    assert app.rpc('workspace.snapshot')['workspaceRevision'] == before['workspaceRevision']

    # Provisional native resource failure cannot publish a prepared model transaction.
    start = head()
    before = app.rpc('workspace.get')
    revision = app.rpc('pane.inspect', pane='p1')['layoutRevision']
    app.rpc('debug.rejectNextTerminalPreparation')
    app.rpc('command.run', id='pane.split', pane='p1', target='root', direction='right', newPaneFraction=.2,
            expectedLayoutRevision=revision, error=-32051)
    assert app.rpc('workspace.get') == before and not facts(start)

    def terminal_children():
        found = subprocess.run(['pgrep', '-P', str(app.process.pid), '-x', 'login'], capture_output=True, text=True)
        assert found.returncode in [0, 1], found.stderr
        return set(found.stdout.split())

    # Reject after resources AND the journal candidate have been prepared.
    eventually('owned terminal children', lambda: bool(terminal_children()))
    children = terminal_children()
    session = app.rpc('pane.inspect', pane='p1')['sessionId']
    for pane_type in ['terminal', 'fixture']:
        start = head()
        before = app.rpc('workspace.get')
        workspace_revision = app.rpc('workspace.snapshot')['workspaceRevision']
        prepared_count = app.rpc('debug.inspect')['terminalPreparationCount']
        app.rpc('debug.rejectNextWorkspacePublication')
        app.rpc('command.run', id='pane.split', pane='p1', target='root', direction='right', newPaneFraction=.2,
                type=pane_type, expectedLayoutRevision=revision, error=-32051)
        assert app.rpc('workspace.get') == before and not facts(start)
        assert app.rpc('workspace.snapshot')['workspaceRevision'] == workspace_revision
        assert app.rpc('pane.inspect', pane='p1')['sessionId'] == session
        assert app.rpc('debug.inspect')['terminalPreparationCount'] == prepared_count + (pane_type == 'terminal')
        assert evaluate('workspace.plugin') == identity
        eventually('late-rejected terminal cleaned up', lambda: terminal_children() == children)

    # Catalog persistence must not precede a fallible journal admission.
    start = head()
    before = app.rpc('workspace.get')
    catalog = app.rpc('plugins.list')
    app.rpc('debug.rejectNextWorkspacePublication')
    app.rpc('plugins.unregister', id='fixture', force=True, error=-32051)
    assert app.rpc('workspace.get') == before and app.rpc('plugins.list') == catalog
    assert evaluate('workspace.plugin') == identity
    assert not app.rpc('events.poll', after=start, topics=TOPICS + ['host.plugins.changed'], waitMilliseconds=0)['events']
    # An actual filesystem write failure has the same atomic boundary as preflight
    # rejection. Only this fixture's private catalog directory is made unwritable.
    state_directory = app.root / 'state'
    catalog_file = state_directory / 'plugins.json'
    source = catalog_file.read_bytes()
    workspace_revision = app.rpc('workspace.snapshot')['workspaceRevision']
    state_directory.chmod(0o500)
    try:
        app.rpc('plugins.unregister', id='fixture', force=True, error=-32602)
        assert catalog_file.read_bytes() == source
        assert app.rpc('workspace.get') == before and app.rpc('plugins.list') == catalog
        assert app.rpc('workspace.snapshot')['workspaceRevision'] == workspace_revision
        assert evaluate('workspace.plugin') == identity
        assert not app.rpc('events.poll', after=start, topics=TOPICS + ['host.plugins.changed'], waitMilliseconds=0)['events']
    finally:
        state_directory.chmod(0o700)
    removed = app.rpc('plugins.unregister', id='fixture', force=True)
    emitted = app.rpc('events.poll', after=start, topics=TOPICS + ['host.plugins.changed'], waitMilliseconds=0)['events']
    correlated = [e for e in emitted if e['payload'].get('operationId') == removed['operationId']]
    assert removed['outcome'] == 'committed'
    assert any(e['topic'] == 'host.pane.closed' and e['pane'] == panel for e in correlated)
    assert len([e for e in correlated if e['topic'] == 'host.plugins.changed']) == 1
    assert all(e['payload']['workspaceRevision'] == removed['workspaceRevision'] for e in correlated)

    app.rpc('plugins.register', manifest={'id': 'unused', 'title': 'Unused', 'source': {'kind': 'directory', 'path': str(directory)}})
    start = head()
    workspace_revision = app.rpc('workspace.snapshot')['workspaceRevision']
    removed = app.rpc('plugins.unregister', id='unused')
    assert removed['outcome'] == 'committed' and removed['workspaceRevision'] == workspace_revision
    assert removed['workspacePersistence'] == 'notRequired'
    emitted = app.rpc('events.poll', after=start, topics=TOPICS + ['host.plugins.changed'], waitMilliseconds=0)['events']
    assert len(emitted) == 1 and emitted[0]['payload']['operationId'] == removed['operationId']
    assert emitted[0]['topic'] == 'host.plugins.changed'
    window = app.rpc('pane.inspect', pane='p1')['windowId']
    focused = app.cli('windows', 'focus', '--window-id', window)
    assert focused['operationId'] and focused['workspaceRevision'] == app.rpc('workspace.snapshot')['workspaceRevision']

print('PASS prepared workspace commit: CLI/native/page attribution, normalized facts, revisions, title privacy, no-op and preparation failure')
