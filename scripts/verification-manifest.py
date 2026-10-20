#!/usr/bin/env python3
"""Record a complete gate run only if its source inputs remained unchanged."""
import datetime
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
artifacts = root / 'artifacts'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def sources():
    paths = []
    for directory in ['Sources', 'Native', 'Bootstrap', 'Tests', 'scripts', 'slate-term', 'skills']:
        paths.extend(p for p in (root / directory).rglob('*') if p.is_file() and p.suffix in ['.swift', '.m', '.h', '.sh', '.py', '.js', '.cjs', '.plist', '.json', '.mp4', '.md'])
    paths += [root / 'Package.swift', root / 'Package.resolved', root / 'AppInfo.plist', root / 'slate-term.xcodeproj/project.pbxproj',
              root / 'slate-term.xcodeproj/xcshareddata/xcschemes/SlateTermApp.xcscheme']
    return {str(p.relative_to(root)): digest(p) for p in sorted(paths)}

mode = sys.argv[1]
if mode == 'start':
    artifacts.mkdir(exist_ok=True)
    (artifacts / 'verification.json').unlink(missing_ok=True)
    (artifacts / 'verification-checks.txt').write_text('')
    (artifacts / 'verification-input.json').write_text(json.dumps(sources(), indent=2) + '\n')
elif mode == 'finish':
    before = json.loads((artifacts / 'verification-input.json').read_text())
    after = sources()
    changed = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    if changed:
        raise SystemExit('FAIL source changed during verification: ' + ', '.join(changed))
    from verification_gates import GATES, ORDER, validate
    validate(root)
    checks = (artifacts / 'verification-checks.txt').read_text().splitlines()
    if checks != list(ORDER):
        raise SystemExit('FAIL incomplete or reordered inventory; run bash scripts/verify-all.sh')
    app = root / '.derived/Build/Products/Debug/Slate Terminal.app/Contents'
    runtime = app / 'Frameworks/SlateRuntime.framework'
    products = [app / 'MacOS/Slate Terminal', runtime / 'SlateRuntime',
                runtime / 'Helpers/slate-term', runtime / 'Helpers/slate-layout-launcher']
    for gate in GATES:
        if gate.native:
            products.append(root / gate.product)
            products.extend((root / gate.native_directory).glob('*.dylib'))
    result = {
        'completedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'checks': checks,
        'sources': after,
        'binaries': {str(path.relative_to(root)): digest(path) for path in products},
    }
    (artifacts / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print('PASS expanded verification; unchanged source and binary hashes recorded in artifacts/verification.json')
else:
    raise SystemExit('Expected start or finish')
