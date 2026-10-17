#!/usr/bin/env python3
"""Agent skill install parity across CLI, socket and bridge, using an isolated home folder."""
import json
import os
import time
from api_fixture import ROOT, AppFixture, eventually
from plugin_package_fixture import package_fixture

with AppFixture('agent-skills') as app:
    home = app.root / 'agent-home'
    managed = app.root / 'skills/slate-terminal'
    listing = app.rpc('skills.list')
    agents = {agent['id']: agent for agent in listing['agents']}
    assert list(agents)[:2] == ['agents', 'claude'], list(agents)
    assert all(agent['status'] == 'notInstalled' for agent in agents.values()), listing
    assert agents['agents']['path'] == str(home / '.agents/skills/slate-terminal')
    assert agents['claude']['detected'] is False
    assert app.cli('skill', 'list') == listing, 'CLI and socket results differ'
    commands = {command['id'] for command in app.rpc('command.list')}
    assert {'skills.settings', 'skills.reveal'} <= commands

    installed = app.cli('skill', 'install', '--agent', 'agents', '--agent', 'claude')
    statuses = {agent['id']: agent['status'] for agent in installed['agents']}
    assert statuses['agents'] == statuses['claude'] == 'installed' and statuses['codex'] == 'notInstalled', statuses
    link = home / '.claude/skills/slate-terminal'
    assert link.is_symlink() and os.readlink(link) == str(managed), os.readlink(link)
    assert (link / 'SKILL.md').read_text().startswith('---'), 'Linked skill is unreadable'
    assert (link / 'references/ui/INDEX.md').exists()
    assert not any(part.startswith('.') for path in managed.rglob('*') for part in path.relative_to(managed).parts)
    assert app.rpc('skills.install', agents=['claude'])['agents'] == installed['agents'], 'Reinstall is not a no-op'

    foreign = home / '.codex/skills/slate-terminal'
    foreign.mkdir(parents=True)
    (foreign / 'SKILL.md').write_text('someone else')
    app.rpc('skills.install', agents=['codex'], error=-32050)
    app.rpc('skills.uninstall', agents=['codex'], error=-32050)
    assert (foreign / 'SKILL.md').read_text() == 'someone else'
    app.rpc('skills.install', agents=['nope'], error=-32602)
    app.rpc('skills.install', agents='claude', error=-32602)
    app.rpc('skills.install', agents=[], error=-32602)
    app.rpc('skills.list', extra=True, error=-32602)

    panel = app.root / 'panel'
    panel.mkdir()
    (panel / 'index.html').write_text('<!doctype html><title>Skill Fixture</title>')
    app.rpc('plugins.register', packagePath=package_fixture({'id': 'skill-fixture', 'title': 'Skill Fixture', 'source': {'kind': 'directory', 'path': str(panel)}}, app.root))
    app.rpc('command.run', id='pane.type', pane='p1', type='skill-fixture', force=True)

    def evaluate(script):
        return app.rpc('debug.pluginEval', pane='p1', script=script)
    eventually('plugin document', lambda: evaluate('typeof workspace') == 'object')
    assert evaluate('await workspace.call("skills.list")') == app.rpc('skills.list'), 'Bridge and socket results differ'
    removed = evaluate('await workspace.rpc["skills.uninstall"]({agents:["claude"]})')
    assert {agent['id']: agent['status'] for agent in removed['agents']}['claude'] == 'notInstalled'
    assert not link.exists() and not link.is_symlink() and managed.exists()

    app.rpc('debug.settings', section='AI Agents')
    time.sleep(0.5)  # Let the window open animation finish before capturing.
    app.rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/agent-skills-settings.png'))

    # Disk is the source of truth: the section re-reads it when shown again and when the app regains focus.
    def shown(agent):
        return app.rpc('debug.settings', inspectOnly=True)['agentSkills'][agent]
    assert shown('agents') == 'installed'
    (home / '.agents/skills/slate-terminal').unlink()
    app.rpc('debug.settings', inspectOnly=True, section='General')
    app.rpc('debug.settings', inspectOnly=True, section='AI Agents')
    eventually('section switch shows the removal', lambda: shown('agents') == 'notInstalled')
    gemini = home / '.gemini/skills/slate-terminal'
    gemini.parent.mkdir(parents=True)
    gemini.symlink_to(managed)
    app.rpc('debug.activate')
    eventually('regaining focus shows the external install', lambda: shown('gemini') == 'installed')
print('Agent skill listing, install, conflicts and bridge parity passed')
