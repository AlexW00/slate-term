#!/usr/bin/env python3
"""appearance.get parity, host.appearance.changed publication and plugin page theme injection."""
import json
from api_fixture import AppFixture, eventually

MOCHA, LATTE = '#1e1e2e', '#eff1f5'
source = '[appearance]\ntheme = "dark"\n[terminal]\nshell = "/bin/zsh"\nlight_theme = "Catppuccin Latte"\ndark_theme = "Catppuccin Mocha"\n'
with AppFixture('theme-api', source) as app:
    def changes(after, wait=0):
        batch = app.rpc('events.poll', after=after, topics=['host.appearance.changed'], waitMilliseconds=wait)
        return batch['events']

    appearance = app.rpc('appearance.get')
    assert appearance['tone'] == 'dark' and appearance['slot'] == 'dark' and appearance['setting'] == 'dark', appearance
    assert appearance['systemAppearance'] is None, 'Forced appearance must not report the system value'
    assert appearance['paletteName'] == 'Catppuccin Mocha' and appearance['palette']['background'] == MOCHA, appearance
    assert len(appearance['palette']['ansi']) == 16 and appearance['font'] == {'family': 'SF Mono', 'size': 13}, appearance
    assert app.cli('appearance', 'get') == appearance, 'CLI and socket results differ'
    app.rpc('appearance.get', unexpected=1, error=-32602)
    assert app.cli('appearance', 'get', 'dark', error=True)
    assert 'appearance' in app.rpc('api.describe') and 'appearance.get' in app.rpc('api.describe')['methods']

    panel = app.root / 'panel'
    panel.mkdir()
    (panel / 'index.html').write_text('<!doctype html><title>Theme Fixture</title><iframe srcdoc="<p>child</p>"></iframe>')
    app.rpc('plugins.register', manifest={'id': 'theme-fixture', 'title': 'Theme Fixture', 'source': {'kind': 'directory', 'path': str(panel)}})
    app.rpc('command.run', id='pane.type', pane='p1', type='theme-fixture', force=True)

    def evaluate(script):
        return app.rpc('debug.pluginEval', pane='p1', script=script)

    def variable(name):
        return evaluate(f'getComputedStyle(document.documentElement).getPropertyValue({json.dumps(name)}).trim()')

    eventually('plugin document', lambda: evaluate('typeof workspace') == 'object')
    assert evaluate('await workspace.appearance.get()') == appearance, 'Bridge and socket results differ'
    assert evaluate('await workspace.call("appearance.get")') == appearance
    # The theme script runs at document start, before any page script could read the variables.
    assert variable('--st-bg') == MOCHA and variable('--st-ansi-15') == appearance['palette']['ansi'][15]
    assert evaluate('document.documentElement.dataset.appearance') == 'dark'
    assert variable('--st-font-mono-size') == '12px', variable('--st-font-mono-size')
    eventually('subframe loaded', lambda: evaluate('document.querySelector("iframe").contentDocument?.readyState') == 'complete')
    assert evaluate('document.querySelector("iframe").contentDocument.documentElement.style.getPropertyValue("--st-bg")') == ''

    cursor = app.rpc('events.head')['cursor']
    app.cli('appearance', 'light')
    eventually('one appearance event', lambda: len(changes(cursor)) >= 1)
    events = changes(cursor, wait=300)
    assert len(events) == 1, events
    light = app.rpc('appearance.get')
    assert events[0]['payload'] == {'revision': light['revision'], 'tone': 'light', 'slot': 'light'}, events
    assert light['palette']['background'] == LATTE and light['revision'] != appearance['revision']
    eventually('live page restyled', lambda: variable('--st-bg') == LATTE)
    assert evaluate('document.documentElement.dataset.appearance') == 'light'

    cursor = app.rpc('events.head')['cursor']
    app.cli('appearance', 'light')
    app.rpc('config.reload')
    assert changes(cursor, wait=500) == [], 'A no-op apply published an appearance event'
    assert app.rpc('appearance.get')['revision'] == light['revision']

    cursor = app.rpc('events.head')['cursor']
    app.cli('config', 'set', '--key', 'terminal.font_size', '--value', '15', '--expected-source-revision', app.rpc('config.get')['sourceRevision'])
    eventually('font change event', lambda: len(changes(cursor)) == 1)
    eventually('font variable', lambda: variable('--st-font-mono-size') == '14px')

    # Reloading keeps the injected palette for the new document.
    evaluate('location.reload()')
    eventually('reloaded document', lambda: evaluate('typeof workspace') == 'object' and variable('--st-bg') == LATTE)

    app.rpc('command.run', id='pane.type', pane='p1', type='browser', force=True)
    probe = 'JSON.stringify([document.readyState, document.documentElement.style.getPropertyValue("--st-bg"), document.documentElement.dataset.appearance ?? null])'

    def browser_state():
        # The new browser pane may still be navigating; a changed document is retried.
        try:
            return json.loads(app.rpc('browser.eval', pane='p1', script=probe))
        except AssertionError:
            return None
    eventually('browser pane has no theme injection', lambda: browser_state() == ['complete', '', None])
print('Theme API parity, change events and plugin page injection passed')
