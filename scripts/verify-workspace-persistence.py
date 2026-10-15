#!/usr/bin/env python3
"""Model acceptance and best-effort workspace persistence are different outcomes."""
import json
from api_fixture import AppFixture

with AppFixture('workspace-persistence') as app:
    contract = app.rpc('api.describe')['workspaceCommit']
    assert contract['version'] == 1 and 'workspacePersistence' in contract['resultFields']
    assert set(contract['workspacePersistence']) == {'saved', 'failed', 'disabled', 'suspended', 'notRequired'}
    saved = app.cli('panes', 'set-title', '--pane', 'p1', '--title', 'Persisted')
    assert saved['outcome'] == 'committed' and saved['workspacePersistence'] == 'saved'
    state = app.root / 'state'
    snapshot = state / 'workspace.json'
    original = snapshot.read_bytes()
    start = app.rpc('events.head')['cursor']
    state.chmod(0o500)
    try:
        accepted = app.cli('panes', 'set-title', '--pane', 'p1', '--title', 'Accepted in memory')
        assert accepted['outcome'] == 'committed' and accepted['workspacePersistence'] == 'failed'
        assert app.rpc('pane.inspect', pane='p1')['manualTitle'] == 'Accepted in memory'
        assert app.rpc('workspace.snapshot')['workspaceRevision'] == accepted['workspaceRevision']
        assert snapshot.read_bytes() == original
        facts = app.rpc('events.poll', after=start, topics=['host.pane.title.changed', 'host.workspace.changed'], waitMilliseconds=0)['events']
        assert len(facts) == 2 and all(e['payload']['operationId'] == accepted['operationId'] for e in facts)
        assert str(state) not in json.dumps(accepted), 'Do not expose filesystem diagnostics in page-accessible mutation results'
    finally:
        state.chmod(0o700)
    # Explicit no-op acceptance can save current state without replaying the mutation.
    start = app.rpc('events.head')['cursor']
    recovered = app.cli('panes', 'set-title', '--pane', 'p1', '--title', 'Accepted in memory')
    assert recovered['outcome'] == 'unchanged' and recovered['workspacePersistence'] == 'saved'
    assert recovered['workspaceRevision'] == accepted['workspaceRevision']
    assert snapshot.read_bytes() != original
    assert not app.rpc('events.poll', after=start, topics=['host.pane.title.changed', 'host.workspace.changed'], waitMilliseconds=0)['events']

with AppFixture('workspace-persistence-disabled', configuration='[layout]\nrestore_workspace = false\n', workspace_source='preserved disabled snapshot') as app:
    result = app.cli('panes', 'set-title', '--pane', 'p1', '--title', 'Not persisted')
    assert result['outcome'] == 'committed' and result['workspacePersistence'] == 'disabled'
    assert (app.root / 'state/workspace.json').read_text() == 'preserved disabled snapshot'

with AppFixture('workspace-persistence-suspended', workspace_source='preserved invalid snapshot') as app:
    result = app.cli('panes', 'set-title', '--pane', 'p1', '--title', 'Recovery workspace')
    assert result['outcome'] == 'committed' and result['workspacePersistence'] == 'suspended'
    assert (app.root / 'state/workspace.json').read_text() == 'preserved invalid snapshot'

print('PASS workspace persistence: saved, failed-but-committed, explicit no-op recovery, disabled and suspended snapshot preservation')
