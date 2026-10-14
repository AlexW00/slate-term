#!/usr/bin/env python3
"""Fresh owned native evidence for layout/tab commands and picker availability."""
import time
from api_fixture import AppFixture, ROOT

with AppFixture('layout-ui') as app:
    t2 = app.cli('tabs', 'new')['tabId']
    t3 = app.cli('tabs', 'new')['tabId']
    revision = app.rpc('workspace.snapshot')['workspaceRevision']
    app.cli('tabs', 'reorder', '--tab', t3, '--index', '0', '--expected-workspace-revision', revision)
    app.cli('tabs', 'focus', '--tab', 't1')
    revision = app.rpc('pane.inspect', pane='p1')['layoutRevision']
    app.cli('panes', 'split', '--pane', 'p1', '--right', '--type', 'browser', '--new-pane-fraction', '.35',
            '--focus-policy', 'preserve', '--expected-layout-revision', revision)
    app.cli('panes', 'set-title', '--pane', 'p1', '--title', 'Build output')
    for theme, query, name in [('light', 'clear title', 'layout-title-picker-light'),
                               ('dark', 'tab', 'layout-tab-picker-dark')]:
        app.rpc('command.run', id=f'appearance.{theme}')
        app.rpc('debug.activate')
        # Allow native appearance/material rendering to settle before evidence.
        time.sleep(.7)
        app.rpc('debug.screenshot', path=str(ROOT / f'artifacts/layout-native-{theme}.png'))
        app.rpc('debug.commandPicker', show=True, pane='p1', tab='t1', query=query)
        time.sleep(.7)
        app.rpc('debug.screenshot', picker=True, pickerContext=True, path=str(ROOT / f'artifacts/{name}.png'))
        app.rpc('debug.commandPicker', dismiss=True)
    assert app.rpc('debug.inspect')['nativeTabGroups'] == [[t3, 't1', t2]]
print('Captured owned light/dark native layouts and title/tab picker states')
