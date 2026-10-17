"""Credential lifecycle tests use fake identities and never access a real keychain."""

import base64
import importlib.util
import multiprocessing
import os
from pathlib import Path
import signal
import stat
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_credentials", ROOT / "scripts/release-with-credentials.py")
credentials = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(credentials)
IDENTITY = "A" * 40


def inputs():
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "SLATE_RELEASE_CERTIFICATE_P12_BASE64": base64.b64encode(b"fake-p12").decode(),
        "SLATE_RELEASE_CERTIFICATE_PASSWORD": "test-only-password",
        "SLATE_NOTARY_KEY_P8_BASE64": base64.b64encode(b"-----BEGIN PRIVATE KEY-----\ntest-only-key\n-----END PRIVATE KEY-----\n").decode(),
        "SLATE_NOTARY_KEY_ID": "FAKE123456",
        "SLATE_NOTARY_ISSUER_ID": "12345678-1234-1234-1234-123456789abc",
        "OP_SERVICE_ACCOUNT_TOKEN": "test-only-op-token",
        "OP_SESSION_example": "test-only-session",
    }


class FakeTools:
    def __init__(self, fail_at=None, child_result=0):
        self.calls = []
        self.fail_at = fail_at
        self.child_result = child_result
        self.keychains = []
        self.child_environments = []
        self.identities = f'  1) {IDENTITY} "Developer ID Application: Test (FAKE123456)"\n'.encode()

    def __call__(self, command, **options):
        self.calls.append(command)
        operation = command[1] if command[0] == credentials.SECURITY else command[0]
        if operation == "create-keychain":
            path = Path(command[-1])
            self.keychains.append(path)
            assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
            path.write_bytes(b"fake-keychain")
        if operation == "import":
            assert stat.S_IMODE(Path(command[2]).stat().st_mode) == 0o600
            assert Path(command[2]).read_bytes() == b"fake-p12"
        if operation == credentials.XCRUN:
            path = Path(command[command.index("--key") + 1])
            assert stat.S_IMODE(path.stat().st_mode) == 0o600
            assert "--no-validate" in command
        if options.get("visible"):
            self.child_environments.append(options["env"])
            path = Path(options["env"]["SLATE_SIGNING_KEYCHAIN"])
            assert path.exists()
            assert not (path.parent / "certificate.p12").exists()
            assert not (path.parent / "notary.p8").exists()
        if self.fail_at == operation:
            raise credentials.CredentialError("Fake tool failed; output suppressed.")
        if operation == "find-identity":
            return 0, self.identities
        return (self.child_result if options.get("visible") else 0), b""


def concurrent_worker(start, output):
    fake = FakeTools()
    start.wait(10)
    try:
        def runner(command, **options):
            result = fake(command, **options)
            if options.get("visible"):
                time.sleep(0.15)
            return result
        result = credentials.with_credentials(["release"], inputs(), runner=runner)
        output.put((result, [str(p) for p in fake.keychains], fake.calls))
    except Exception:
        output.put(("failed", [], []))


