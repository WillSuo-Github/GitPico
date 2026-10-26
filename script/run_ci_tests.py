#!/usr/bin/env python3
"""Run native CI tests and preserve stacks if Swift Testing stops progressing."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main(architecture):
    output = Path('.build/ci')
    output.mkdir(parents=True, exist_ok=True)
    log = output / 'xcodebuild.log'
    command = ['xcodebuild', 'test', '-project', 'GitPico.xcodeproj', '-scheme', 'GitPico',
               '-derivedDataPath', '.build/ci-derived', '-destination', 'platform=macOS,arch=' + architecture,
               '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
               '-default-test-execution-time-allowance', '120', '-maximum-test-execution-time-allowance', '180',
               '-resultBundlePath', str(output / 'Tests.xcresult')]
    with log.open('wb') as stream, log.open('r', errors='replace') as reader:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        started = False
        last_progress = time.monotonic()
        last_event = ''
        while process.poll() is None:
            for line in reader.readlines():
                if '◇ Test ' in line or '✔ Test ' in line or '✘ Test ' in line:
                    started = True
                    last_progress = time.monotonic()
                    last_event = line.strip()
            if started and time.monotonic() - last_progress > 180:
                (output / 'hung-test.txt').write_text('No test progress for 180 seconds.\n' + last_event + '\n')
                pids = subprocess.run(['pgrep', '-x', 'GitPico'], capture_output=True, text=True).stdout.split()
                for pid in pids:
                    with (output / ('hung-GitPico-' + pid + '.txt')).open('w') as sample:
                        try:
                            subprocess.run(['sample', pid, '5'], stdout=sample, stderr=subprocess.STDOUT, timeout=15)
                        except subprocess.TimeoutExpired:
                            sample.write('\nStack sampling timed out.\n')
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                return 124
            time.sleep(5)
        return process.returncode


if __name__ == '__main__':
    if len(sys.argv) != 2 or sys.argv[1] not in ('arm64', 'x86_64'):
        raise SystemExit('Usage: script/run_ci_tests.py arm64|x86_64')
    raise SystemExit(main(sys.argv[1]))
