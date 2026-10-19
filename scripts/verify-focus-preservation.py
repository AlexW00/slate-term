#!/usr/bin/env python3
"""Structural automation preserves native focus; explicit navigation still selects."""
import uuid
from api_fixture import AppFixture, eventually

with AppFixture('focus-preservation') as app:
    app.capture_contracts()
    app.rpc('command.run', id='welcome.read')
    app.rpc('debug.activate')
    eventually('Owned fixture is active', lambda: app.rpc('debug.notifications')['appActive'])
    app.rpc('command.run', id='settings.open')

    def workspace_key():
        return app.rpc('debug.notifications')['keyTab']

    def model():
        return app.rpc('workspace.get')

    def tab(tab_id):
        return next(t for t in model()['tabs'] if t['id'] == tab_id)

    def pane(pane_id):
        return app.rpc('pane.inspect', pane=pane_id)

    def native(pane_id):
        return next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == pane_id)

    def selected(pane_id='p1', tab_id='t1'):
        state = model()
        return (workspace_key() == tab_id and state['keyTabID'] == tab_id
                and next(t for t in state['tabs'] if t['id'] == tab_id)['focusedPane'] == pane_id)

    def settings_key():
        state = app.rpc('debug.notifications')
        return state['appActive'] and state['settingsKey'] and state['keyTab'] is None

    eventually('Settings owns native key focus', settings_key)
    key_changes = app.rpc('debug.notifications')['nativeKeyChangeCount']
    # Equalizing one pane is a model no-op, but still reaches native reconciliation.
    app.rpc('command.run', id='layout.equalize', pane='p1')
    assert workspace_key() is None, 'Background layout mutation stole Settings key focus'
    assert app.rpc('debug.notifications')['nativeKeyChangeCount'] == key_changes, 'Background mutation changed key focus transiently'
    assert not native('p1')['terminalFocus'], 'Background reconciliation reactivated terminal input'
    app.rpc('command.run', id='pane.focus', pane='p1')
    try:
        eventually('Explicit focus reasserts unchanged model target', selected)
    except AssertionError:
        print('FOCUS_DIAGNOSTIC', app.rpc('debug.notifications'), model(), native('p1'), flush=True)
        raise

    key_changes = app.rpc('debug.notifications')['nativeKeyChangeCount']
    cursor = app.rpc('events.head')['cursor']
    sibling = app.cli('panes', 'split', '--pane', 'p1', '--right')['paneId']
    assert selected() and native('p1')['firstResponder'], 'Basic split stole focus'
    app.rpc('command.run', id='terminal.find', pane='p1')
    eventually('Find owns the native responder', lambda: native('p1')['findFocused'])
    nested = app.cli('panes', 'split', '--pane', sibling, '--down', '--type', 'terminal',
                     '--expected-layout-revision', pane(sibling)['layoutRevision'])['paneId']
    assert selected() and native('p1')['findFocused'], 'Atomic background split stole Find focus'
    app.rpc('command.run', id='pane.type', pane=nested, type='browser', force=True)
    assert selected() and native('p1')['findFocused'], 'Background replacement stole Find focus'
    app.rpc('command.run', id='pane.close', pane=nested, force=True)
    assert selected() and native('p1')['findFocused'], 'Background close stole Find focus'
    app.rpc('command.run', id='terminal.find.end', pane='p1')

    second = app.cli('tabs', 'new', '--tab', 't1')['tabId']
    assert selected(), 'New native tab stole focus'
    window = app.rpc('command.run', id='window.new')['tabId']
    assert selected(), 'New window stole focus'
    assert app.rpc('debug.notifications')['nativeKeyChangeCount'] == key_changes, 'Background structural changes temporarily stole key focus'
    events = app.rpc('events.poll', after=cursor, scope='global')['events']
    assert not [event for event in events if event['topic'] == 'host.focus.changed'], events
    window_info = next(w for w in app.rpc('window.list')['windows'] if w['tabId'] == window)
    assert window_info['visible'] and not window_info['key'], 'Background window was hidden or activated'
    destination = tab(window)['focusedPane']
    app.cli('panes', 'move', '--pane', sibling, '--destination', destination, '--down',
            '--expected-layout-revision', pane(sibling)['layoutRevision'],
            '--expected-workspace-revision', app.rpc('context.inspect', pane=sibling)['workspaceRevision'])
    assert selected(), 'Background pane move stole global focus'
    assert tab(window)['focusedPane'] == destination, 'Background pane move changed destination selection'
    app.rpc('command.run', id='pane.type', pane=destination, type='browser', force=True)
    app.rpc('command.run', id='pane.close', pane=sibling, force=True)
    assert selected(), 'Background window mutation changed native key focus'

    app.rpc('command.run', id='pane.focus', pane=destination)
    app.rpc('command.run', id='browser.focusAddress', pane=destination)
    eventually('Browser address owns native responder', lambda: native(destination)['browser']['addressFocused'])
    app.rpc('command.run', id='layout.equalize', pane='p1')
    assert native(destination)['browser']['addressFocused'], 'Background layout operation stole address editing'
    app.rpc('command.run', id='pane.focus', pane='p1')

    # Native keyboard creation still intentionally selects its result.
    app.rpc('debug.key', chord='cmd+d')
    created = tab('t1')['focusedPane']
    assert created != 'p1' and selected(created), 'Native split no longer selects its new pane'
    app.rpc('command.run', id='pane.close', pane=created, force=True)
    app.rpc('command.run', id='pane.focus', pane='p1')
    explicit = app.cli('panes', 'split', '--pane', 'p1', '--right', '--focus-policy', 'new')['paneId']
    assert selected(explicit), 'Explicit split policy was ignored'
    app.rpc('command.run', id='pane.close', pane=explicit, force=True)
    app.rpc('command.run', id='pane.focus', pane='p1')

    definition = {'version': 1, 'id': str(uuid.uuid4()), 'name': 'Focus fixture', 'tabs': [
        {'name': 'Fixture tab', 'layout': {'kind': 'pane', 'pane': 'p1'},
         'panes': [{'id': 'p1', 'type': 'terminal', 'title': '', 'headerVisible': True, 'configuration': {}}]}]}
    app.rpc('layouts.create', definition=definition)
    app.cli('layouts', 'open', '--id', definition['id'])
    assert selected(), 'Opening a saved layout stole focus'
    app.cli('layouts', 'open', '--id', definition['id'], '--focus-policy', 'new')
    assert workspace_key() != 't1', 'Explicit saved-layout focus was ignored'
    app.rpc('command.run', id='pane.focus', pane='p1')
    app.rpc('command.run', id='settings.open')
    eventually('Settings owns focus again', settings_key)
    app.rpc('command.run', id='split.right', pane=tab(second)['focusedPane'])
    assert settings_key(), 'Background tab split raised a workspace window over Settings'

    # An existing non-workspace key window survives initial workspace creation too.
    for existing in list(model()['tabs']):
        app.rpc('command.run', id='tab.close', tab=existing['id'], force=True)
    assert settings_key() and not model()['tabs']
    app.rpc('command.run', id='window.new')
    assert settings_key(), 'First background workspace stole Settings focus'
    for existing in list(model()['tabs']):
        app.rpc('command.run', id='tab.close', tab=existing['id'], force=True)
    app.cli('layouts', 'open', '--id', definition['id'])
    assert settings_key(), 'First saved-layout workspace stole Settings focus'

print('PASS focus preservation: Settings/Find responders, CLI split/move/create/type/close/layout defaults, native creation and explicit navigation')