class CredentialLifecycleTests(unittest.TestCase):
    def test_success_isolated_identity_and_no_raw_secrets_in_child(self):
        fake = FakeTools()
        command = ["release", "worktree with spaces", "$(must-not-execute)"]
        self.assertEqual(credentials.with_credentials(command, inputs(), runner=fake), 0)
        child = fake.child_environments[0]
        self.assertEqual(child["SLATE_SIGNING_IDENTITY"], IDENTITY)
        self.assertEqual(child["SLATE_NOTARY_PROFILE"], "slate-release")
        self.assertEqual(child["SLATE_NOTARY_KEYCHAIN"], child["SLATE_SIGNING_KEYCHAIN"])
        self.assertTrue(set(credentials.INPUTS).isdisjoint(child))
        self.assertFalse(any(name.startswith("OP_") for name in child))
        self.assertIn(command, fake.calls)
        self.assertFalse(fake.keychains[0].parent.exists())
        self.assertEqual(fake.calls[-1], [credentials.SECURITY, "delete-keychain", str(fake.keychains[0])])
        self.assertFalse(any("list-keychains" in c or "default-keychain" in c for c in fake.calls))
        for call in fake.calls:
            if call[0] == credentials.SECURITY:
                self.assertIn(str(fake.keychains[0]), call)

    def test_cleanup_on_every_tool_failure(self):
        for operation in ("create-keychain", "set-keychain-settings", "unlock-keychain", "import",
                          "set-key-partition-list", "find-identity", credentials.XCRUN, "release"):
            with self.subTest(operation=operation):
                fake = FakeTools(fail_at=operation)
                with self.assertRaises(credentials.CredentialError):
                    credentials.with_credentials(["release"], inputs(), runner=fake)
                self.assertEqual(fake.calls[-1][1], "delete-keychain")
                self.assertFalse(fake.keychains[0].parent.exists())

    def test_cleanup_failure_is_not_reported_as_success(self):
        fake = FakeTools(fail_at="delete-keychain")
        with self.assertRaisesRegex(credentials.CredentialError, "cleanup failed"):
            credentials.with_credentials(["release"], inputs(), runner=fake)
        self.assertFalse(fake.keychains[0].parent.exists())

    def test_child_exit_code_preserved(self):
        fake = FakeTools(child_result=19)
        self.assertEqual(credentials.with_credentials(["release"], inputs(), runner=fake), 19)
        self.assertFalse(fake.keychains[0].parent.exists())

    def test_cleanup_on_interruption(self):
        fake = FakeTools()
        def interrupt(command, **options):
            result = fake(command, **options)
            if options.get("visible"):
                raise credentials.Interrupted(signal.SIGTERM)
            return result
        with self.assertRaises(credentials.Interrupted):
            credentials.with_credentials(["release"], inputs(), runner=interrupt)
        self.assertFalse(fake.keychains[0].parent.exists())
        self.assertEqual(fake.calls[-1][1], "delete-keychain")

    def test_multiple_or_wrong_identities_fail_closed(self):
        for identities in (b"no identities", FakeTools().identities * 2,
                           FakeTools().identities.replace(b"Developer ID Application", b"Apple Development")):
            fake = FakeTools()
            fake.identities = identities
            with self.assertRaisesRegex(credentials.CredentialError, "exactly one"):
                credentials.with_credentials(["release"], inputs(), runner=fake)
            self.assertEqual(fake.child_environments, [])
            self.assertFalse(fake.keychains[0].parent.exists())

    def test_malformed_inputs_fail_before_keychain_changes(self):
        for name, value in ((credentials.INPUTS[0], "broken base64!"),
                            (credentials.INPUTS[2], base64.b64encode(b"not-a-pem").decode()),
                            (credentials.INPUTS[3], "bad-id"), (credentials.INPUTS[4], "bad-issuer")):
            with self.subTest(name=name):
                environment = inputs()
                environment[name] = value
                fake = FakeTools()
                with self.assertRaises(credentials.CredentialError):
                    credentials.with_credentials(["release"], environment, runner=fake)
                self.assertEqual(fake.calls, [])

    def test_missing_inputs_fail_before_keychain_changes(self):
        environment = inputs()
        del environment[credentials.INPUTS[1]]
        fake = FakeTools()
        with self.assertRaisesRegex(credentials.CredentialError, "Missing release input"):
            credentials.with_credentials(["release"], environment, runner=fake)
        self.assertEqual(fake.calls, [])

    def test_two_concurrent_runs_never_delete_each_others_keychain(self):
        context = multiprocessing.get_context("fork")
        start, output = context.Event(), context.Queue()
        processes = [context.Process(target=concurrent_worker, args=(start, output)) for _ in range(2)]
        for process in processes:
            process.start()
        try:
            start.set()
            results = [output.get(timeout=15) for _ in processes]
            paths = []
            for result, keychains, calls in results:
                self.assertEqual(result, 0)
                self.assertEqual(len(keychains), 1)
                paths.extend(keychains)
                self.assertEqual([c[-1] for c in calls if len(c) > 1 and c[1] == "delete-keychain"], keychains)
                self.assertFalse(Path(keychains[0]).parent.exists())
            self.assertEqual(len(set(paths)), 2)
        finally:
            for process in processes:
                process.join(timeout=5)
                if process.is_alive():
                    process.kill()
                    process.join()


class ReferenceFileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="slate credentials tests ")
        self.directory = Path(self.temporary.name)
        self.path = self.directory / "release.env.op"
        self.path.write_text((ROOT / "config/release.env.op.example").read_text())
        self.path.chmod(0o600)

    def tearDown(self):
        self.temporary.cleanup()

    def test_private_external_file_with_spaces_is_accepted(self):
        self.assertEqual(credentials.validate_env_file(self.path), self.path.resolve())

    def test_default_path_is_shared_between_worktrees(self):
        environment = {"XDG_CONFIG_HOME": str(self.directory / "shared config")}
        expected = self.directory / "shared config/slate-term/release.env.op"
        self.assertEqual(credentials.config_path(environment), expected)
        with self.assertRaises(credentials.CredentialError):
            credentials.config_path({"XDG_CONFIG_HOME": "relative"})

    def test_unrelated_checkout_and_linked_worktree_are_rejected(self):
        for linked in (False, True):
            checkout = self.directory / ("linked worktree" if linked else "checkout")
            checkout.mkdir()
            if linked:
                (checkout / ".git").write_text("gitdir: /somewhere/repo/.git/worktrees/linked\n")
            else:
                (checkout / ".git").mkdir()
            path = checkout / "release.env.op"
            path.write_text(self.path.read_text())
            path.chmod(0o600)
            with self.assertRaisesRegex(credentials.CredentialError, "outside all Git checkouts"):
                credentials.validate_env_file(path)

    def test_insecure_mode_and_symlink_rejected(self):
        self.path.chmod(0o644)
        with self.assertRaisesRegex(credentials.CredentialError, "mode 600"):
            credentials.validate_env_file(self.path)
        self.path.chmod(0o600)
        alias = self.directory / "alias"
        alias.symlink_to(self.path)
        with self.assertRaisesRegex(credentials.CredentialError, "regular file"):
            credentials.validate_env_file(alias)

    def test_plaintext_extra_variable_and_missing_reference_rejected(self):
        original = self.path.read_text()
        for contents in (original.replace('"op://Release/Slate Release/notary-key-id"', '"fake-value"'),
                         original + "PATH=op://Release/Slate Release/path\n",
                         "# missing all references\n"):
            self.path.write_text(contents)
            with self.assertRaises(credentials.CredentialError):
                credentials.validate_env_file(self.path)

    def test_local_reexec_uses_op_without_evaluating_command(self):
        with mock.patch.dict(os.environ, {"OP_SESSION_example": "test-only-session"}):
            with mock.patch.object(credentials, "run", return_value=(23, b"")) as run:
                self.assertEqual(credentials.main(["--env-file", str(self.path), "--", "release", "a b"]), 23)
        self.assertEqual(run.call_args.kwargs["env"]["OP_SESSION_example"], "test-only-session")
        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["op", "run", "--env-file", str(self.path.resolve())])
        self.assertEqual(command[-4:], ["--from-environment", "--", "release", "a b"])
        self.assertNotIn("--no-masking", command)


class ProcessSafetyTests(unittest.TestCase):
    def test_subprocess_errors_do_not_disclose_secret_output(self):
        sentinel = "UNIQUE_TEST_SECRET_SENTINEL"
        command = [sys.executable, "-c", f"import sys; print('{sentinel}'); print('{sentinel}', file=sys.stderr); sys.exit(42)"]
        with self.assertRaises(credentials.CredentialError) as failure:
            credentials.run(command)
        self.assertIn("exit 42", str(failure.exception))
        self.assertNotIn(sentinel, str(failure.exception))

    def test_timeout_terminates_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "pid"
            code = "import os, pathlib, sys, time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
            with self.assertRaisesRegex(credentials.CredentialError, "timed out"):
                credentials.run([sys.executable, "-c", code, str(path)], timeout=0.3)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(path.read_text()), 0)

    def test_signal_is_forwarded_and_child_reaped(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "pid"
            code = "import os, pathlib, sys, time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
            timer = threading.Timer(0.3, lambda: os.kill(os.getpid(), signal.SIGTERM))
            with credentials.interrupt_handlers():
                timer.start()
                try:
                    with self.assertRaises(credentials.Interrupted):
                        credentials.run([sys.executable, "-c", code, str(path)], timeout=None)
                finally:
                    timer.cancel()
                    timer.join()
            with self.assertRaises(ProcessLookupError):
                os.kill(int(path.read_text()), 0)


if __name__ == "__main__":
    unittest.main()
