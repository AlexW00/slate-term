#!/usr/bin/env python3
"""Focused Settings close consent, using one owned app and isolated layout files."""
import json

from api_fixture import AppFixture, ROOT, eventually


with AppFixture('settings-layout-close') as app:
    def editor(**params):
        return app.rpc('debug.savedLayouts', **params)

    def close(answer='cancel', **params):
        return app.rpc('debug.closeConfirmation', settings=True, answer=answer, **params)

    def shown(state):
        assert len(state['prompts']) == 1, state
        prompt = state['prompts'][0]
        assert 'closing Settings' in prompt['message'], prompt
        assert prompt['buttons'] == ['Cancel', 'Discard Changes', 'Save All'], prompt

    def reopen():
        app.rpc('command.run', id='settings.open')
        assert app.rpc('debug.settings', inspectOnly=True)['visible']

    first = editor(create=True)
    first_file = first['file']
    second = editor(create=True)
    second_file = second['file']
    first_path = app.root / 'layouts' / first_file
    second_path = app.root / 'layouts' / second_file
    original_first = json.loads(first_path.read_text())
    original_second = json.loads(second_path.read_text())

    # A clean close must not prompt, including through the Settings Command-W path.
    state = close(key=True)
    assert not state['visible'] and not state['prompts'], state
    reopen()
    editor(file=first_file, name='Retained layout draft')
    editor(file=second_file)
    app.rpc('debug.settings', inspectOnly=True, section='General')
    capture = ROOT / 'artifacts/settings-layout-close-confirmation.png'
    capture.unlink(missing_ok=True)
    state = close(screenshot=str(capture))
    shown(state)
    assert capture.stat().st_size > 1000
    assert state['visible'] and state['dirty'], state
    assert editor(file=first_file)['definition']['name'] == 'Retained layout draft'
    assert json.loads(first_path.read_text()) == original_first

    # Quit no longer asks about layouts, even if the user would cancel a prompt.
    assert app.rpc('debug.closeConfirmation', quit=True, answer='cancel') is True
    assert editor(file=first_file)['dirty']

    # Discard all selections, not only the currently selected layout.
    editor(file=second_file, name='Second discarded draft')
    state = close('discard', key=True)
    shown(state)
    assert not state['visible'] and not state['dirty'], state
    assert json.loads(first_path.read_text()) == original_first
    assert json.loads(second_path.read_text()) == original_second
    reopen()
    for file in [first_file, second_file]:
        assert not editor(file=file)['dirty']
    state = close()
    assert not state['visible'] and not state['prompts'], state

    # Save All persists drafts in every selection, including while another Settings section is shown.
    reopen()
    editor(file=first_file, name='First saved on close')
    editor(file=second_file, name='Second saved on close')
    app.rpc('debug.settings', inspectOnly=True, section='General')
    state = close('save')
    shown(state)
    assert not state['visible'] and not state['dirty'], state
    assert json.loads(first_path.read_text())['name'] == 'First saved on close'
    assert json.loads(second_path.read_text())['name'] == 'Second saved on close'
    reopen()
    state = close(key=True)
    assert not state['visible'] and not state['prompts'], state

    # A stale source causes Save All to fail without closing or losing the draft/external edit.
    reopen()
    editor(file=first_file, name='Unsaved conflicting draft')
    external = json.loads(first_path.read_text())
    external['name'] = 'External edit kept'
    first_path.write_text(json.dumps(external))
    editor(file=second_file)
    app.rpc('debug.settings', inspectOnly=True, section='General')
    state = close('save', key=True)
    shown(state)
    assert state['visible'] and state['dirty'] and state['error'], state
    assert state['section'] == 'Layouts', state
    draft = editor(file=first_file)
    assert draft['dirty'] and draft['conflict'] and draft['definition']['name'] == 'Unsaved conflicting draft', draft
    assert json.loads(first_path.read_text()) == external
    editor(revert=True)
    editor(name='Recovered save')
    state = close('save')
    assert not state['visible'] and not state['dirty'], state
    assert json.loads(first_path.read_text())['name'] == 'Recovered save'

    # Process quit protection still runs independently of dirty saved-layout drafts.
    reopen()
    editor(file=first_file, name='Draft while shell busy')
    app.rpc('terminal.send', pane='p1', text="/bin/sleep 30\r")
    eventually('owned foreground process', lambda: any(p['paneId'] == 'p1' and p['needsConfirmClose']
                                                      for p in app.rpc('debug.inspect')['panes']))
    assert app.rpc('debug.closeConfirmation', quit=True, answer='cancel') is False
    assert app.rpc('debug.closeConfirmation', quit=True, answer='terminate') is True
    assert editor(file=first_file)['dirty']
    state = close('discard')
    assert not state['visible'] and not state['dirty'], state

print('PASS Settings close/Cmd-W: all-layout Cancel/Discard/Save All, no stale prompts, failed-save recovery, no layout quit prompt and retained process quit protection')
