#!/usr/bin/env python3
"""Offline config validation must not need a running app or mutate its input."""
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLI = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/Helpers/slate-term"
environment = dict(os.environ, SLATE_TERM_SOCKET="/no-running-slate-term.sock")

with tempfile.TemporaryDirectory(prefix="slate-config-cli-") as temporary:
    file = pathlib.Path(temporary) / "config.toml"

    def validate(source, valid):
        file.write_text(source)
        result = subprocess.run([str(CLI), "config", "validate", "--file", str(file), "--json"],
                                env=environment, text=True, capture_output=True, timeout=10)
        assert (result.returncode == 0) == valid, result.stderr
        assert file.read_text() == source
        if valid:
            return json.loads(result.stdout)
        assert result.stderr

    result = validate('[terminal]\nfont_size = 17.5\n', True)
    assert result["valid"] and result["configuration"]["terminal"]["font_size"] == 17.5
    for source in ['[terminal]\nfont_size = -1\n', '[terminal]\nshell = "/bin"\n',
                   '[terminal]\nfont_size = 1970-01-01T00:00:13Z\n', '[typo]\nvalue = 1\n']:
        validate(source, False)
    file.unlink()
    result = subprocess.run([str(CLI), "config", "validate", "--file", str(file)], env=environment,
                            text=True, capture_output=True, timeout=10)
    assert result.returncode != 0, "An explicitly missing file was validated as defaults"
    print("PASS config CLI: offline validation, typed values, errors, missing-file rejection, no input mutation")
