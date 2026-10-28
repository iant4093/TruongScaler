"""Low-CPU process-supervision regressions; all spawned processes are test-owned."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "scripts/run_bounded.py"
TREE_SCRIPT = r'''
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

resistant = sys.argv[2] == "resistant"
worker = "import time; time.sleep(300)"
if resistant:
    worker = "import signal,time; signal.signal(signal.SIGINT, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"
grandchild = subprocess.Popen([sys.executable, "-c", worker])
def stop(signum, _frame):
    if not resistant:
        grandchild.wait(timeout=2)
    # In the resistant case the leader exits immediately, leaving the guard
    # responsible for the grandchild after the session leader becomes a zombie.
    raise SystemExit(128 + signum)
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)
# Grandchild must have installed its handlers before the test sends a signal.
time.sleep(0.15)
Path(sys.argv[1]).write_text(json.dumps({"child": os.getpid(), "grandchild": grandchild.pid}))
while True:
    time.sleep(300)
'''


def live(pid):
    status = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    # A terminated orphan can briefly await the OS reaper; it cannot execute.
    return status.returncode == 0 and bool(status.stdout.strip()) and not status.stdout.strip().startswith("Z")


class RunBoundedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="truongscaler-supervisor-")
        self.directory = Path(self.temporary.name)
        self.env = os.environ.copy()
        self.env["TRUONGSCALER_LOG_DIR"] = str(self.directory)
        self.processes = []
        self.tree_pids = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        # Failure cleanup refers only to PIDs created and recorded by this test.
        for pid in self.tree_pids:
            if live(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.temporary.cleanup()

    def launch(self, label, *args):
        process = subprocess.Popen([sys.executable, str(GUARD), label, "8192", *args],
                                   env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.processes.append(process)
        return process

    def wait_for(self, predicate, explanation, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.025)
        self.fail(explanation)

    def test_normal_exit_status_propagates(self):
        for code in (0, 23):
            with self.subTest(code=code):
                label = "exit-" + str(code)
                guard = self.launch(label, sys.executable, "-c", f"raise SystemExit({code})")
                _output, errors = guard.communicate(timeout=8)
                self.assertEqual(guard.returncode, code, errors)
                report = json.loads((self.directory / (label + ".json")).read_text())
                self.assertEqual(report["exitCode"], code)
                self.assertEqual(report["actualExitCode"], code)
                self.assertFalse(report["interrupted"])
                self.assertFalse(report["resourceGuardAborted"])
                self.assertEqual(report["limitMiB"], 8192)

    def cancel_tree(self, signum, resistant=False):
        label = "signal-" + str(signum) + ("-resistant" if resistant else "")
        marker = self.directory / (label + "-pids.json")
        sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"], start_new_session=True)
        self.processes.append(sentinel)
        guard = self.launch(label, sys.executable, "-c", TREE_SCRIPT, str(marker),
                            "resistant" if resistant else "graceful")
        self.wait_for(marker.exists, "Owned child/grandchild did not become ready")
        pids = json.loads(marker.read_text())
        self.tree_pids.extend(pids.values())
        self.assertTrue(all(live(pid) for pid in pids.values()))
        guard.send_signal(signum)
        _output, errors = guard.communicate(timeout=8)
        self.assertEqual(guard.returncode, 128 + signum, errors)
        self.wait_for(lambda: not any(live(pid) for pid in pids.values()), "Guard abandoned a live owned process")
        self.assertIsNone(sentinel.poll(), "Guard signalled an unrelated test-owned process")
        report = json.loads((self.directory / (label + ".json")).read_text())
        self.assertEqual(report["exitCode"], 128 + signum)
        self.assertTrue(report["interrupted"])
        self.assertEqual(report["interruptionSignal"], signum)
        self.assertEqual(report["terminationEscalated"], resistant)
        self.assertFalse(report["resourceGuardAborted"])
        self.assertIsInstance(report["actualExitCode"], int)
        self.assertFalse((self.directory / (label + ".json.tmp")).exists())

    def test_sigterm_cleans_owned_child_and_grandchild(self):
        self.cancel_tree(signal.SIGTERM)

    def test_sigint_cleans_owned_child_and_grandchild(self):
        self.cancel_tree(signal.SIGINT)

    def test_sigterm_escalates_for_resistant_owned_grandchild(self):
        self.cancel_tree(signal.SIGTERM, resistant=True)


if __name__ == "__main__":
    unittest.main()
