"""Fault injection against the real shell replacement function; no network or installed apps."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/install.sh"
PRELUDE = 'source "$1"; shift; _howr_check_target() { :; }; _howr_verify() { :; }; '


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.app"
        self.source.mkdir()
        (self.source / "new").write_text("new version")
        self.dest = self.root / "Applications"
        self.target = self.dest / "Howr.app"
        self.target.mkdir(parents=True)
        (self.target / "old").write_text("old version")

    def command(self, extra=""):
        return ["/bin/bash", "-c", PRELUDE + extra + ' _howr_install_app "$1" "$2"',
                "howr-test", str(SCRIPT), str(self.source), str(self.dest)]

    def test_success_replaces_without_nesting(self):
        result = subprocess.run(self.command(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.target / "new").is_file())
        self.assertFalse((self.target / "Howr.app").exists())
        self.assertFalse((self.dest / ".howr-install.lock").exists())

    def test_sigterm_after_parking_restores_previous_app(self):
        fault = '_howr_move() { /bin/mv "$@"; if [[ "$2" == */previous.app ]]; then kill -TERM "$$"; fi; };'
        result = subprocess.run(self.command(fault), capture_output=True)
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertTrue((self.target / "old").is_file())
        self.assertFalse((self.dest / ".howr-install.lock").exists())

    def test_failed_copy_preserves_existing_install(self):
        result = subprocess.run(self.command('_howr_copy() { return 1; };'), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.target / "old").is_file())

    def test_concurrent_replacement_is_rejected(self):
        ready, proceed = self.root / "ready", self.root / "proceed"
        env = {**os.environ, "HOWR_TEST_READY": str(ready), "HOWR_TEST_PROCEED": str(proceed)}
        barrier = '_howr_move() { /bin/mv "$@"; if [[ "$2" == */previous.app ]]; then touch "$HOWR_TEST_READY"; while [[ ! -e "$HOWR_TEST_PROCEED" ]]; do /bin/sleep 0.02; done; fi; };'
        first = subprocess.Popen(self.command(barrier), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and first.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            second = subprocess.run(self.command(), capture_output=True, timeout=3)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn(b"Another install", second.stderr)
            proceed.touch()
            _, stderr = first.communicate(timeout=3)
            self.assertEqual(first.returncode, 0, stderr)
            self.assertTrue((self.target / "new").is_file())
            self.assertFalse((self.target / "Howr.app").exists())
        finally:
            if first.poll() is None:
                first.kill()
                first.communicate()


if __name__ == "__main__":
    unittest.main()
