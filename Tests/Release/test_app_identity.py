"""Keep app/window/tab identity contextual while permitting intentional parent references."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class AppIdentityTests(unittest.TestCase):
    def test_bare_product_and_default_tab_names_have_explicit_owners(self):
        # Parent references inside explanatory sentences are not app identity defaults.
        # Exact standalone labels must come from these two authoritative definitions.
        allowed = {
            ('Native/ApplicationLaunchContext.swift', 'Slate Terminal'),
            ('Bootstrap/main.m', 'Slate Terminal'),
            ('Sources/SlateTermCore/TabTitle.swift', 'New Tab'),
            ('Sources/SlateTermCore/CommandRegistry.swift', 'New Tab'),
        }
        found = set()
        for directory in ['Native', 'Bootstrap', 'Sources/SlateTermCore']:
            for path in (ROOT / directory).rglob('*'):
                if path.suffix not in {'.swift', '.m'}:
                    continue
                for match in re.finditer(r'@?"(Slate Terminal|New Tab)"', path.read_text()):
                    entry = (str(path.relative_to(ROOT)), match.group(1))
                    self.assertIn(entry, allowed, f'Hardcoded app/tab identity in {entry[0]}')
                    found.add(entry)
        self.assertEqual(found, allowed)


if __name__ == '__main__':
    unittest.main()
