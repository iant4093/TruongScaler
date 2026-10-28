#!/usr/bin/env python3
"""Run one development command with a Darwin process-tree footprint limit."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def main():
    if len(sys.argv) < 4 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", sys.argv[1]):
        raise SystemExit("usage: run_bounded.py LABEL LIMIT_MIB COMMAND [ARGS...]")
    label, limit, args = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
    if limit <= 0:
        raise SystemExit("LIMIT_MIB must be positive")
    directory = Path(os.environ.get("TRUONGSCALER_LOG_DIR", Path(__file__).resolve().parents[1] / "build/logs"))
    directory.mkdir(parents=True, exist_ok=True)
    start, samples, aborted = time.monotonic(), [], False
    with (directory / (label + ".log")).open("w") as output:
        process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        while process.poll() is None:
            time.sleep(2)
            if process.poll() is not None:
                break
            listing = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
            parents = {int(a): int(b) for a, b in (line.split() for line in listing.splitlines())}
            descendants = {process.pid}
            while True:
                expanded = descendants | {pid for pid, parent in parents.items() if parent in descendants}
                if expanded == descendants:
                    break
                descendants = expanded
            # top MEM includes compression; RSS alone is not a safe bound.
            top = subprocess.check_output(["top", "-l", "1", "-stats", "pid,command,mem,cmprs"], text=True)
            footprints = []
            for line in top.splitlines():
                match = re.match(r"\s*(\d+)\s+\S+\s+(\d+(?:\.\d+)?)([KMG])\b", line)
                if match and int(match[1]) in descendants:
                    mib = float(match[2]) * {"K": 1 / 1024, "M": 1, "G": 1024}[match[3]]
                    footprints.append({"pid": int(match[1]), "footprintMiB": mib})
            total = sum(item["footprintMiB"] for item in footprints)
            samples.append({"elapsedSeconds": time.monotonic() - start, "treeFootprintMiB": total, "processes": footprints})
            if total > limit and process.poll() is None:
                aborted = True
                output.write("\nRESOURCE_GUARD_ABORT: command-tree footprint exceeded limit\n")
                output.flush()
                # Only this command's fresh session; no unrelated app/service or recorded PID.
                os.killpg(process.pid, signal.SIGTERM)
                break
        try:
            code = process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait()
    result = {"label": label, "args": args, "actualExitCode": code,
              "exitCode": 124 if aborted else code, "resourceGuardAborted": aborted,
              "limitMiB": limit, "elapsedSeconds": time.monotonic() - start,
              "peakCommandTreeMiB": max((item["treeFootprintMiB"] for item in samples), default=0),
              "samples": samples}
    (directory / (label + ".json")).write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "samples"}))
    return result["exitCode"]


if __name__ == "__main__":
    sys.exit(main())
