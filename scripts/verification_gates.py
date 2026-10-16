"""Authoritative ordered inventory for selected and complete verification runs."""
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class NativeRecipe:
    executable: str
    package: bool = False
    ghostty: bool = False
    cli: bool = False


# Each recipe uses its existing script for BOTH host preparation and guest execution.
NATIVE_RECIPES = {
    'terminal-keys': NativeRecipe('terminal-keys'),
    'terminal-runs': NativeRecipe('terminal-runs'),
    'event-hub': NativeRecipe('event-hub-lifecycle'),
    'event-efficiency': NativeRecipe('event-efficiency', package=True, ghostty=True),
    'plugin-process': NativeRecipe('process-lifecycle'),
    'plugin-listener': NativeRecipe('plugin-listener'),
    'process-titles': NativeRecipe('process-titles'),
    'pane-movement-native': NativeRecipe('pane-movement'),
    'text-checking': NativeRecipe('text-checking'),
    'pane-titles-native': NativeRecipe('pane-titles'),
    'welcome-native': NativeRecipe('welcome'),
    'dividers-native': NativeRecipe('dividers'),
    'tab-overview': NativeRecipe('tab-overview'),
    'terminal': NativeRecipe('terminal-lifecycle', ghostty=True),
    'web-operations': NativeRecipe('web-operations'),
    'browser-data': NativeRecipe('browser-data', package=True),
    'browser-navigation': NativeRecipe('browser-navigation', package=True),
    'service-commands': NativeRecipe('service-commands', package=True, cli=True),
    'service-generation': NativeRecipe('service-generation', package=True, cli=True),
}
HOST_COMMANDS = {
    'engine': ('bash', 'scripts/build-ghostty.sh'),
    'model': ('bash', 'scripts/verify-model.sh'),
    'vm-runner': ('python3', '-m', 'unittest', 'discover', '-s', 'Tests/VMRunner', '-v'),
    'mutations': ('python3', 'scripts/verify-model-mutations.py'),
    'build': ('bash', 'scripts/build-app.sh'),
    'whitespace': ('git', 'diff', '--check'),
}
ORDER = (
    'engine', 'model', 'vm-runner', 'mutations',
    'terminal-keys', 'terminal-runs', 'event-hub', 'event-efficiency',
    'plugin-process', 'plugin-listener', 'process-titles', 'pane-movement-native',
    'text-checking', 'pane-titles-native', 'welcome-native', 'dividers-native',
    'tab-overview', 'terminal', 'build', 'plugin-worker',
    'app-1', 'app-2', 'app-3',
    'config-cli', 'settings', 'settings-window', 'saved-layouts', 'settings-layout-close',
    'notifications', 'command-picker', 'window-recovery', 'appearance', 'palettes',
    'menu-ui', 'shell', 'web-operations', 'browser-data', 'browser-navigation',
    'browser-profiles', 'browser', 'web', 'context', 'api-context', 'api-settings', 'api-parity', 'presence',
    'theme-api', 'agent-skills', 'welcome', 'api-negotiation', 'service-session',
    'service-commands', 'service-generation', 'background-services', 'plugin-settings-api',
    'layout-api', 'semantic-events', 'semantic-editor', 'divider-events',
    'divider-native-commands', 'divider-presentation', 'divider-reentrancy',
    'divider-ordinary', 'causation', 'storage-causation', 'command-lifecycle',
    'settings-lifecycle', 'workspace-persistence', 'pane-titles', 'tab-titles',
    'pane-headers', 'cross-window-pane-movement', 'pane-movement', 'plugins',
    'plugin-lifecycle', 'plugin-services', 'plugin-commands', 'plugin-header-buttons',
    'events', 'extension-interop', 'whitespace',
)
ALIASES = {'app': 'app-1'}


@dataclass(frozen=True)
class Gate:
    name: str
    command: tuple
    location: str
    native: object = None

    @property
    def native_directory(self):
        return '.build/vm-native/' + self.name

    @property
    def product(self):
        return self.native_directory + '/' + self.native.executable

    @property
    def requires_app(self):
        return self.location == 'vm' and self.native is None


def make_gate(name):
    if name in HOST_COMMANDS:
        return Gate(name, HOST_COMMANDS[name], 'host')
    if name in NATIVE_RECIPES:
        return Gate(name, ('bash', 'scripts/verify-' + name + '.sh'), 'vm', NATIVE_RECIPES[name])
    script = 'app' if name in {'app-1', 'app-2', 'app-3'} else name
    return Gate(name, ('python3', 'scripts/verify-' + script + '.py'), 'vm')


GATES = tuple(make_gate(name) for name in ORDER)
BY_NAME = {gate.name: gate for gate in GATES}


def select(names, complete=False):
    if complete:
        if names:
            raise ValueError('Use either --all or selected test names, not both')
        return list(GATES)
    result = []
    for name in names:
        canonical = ALIASES.get(name, name)
        if canonical not in BY_NAME:
            raise ValueError('Unknown test: ' + name + '. Use --list.')
        if BY_NAME[canonical] not in result:
            result.append(BY_NAME[canonical])
    return result


def validate(root):
    if len(BY_NAME) != len(GATES):
        raise ValueError('Duplicate gate identifiers in verification inventory')
    registered = set()
    for gate in GATES:
        for argument in gate.command:
            if argument.startswith('scripts/'):
                if not (root / argument).is_file():
                    raise ValueError('Missing gate script: ' + argument)
                registered.add(Path(argument).name)
    scripts = {path.name for pattern in ['verify-*.sh', 'verify-*.py']
               for path in (root / 'scripts').glob(pattern)}
    missing = scripts - registered - {'verify-all.sh', 'verify-vm.py'}
    if missing:
        raise ValueError('Unregistered verification scripts: ' + ', '.join(sorted(missing)))
