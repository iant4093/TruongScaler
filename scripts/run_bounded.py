#!/usr/bin/env python3
"""Run one development command with a Darwin process-tree footprint limit."""
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

SAMPLE_INTERVAL_SECONDS = 2
TERMINATION_GRACE_SECONDS = 3


def sample_tree(pid, elapsed):
    listing = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    parents = {int(a): int(b) for a, b in (line.split() for line in listing.splitlines())}
    descendants = {pid}
    while True:
        expanded = descendants | {child for child, parent in parents.items() if parent in descendants}
        if expanded == descendants:
            break
        descendants = expanded
    # Darwin top MEM includes compression; RSS alone is not a safe bound.
    top = subprocess.check_output(["top", "-l", "1", "-stats", "pid,command,mem,cmprs"], text=True)
    footprints = []
    for line in top.splitlines():
        match = re.match(r"\s*(\d+)\s+\S+\s+(\d+(?:\.\d+)?)([KMG])\b", line)
        if match and int(match[1]) in descendants:
            mib = float(match[2]) * {"K": 1 / 1024, "M": 1, "G": 1024}[match[3]]
            footprints.append({"pid": int(match[1]), "footprintMiB": mib})
    return {"elapsedSeconds": elapsed, "treeFootprintMiB": sum(item["footprintMiB"] for item in footprints),
            "processes": footprints}


def signal_owned_group(process, signum):
    # Popen created this session. Never signal after wait/poll has reaped its
    # leader: retaining that child (even as a zombie) prevents PID/PGID reuse.
    if process.returncode is not None:
        return False
    try:
        # Darwin can stop reporting getsid/getpgid for a zombie leader while
        # its resistant grandchildren still run. Popen created this session and
        # the leader has not been reaped, so its pinned ID cannot belong to a
        # different session. Signal that owned group directly.
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        return False
    return True


def group_has_live_members(pgid):
    listing = subprocess.check_output(["ps", "-axo", "pid=,pgid=,stat="], text=True)
    for line in listing.splitlines():
        _pid, group, state = line.split(maxsplit=2)
        if int(group) == pgid and not state.startswith("Z"):
            return True
    return False


def terminate_owned_group(process, signum):
    if not signal_owned_group(process, signum):
        return False
    deadline = time.monotonic() + TERMINATION_GRACE_SECONDS
    # Do not poll/wait here. The unreaped session leader pins the owned PGID
    # until every group member has stopped, including resistant grandchildren.
    while time.monotonic() < deadline:
        try:
            if not group_has_live_members(process.pid):
                return False
        except (OSError, subprocess.SubprocessError, ValueError):
            # Failure to inspect the group cannot justify abandoning it. Its
            # unreaped leader still pins ownership, so escalation remains safe.
            break
        time.sleep(0.05)
    return signal_owned_group(process, signal.SIGKILL)


def write_result(directory, label, result):
    target = directory / (label + ".json")
    temporary = directory / (label + ".json.tmp")
    with temporary.open("w") as output:
        output.write(json.dumps(result, indent=2) + "\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, target)
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main():
    if len(sys.argv) < 4 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", sys.argv[1]):
        raise SystemExit("usage: run_bounded.py LABEL LIMIT_MIB COMMAND [ARGS...]")
    label, limit, args = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
    if not math.isfinite(limit) or limit <= 0:
        raise SystemExit("LIMIT_MIB must be finite and positive")
    directory = Path(os.environ.get("TRUONGSCALER_LOG_DIR", Path(__file__).resolve().parents[1] / "build/logs"))
    directory.mkdir(parents=True, exist_ok=True)
    start, samples, aborted = time.monotonic(), [], False
    interruption = None

    def interrupted(signum, _frame):
        nonlocal interruption
        # Preserve the first cancellation reason; repeated CI signals must not
        # interrupt cleanup or redirect it to any other process.
        if interruption is None:
            interruption = signum

    handlers = {signum: signal.signal(signum, interrupted) for signum in (signal.SIGINT, signal.SIGTERM)}
    process = None
    escalated = False
    try:
        with (directory / (label + ".log")).open("w") as output:
            if interruption is None:
                process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            next_sample = start + SAMPLE_INTERVAL_SECONDS
            while process is not None:
                if interruption is not None:
                    output.write(f"\nRESOURCE_GUARD_INTERRUPTED: signal {interruption}\n")
                    output.flush()
                    escalated = terminate_owned_group(process, interruption)
                    break
                if process.poll() is not None:
                    break
                if time.monotonic() >= next_sample:
                    sample = sample_tree(process.pid, time.monotonic() - start)
                    samples.append(sample)
                    next_sample = time.monotonic() + SAMPLE_INTERVAL_SECONDS
                    if sample["treeFootprintMiB"] > limit:
                        aborted = True
                        output.write("\nRESOURCE_GUARD_ABORT: command-tree footprint exceeded limit\n")
                        output.flush()
                        escalated = terminate_owned_group(process, signal.SIGTERM)
                        break
                time.sleep(0.1)
            code = process.wait() if process is not None else None
        exit_code = 128 + interruption if interruption is not None else 124 if aborted else code
        result = {"label": label, "args": args, "actualExitCode": code,
                  "exitCode": exit_code, "resourceGuardAborted": aborted,
                  "interrupted": interruption is not None, "interruptionSignal": interruption,
                  "terminationEscalated": escalated,
                  "limitMiB": limit, "elapsedSeconds": time.monotonic() - start,
                  "peakCommandTreeMiB": max((item["treeFootprintMiB"] for item in samples), default=0),
                  "samples": samples}
        write_result(directory, label, result)
        print(json.dumps({key: value for key, value in result.items() if key != "samples"}))
        return result["exitCode"]
    finally:
        # Sampling/spawn errors must not abandon a command either. No reaping
        # occurs inside termination, so group ownership remains pinned there.
        if process is not None and process.returncode is None:
            terminate_owned_group(process, signal.SIGTERM)
            process.wait()
        for signum, handler in handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(main())
