import base64
import contextlib
import datetime as dt
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / 'instance/idle_check.py'
NOW = 1793016000
PASSWORD = 'idle-admin-password-acceptance'
AWS = ['aws', 'autoscaling', 'set-desired-capacity', '--auto-scaling-group-name',
       'sonarqube', '--desired-capacity', '0', '--no-honor-cooldown', '--region', 'us-east-1']


def log_line(age, login='owner', agent='scanner', request='GET /api/system/status HTTP/1.1'):
    timestamp = dt.datetime.fromtimestamp(NOW - age, dt.timezone.utc).strftime('%d/%b/%Y:%H:%M:%S +0000')
    return f'127.0.0.1 - {login} [{timestamp}] "{request}" 200 2 "{agent}"\n'


@contextlib.contextmanager
def ce_server(mode):
    calls = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            calls.append((self.path, self.headers.get('Authorization'), self.headers.get('User-Agent')))
            if mode == 'timeout':
                time.sleep(0.3)
            payload = {'pending': 1 if mode == 'pending' else 0,
                       'inProgress': 1 if mode == 'inProgress' else 0}
            self.send_response(503 if mode == 'error' else 200)
            self.end_headers()
            try:
                self.wfile.write(json.dumps(payload).encode())
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}/api/ce/activity_status'
    if mode == 'refused':
        server.shutdown()
        server.server_close()
    try:
        yield url, calls
    finally:
        if mode != 'refused':
            server.shutdown()
            server.server_close()
        thread.join(timeout=1)


class IdleAcceptance(unittest.TestCase):
    def setUp(self):
        self.assertTrue(CHECKER.is_file(), 'implementation missing: instance/idle_check.py')
        self.temp = tempfile.TemporaryDirectory(prefix='sonarqube-idle-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.records = self.directory / 'commands.jsonl'
        self.log = self.directory / 'access.log'
        self.uptime = self.directory / 'uptime'
        self.password = self.directory / 'password'
        self.password.write_text(PASSWORD)
        bindir = self.directory / 'bin'
        bindir.mkdir()
        stub = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['RECORDS'], 'a') as record:
    record.write(json.dumps([os.path.basename(sys.argv[0]), *sys.argv[1:]]) + '\\n')
sys.exit(int(os.environ.get('AWS_EXIT', '0')) if os.path.basename(sys.argv[0]) == 'aws' else 97)
'''
        for name in ('aws', 'systemctl', 'docker'):
            path = bindir / name
            path.write_text(stub)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{bindir}:{os.environ["PATH"]}', RECORDS=str(self.records),
                        SONAR_ACCESS_LOG=str(self.log), SONAR_UPTIME_FILE=str(self.uptime),
                        SONAR_ADMIN_PASSWORD_FILE=str(self.password), SONAR_NOW_EPOCH=str(NOW),
                        SONAR_CE_TIMEOUT_SECONDS='0.1')

    def commands(self):
        return [json.loads(line) for line in self.records.read_text().splitlines()] if self.records.exists() else []

    def run_checker(self, lines='', uptime=3600, ce='idle', aws_exit=0):
        self.log.write_text(lines)
        self.uptime.write_text(f'{uptime}.00 0.00\n')
        with ce_server(ce) as (url, calls):
            result = subprocess.run(['python3', str(CHECKER)], cwd=ROOT,
                                    env=dict(self.env, SONAR_CE_URL=url, AWS_EXIT=str(aws_exit)),
                                    capture_output=True, text=True, timeout=2)
        for path, auth, agent in calls:
            self.assertEqual(path, '/api/ce/activity_status')
            self.assertEqual(auth, 'Basic ' + base64.b64encode(f'admin:{PASSWORD}'.encode()).decode())
            self.assertEqual(agent, 'sonarqube-idle-check')
        return result

    def test_C1_C6_recent_authenticated_activity(self):
        for age in (0, 60, 1799):
            with self.subTest(age=age):
                result = self.run_checker(log_line(age))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.commands(), [])

    def test_C1_C6_activity_before_noise_still_counts(self):
        lines = log_line(120) + log_line(1, '-') + log_line(2, 'admin', 'sonarqube-idle-check')
        result = self.run_checker(lines)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [])

    def test_C2_C5_idle_ignores_unauthenticated_self_and_old_lines(self):
        lines = log_line(1801) + log_line(1, '-') + log_line(5, 'admin', 'sonarqube-idle-check')
        result = self.run_checker(lines, uptime=1800)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [AWS])

    def test_C2_C5_empty_log_is_idle(self):
        result = self.run_checker('')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [AWS])

    def test_C1_C6_activity_is_authentication_field_not_header_or_url(self):
        lines = log_line(1, '-', 'owner', 'GET /?LOGIN=owner HTTP/1.1')
        result = self.run_checker(lines)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [AWS])

    def test_C3_C6_pending_and_running_ce_are_busy(self):
        for mode in ('pending', 'inProgress'):
            with self.subTest(ce=mode):
                result = self.run_checker(log_line(2000), ce=mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.commands(), [])

    def test_C4_C6_uptime_gate(self):
        for lines in ('', log_line(1), log_line(2000)):
            with self.subTest(log=lines):
                result = self.run_checker(lines, uptime=1799)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.commands(), [])

    def test_C7_failed_scale_in_retries_and_stops_nothing(self):
        for _ in range(2):
            result = self.run_checker(log_line(2000), aws_exit=23)
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [AWS, AWS])

    def test_C8_C5_failed_ce_counts_as_not_busy(self):
        for mode in ('refused', 'timeout', 'error'):
            with self.subTest(ce=mode):
                self.records.unlink(missing_ok=True)
                result = self.run_checker(log_line(2000), ce=mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.commands(), [AWS])


if __name__ == '__main__':
    unittest.main()
