#!/usr/bin/env python3
"""Identity, revision, pagination, environment, CLI error and native/legacy parity gate."""
import json
import shlex
from concurrent.futures import ThreadPoolExecutor
from api_fixture import AppFixture, eventually

with AppFixture('api-context') as app:
    api = app.cli('api', 'describe')
    assert api['identityGuards'] and api['workspaceRevisions']
    epoch = api['appInstanceId']
    original = app.rpc('workspace.get')
    assert app.cli('workspace', 'get') == original
    snapshot = app.cli('workspace', 'snapshot')
    revision = snapshot['workspaceRevision']
    assert snapshot['appInstanceId'] == epoch and snapshot['nextCursor'] is None
    assert app.rpc('workspace.snapshot')['workspaceRevision'] == revision, 'Reads changed revision'
    p1 = snapshot['panes'][0]
    assert p1['paneId'] == 'p1' and 'terminal.capture' in p1['contentOperations']
    assert 'command' not in p1 and 'workingDirectory' not in p1 and 'environment' not in p1
    layout1 = p1['layoutRevision']
    eventually('prompt', lambda: app.rpc('context.get', pane='p1', scope='pane')['terminal']['state'] == 'prompt')
    session = app.rpc('context.get', pane='p1', scope='pane')['terminal']['sessionId']
    env = app.env | dict(SLATE_TERM_INSTANCE_ID=epoch, SLATE_TERM_PANE_ID='p1', SLATE_TERM_TAB_ID='t999', SLATE_TERM_SESSION_ID=session)
    context = app.cli('context', 'inspect', '--self', env=env)
    assert context['caller']['paneId'] == 'p1' and context['caller']['tabId'] == 't1'
    assert context['caller']['sessionId'] == session
    app.rpc('pane.inspect', pane='p1', expectedInstanceId='different', error=-32050)
    app.rpc('pane.inspect', pane='p1', expectedAnchorSessionId='different', error=-32050)
    assert app.cli('context', 'inspect', '--self', env=env | {'SLATE_TERM_INSTANCE_ID': 'different'}, error=True)['code'] == -32050
    assert app.cli('panes', 'inspect', '--pane', 'not-an-id', error=True)['outcome'] == 'rejected'
    assert app.cli('panes', 'send', '--pane', 'p1', error=True)['code'] == -32602

    # Check real shell exports without returning private authentication/run tokens.
    output = app.root / 'identity.json'
    command = "python3 -c " + shlex.quote('import os,json; print(json.dumps({k:os.getenv(k) for k in ["SLATE_TERM_PANE_ID","SLATE_TERM_TAB_ID","SLATE_TERM_INSTANCE_ID","SLATE_TERM_SESSION_ID"]}))') + ' > ' + shlex.quote(str(output))
    app.rpc('terminal.run', pane='p1', command=command, timeoutMilliseconds=10000)
    exported = json.loads(output.read_text())
    assert exported == dict(SLATE_TERM_PANE_ID='p1', SLATE_TERM_TAB_ID='t1', SLATE_TERM_INSTANCE_ID=epoch, SLATE_TERM_SESSION_ID=session), exported

    second = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    changed = app.rpc('workspace.snapshot', limit=1)
    assert changed['workspaceRevision'] != revision and changed['nextCursor']
    assert changed['panes'][0]['layoutRevision'] != layout1
    next_page = app.rpc('workspace.snapshot', limit=1, cursor=changed['nextCursor'])
    assert next_page['eventCursor'] == changed['eventCursor'] and next_page['panes'][0]['paneId'] == second
    assert next_page['nextCursor'] is None
    assert app.cli('panes', 'inspect', '--pane', second, env=env)['paneId'] == second, 'Inherited session contaminated sibling target'
    assert app.cli('terminal', 'capture', '--scope', 'tab', env=env), 'Contextual lookup used stale inherited tab hint'
    second_revision = changed['workspaceRevision']
    app.rpc('command.run', id='pane.focus', pane='p1')
    app.rpc('workspace.snapshot', cursor=changed['nextCursor'], error=-32050)
    assert app.rpc('pane.inspect', pane='p1')['layoutRevision'] == changed['panes'][0]['layoutRevision'], 'Focus invalidated layout'
    app.rpc('pane.inspect', pane='p1', expectedWorkspaceRevision=second_revision, error=-32050)
    app.rpc('command.run', id='pane.type', pane='p1', type='browser', force=True)
    assert app.cli('panes', 'inspect', env=env, error=True)['code'] == -32050, 'Dead shell retargeted successor slot'
    assert app.cli('panes', 'inspect', '--active', env=env)['type'] == 'browser'

    # Explicit guards must survive CLI paths that do not inherit a workspace target.
    before_window = app.rpc('workspace.get')
    assert app.cli('command', 'run', 'window.new', '--expected-workspace-revision', 'stale', error=True)['code'] == -32050
    assert app.rpc('workspace.get') == before_window
    assert app.cli('workspace', 'snapshot', '--expected-workspace-revision', 'stale', error=True)['code'] == -32050

    # Guards are checked again after WebKit preparation, immediately before mutation submission.
    app.rpc('browser.navigate', pane='p1', url='about:blank')
    app.rpc('browser.eval', pane='p1', script='document.body.innerHTML = `<button id="go" onclick="window.clicks++">Go</button>`; window.clicks = 0')
    web_revision = app.rpc('pane.inspect', pane='p1')['layoutRevision']
    with ThreadPoolExecutor(max_workers=2) as workers:
        busy = workers.submit(app.rpc, 'browser.eval', pane='p1', script='(() => { const until = Date.now() + 1500; while (Date.now() < until) {} return true; })()')
        eventually('busy JS admitted', lambda: app.rpc('browser.get', pane='p1')['pendingOperations'] >= 1)
        click = workers.submit(app.rpc, 'browser.click', pane='p1', selector='#go', expectedLayoutRevision=web_revision, error=-32050)
        eventually('automation preparation admitted', lambda: app.rpc('browser.get', pane='p1')['pendingOperations'] >= 2)
        app.rpc('command.run', id='pane.zoom', pane='p1')
        assert app.rpc('pane.inspect', pane='p1')['layoutRevision'] != web_revision
        assert busy.result(timeout=10) is True
        click.result(timeout=10)
    assert app.rpc('browser.eval', pane='p1', script='window.clicks') == 0
    app.rpc('browser.snapshot', pane='p1', expectedSourceRevision='unsupported', error=-32602)

    # Background pane identity, not the key tab, controls tab reads and destructive commands.
    foreground = app.rpc('command.run', id='window.new')['tabId']
    assert app.rpc('workspace.get')['keyTabID'] == foreground
    assert app.cli('layout', 'get', '--pane', second) == app.rpc('layout.get', tab='t1')
    app.cli('tabs', 'close', '--pane', second, '--force')
    assert [tab['id'] for tab in app.rpc('tabs.list')] == [foreground]

    batch = app.rpc('events.poll', after=snapshot['eventCursor'], topics=['host.*'], waitMilliseconds=0)
    topics = {event['topic'] for event in batch['events']}
    assert {'host.pane.created', 'host.layout.changed', 'host.pane.type.changed'} <= topics, topics
    assert all(event['source'] for event in batch['events'])
print('API context, identity guards, legacy revision tracking and pagination passed')
