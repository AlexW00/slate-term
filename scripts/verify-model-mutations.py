#!/usr/bin/env python3
"""Check that the regression tests detect three representative broken implementations.

Work only in a temporary copy. Never mutate the developer's source tree.
"""
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MUTANTS = [
    (
        "reversed-left-split", "Sources/SlateTermCore/Layout.swift",
        "self == .left || self == .up", "self == .right || self == .up",
        "splitPlacement",
    ),
    (
        "duplicate-leaf-accepted", "Sources/SlateTermCore/Workspace.swift",
        "leaves.count == paneIDs.count, Set(leaves) == paneIDs",
        "Set(leaves) == paneIDs", "restoreRejectsDuplicateLayoutLeavesAndMissingTabGroups",
    ),
    (
        "background-close-steals-focus", "Sources/SlateTermCore/Workspace.swift",
        "keyTabID = previousKeyTab", "_ = previousKeyTab",
        "closingFocusedPaneInBackgroundTabDoesNotStealKeyWindow",
    ),
]

with tempfile.TemporaryDirectory(prefix="slate-term-mutations-") as temporary:
    directory = pathlib.Path(temporary)
    shutil.copy2(ROOT / "Package.swift", directory)
    shutil.copytree(ROOT / "Sources", directory / "Sources")
    # SwiftPM validates every declared target even when --filter selects only model tests.
    for tests in (ROOT / "Tests").glob("SlateTerm*"):
        shutil.copytree(tests, directory / "Tests" / tests.name)
    for name, path, original, broken, test in MUTANTS:
        target = directory / path
        source = target.read_text()
        assert source.count(original) == 1, f"Mutation no longer matches: {name}"
        target.write_text(source.replace(original, broken))
        try:
            result = subprocess.run(
                ["swift", "test", "--package-path", str(directory), "--jobs", "4", "--filter", test],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180,
            )
            (ROOT / "artifacts").mkdir(exist_ok=True)
            (ROOT / "artifacts" / f"mutation-{name}.log").write_text(result.stdout)
            # A compilation failure is not evidence that the assertion catches the bug.
            assert result.returncode != 0 and "Expectation failed" in result.stdout, (
                f"Mutation survived or failed before assertions: {name}\n{result.stdout}"
            )
            print(f"PASS regression test killed mutant: {name}", flush=True)
        finally:
            target.write_text(source)
