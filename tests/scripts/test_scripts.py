import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASE = 'https://sonar.sebastiansuarez.dev'
TOKEN = 'acceptance-analysis-token-SECRET'
WAKE = 'acceptance-current-wake-key-SECRET'
STALE = 'acceptance-stale-wake-key-SECRET'
ADMIN = 'acceptance-admin-password-SECRET'
GENERATED = 'acceptance-generated-token-SECRET'
SECRETS = (TOKEN, WAKE, STALE, ADMIN, GENERATED)
STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, re, shlex, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
statepath = pathlib.Path(os.environ['STUB_STATE'])
state = json.loads(statepath.read_text())
stdin = sys.stdin.read() if (name == 'curl' and '-K' in args and args[args.index('-K')+1] == '-') or (name == 'security' and '-i' in args) or (name == 'gh' and args[:2] == ['secret', 'set']) else ''
record = dict(command=name, argv=args, stdin=stdin, pid=os.getpid(), ppid=os.getppid(), time=time.monotonic(), env={k: os.environ[k] for k in ['SONAR_TOKEN', 'SONAR_HOST_URL'] if k in os.environ})
with open(os.environ['STUB_RECORDS'], 'a') as stream:
    stream.write(json.dumps(record) + '\n')
def save():
    statepath.write_text(json.dumps(state))
def option(flag, default=None):
    return args[args.index(flag)+1] if flag in args else default
if name == 'git':
    joined = ' '.join(args)
    if 'commit' in args or 'push' in args:
        sys.exit(92)
    if args[:1] == ['status']:
        print(state['dirty'])
    elif args[:1] == ['diff']:
        sys.exit(1 if state['dirty'] else 0)
    elif args[:1] == ['ls-files']:
        print('new.txt' if state['dirty'].startswith('??') else '')
    elif '--show-toplevel' in args:
        print(state['repo'])
    elif '--is-inside-work-tree' in args:
        print('true')
    elif 'refs/remotes/origin/HEAD' in args:
        if not state['origin_head']:
            sys.exit(1)
        print(('origin/' if '--short' in args else 'refs/remotes/origin/') + state['origin_head'])
    elif args[:2] == ['branch', '--show-current'] or '--abbrev-ref' in args or (args[:1] == ['symbolic-ref'] and 'HEAD' in args):
        print(state['branch'])
    elif 'remote.origin.url' in args or args[:2] == ['remote', 'get-url']:
        if not state['origin']:
            sys.exit(2)
        print(state['origin'])
    elif 'init.defaultBranch' in args:
        if not state['default_branch']:
            sys.exit(1)
        print(state['default_branch'])
    else:
        sys.exit(91)
elif name == 'security':
    if args[:1] == ['find-generic-password']:
        if option('-a') != os.environ['USER'] or '-w' not in args:
            sys.exit(93)
        value = state['keychain'].get(option('-s'))
        if value is None:
            sys.exit(44)
        print(value)
    elif args == ['-i']:
        for line in stdin.splitlines():
            words = shlex.split(line)
            if not words or words == ['quit']:
                continue
            if words[0] != 'add-generic-password' or '-U' not in words or words[words.index('-a')+1] != os.environ['USER']:
                sys.exit(93)
            state['keychain'][words[words.index('-s')+1]] = words[words.index('-w')+1]
        save()
    else:
        sys.exit(93)
elif name == 'aws':
    if args[:2] != ['ssm', 'get-parameter'] or '--with-decryption' not in args:
        sys.exit(94)
    value = {'/sonarqube/wake-key': os.environ['TEST_WAKE'], '/sonarqube/admin-password': os.environ['TEST_ADMIN']}.get(option('--name'))
    if value is None:
        sys.exit(94)
    print(value if option('--output') == 'text' and option('--query') == 'Parameter.Value' else json.dumps({'Parameter': {'Value': value}}))
elif name == 'gh':
    if args[:2] != ['secret', 'set']:
        sys.exit(95)
elif name == 'docker':
    time.sleep(float(os.environ.get('SCANNER_SECONDS', '0.15')))
    sys.exit(int(os.environ.get('SCANNER_EXIT', '0')))
elif name == 'curl':
    material = '\n'.join(args) + '\n' + stdin
    urlmatch = re.search(r'https://sonar\.sebastiansuarez\.dev/[^\s"\x27]*', material)
    if not urlmatch:
        sys.exit(96)
    url = urlmatch.group(0)
    record['url'] = url
    status = 200
    if '/api/system/status' in url:
        countpath = pathlib.Path(os.environ['POLL_COUNT'])
        count = int(countpath.read_text()) if countpath.exists() else 0
        countpath.write_text(str(count+1))
        states = json.loads(os.environ.get('POLL_STATES', '["503", "STARTING", "UP"]'))
        answer = states[min(count, len(states)-1)]
        status = 503 if answer == '503' else 200
        body = json.dumps({'status': 'WAKING' if answer == '503' else answer})
    elif '/api/users/current' in url:
        body = '{"isLoggedIn":true,"login":"owner"}'
    elif '/api/user_tokens/generate' in url:
        body = json.dumps({'token': os.environ['TEST_GENERATED']})
    else:
        sys.exit(96)
    output = option('-o', option('--output'))
    if output:
        pathlib.Path(output).write_text(body)
    else:
        sys.stdout.write(body)
    writeout = option('-w', option('--write-out', ''))
    sys.stdout.write(writeout.replace('%{http_code}', str(status)).replace('\\n', '\n'))
    if status >= 400 and any(arg in ('-f', '--fail', '--fail-with-body') or (arg.startswith('-') and not arg.startswith('--') and 'f' in arg[1:]) for arg in args):
        sys.exit(22)
else:
    sys.exit(90)
'''


class ScriptAcceptance(unittest.TestCase):
    def setUp(self):
        for name in ('wake.sh', 'scan.sh', 'onboard.sh'):
            self.assertTrue((ROOT / 'scripts' / name).is_file(), f'implementation missing: scripts/{name}')
        self.temp = tempfile.TemporaryDirectory(prefix='sonarqube-scripts-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.repo = self.directory / 'homeassistant'
        self.repo.mkdir()
        self.bindir = self.directory / 'bin'
        self.bindir.mkdir()
        for name in ('git', 'curl', 'docker', 'gh', 'security', 'aws'):
            path = self.bindir / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.records_path = self.directory / 'records.jsonl'
        self.state_path = self.directory / 'state.json'
        self.state_path.write_text(json.dumps(dict(repo=str(self.repo), branch='main', origin_head='main',
                                                  default_branch='', origin='git@github.com:sebastian-suarez/Blue-Glass.git', dirty='',
                                                  keychain={'sonarqube-analysis-token': TOKEN, 'sonarqube-wake-key': WAKE})))
        self.env = dict(os.environ, PATH=f'{self.bindir}:{os.environ["PATH"]}', USER='acceptance-user',
                        STUB_STATE=str(self.state_path), STUB_RECORDS=str(self.records_path),
                        POLL_COUNT=str(self.directory / 'poll-count'), TEST_WAKE=WAKE, TEST_ADMIN=ADMIN,
                        TEST_GENERATED=GENERATED, SONAR_WAIT_SECONDS='1', SONAR_POLL_SECONDS='0.02',
                        SONAR_HEARTBEAT_SECONDS='0.05', POLL_STATES='["UP"]')

    def state(self, **updates):
        state = json.loads(self.state_path.read_text())
        state.update(updates)
        self.state_path.write_text(json.dumps(state))
        return state

    def records(self, command=None):
        rows = [json.loads(line) for line in self.records_path.read_text().splitlines()] if self.records_path.exists() else []
        return [row for row in rows if command is None or row['command'] == command]

    def assert_D8(self):
        for row in self.records():
            argv = '\0'.join(row['argv'])
            for secret in SECRETS:
                self.assertNotIn(secret, argv, f'D8: {row["command"]} argv leaked a secret')
            if row['command'] == 'git':
                self.assertFalse({'commit', 'push'} & set(row['argv']))
            if row['command'] == 'gh':
                self.assertFalse({'pr', 'repo'} & set(row['argv']))

    def processes(self, group):
        try:
            os.killpg(group, 0)
        except ProcessLookupError:
            return []
        return [group]

    def run_script(self, name, *args, timeout=5, **environment):
        output = self.directory / f'{name}.out'
        error = self.directory / f'{name}.err'
        with output.open('w') as stdout, error.open('w') as stderr:
            process = subprocess.Popen(['bash', str(ROOT / 'scripts' / name), *args], cwd=self.repo,
                                       env=dict(self.env, **environment), stdout=stdout, stderr=stderr,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                self.fail(f'{name} exceeded {timeout}s: {error.read_text()}')
        survivors = self.processes(process.pid)
        if survivors:
            os.killpg(process.pid, signal.SIGKILL)
        self.assert_D8()
        return code, output.read_text() + error.read_text(), survivors

    def curls(self, suffix):
        return [row for row in self.records('curl') if suffix in '\n'.join(row['argv']) + '\n' + row['stdin']]

    def assert_scan(self, key):
        self.assertIn('wake.sh', (ROOT / 'scripts/scan.sh').read_text())
        rows = self.records('docker')
        self.assertEqual(len(rows), 1)
        row = rows[0]
        argv = row['argv']
        material = ' '.join(argv)
        self.assertIn('run', argv)
        self.assertRegex(material, r'sonarsource/sonar-scanner-cli:(?!latest(?:\s|$))[0-9][0-9A-Za-z._-]*(?:\s|$)')
        self.assertIn(f'-Dsonar.projectKey={key}', argv)
        self.assertTrue(any(str(self.repo) in value and value.endswith(':ro') for value in argv)
                        or any('readonly' in value and str(self.repo) in value for value in argv), 'repo must be mounted read-only')
        self.assertEqual(row['env'].get('SONAR_TOKEN'), TOKEN)
        self.assertTrue(any(flag in ('-e', '--env') and value == 'SONAR_TOKEN' for flag, value in zip(argv, argv[1:]))
                        or '--env=SONAR_TOKEN' in argv, 'docker must inherit token by name')
        self.assertTrue(f'SONAR_HOST_URL={BASE}' in argv or ('SONAR_HOST_URL' in argv and row['env'].get('SONAR_HOST_URL') == BASE))
        heartbeat = self.curls('/api/users/current')
        self.assertTrue(heartbeat, 'D4: heartbeat must start')
        for beat in heartbeat:
            self.assertIn('-K', beat['argv'])
            self.assertIn('Authorization: Bearer ' + TOKEN, beat['stdin'])

    def test_D2_D8_wake_reads_keychain_and_polls(self):
        code, output, survivors = self.run_script('wake.sh', POLL_STATES='["503", "STARTING", "UP"]', SONAR_WAIT_SECONDS='2')
        self.assertEqual(code, 0, output)
        self.assertEqual(survivors, [])
        polls = self.curls('/api/system/status')
        self.assertEqual(len(polls), 3)
        self.assertTrue(self.records('security'))
        for row in polls:
            self.assertIn('X-Sonar-Wake-Key: ' + WAKE, row['stdin'])
            self.assertIn('-K', row['argv'])

    def test_D2_D8_wake_has_bounded_timeout(self):
        code, output, survivors = self.run_script('wake.sh', POLL_STATES='["STARTING"]')
        self.assertNotEqual(code, 0, output)
        self.assertTrue(self.curls('/api/system/status'))
        self.assertEqual(survivors, [])

    def test_D3_D8_off_branch_is_rejected_before_network(self):
        self.state(branch='feature')
        code, output, _ = self.run_script('scan.sh')
        self.assertNotEqual(code, 0)
        self.assertRegex(output.lower(), r'branch|default')
        self.assertEqual(self.records('curl') + self.records('docker'), [])

    def test_D3_D8_tracked_changes_are_rejected_before_network(self):
        self.state(dirty=' M tracked.txt')
        code, output, _ = self.run_script('scan.sh')
        self.assertNotEqual(code, 0)
        self.assertRegex(output.lower(), r'clean|uncommitted|dirty|changes')
        self.assertEqual(self.records('curl') + self.records('docker'), [])

    def test_D3_D8_untracked_changes_are_rejected_before_network(self):
        self.state(dirty='?? new.txt')
        code, output, _ = self.run_script('scan.sh')
        self.assertNotEqual(code, 0)
        self.assertRegex(output.lower(), r'untracked|clean|dirty|changes')
        self.assertEqual(self.records('curl') + self.records('docker'), [])

    def test_D4_D5_D8_clean_scan_origin_project_key(self):
        self.state(default_branch='develop')
        code, output, survivors = self.run_script('scan.sh')
        self.assertEqual(code, 0, output)
        self.assertTrue(self.curls('/api/system/status'), 'scan must invoke wake.sh')
        self.assert_scan('Blue-Glass')
        self.assertEqual(survivors, [])

    def test_D4_D5_D8_no_origin_and_configured_default(self):
        self.state(origin='', origin_head='', default_branch='trunk', branch='trunk')
        code, output, survivors = self.run_script('scan.sh')
        self.assertEqual(code, 0, output)
        self.assert_scan('homeassistant')
        self.assertEqual(survivors, [])

    def test_D4_D5_D8_default_branch_falls_back_to_main(self):
        self.state(origin='', origin_head='', default_branch='', branch='main')
        code, output, survivors = self.run_script('scan.sh')
        self.assertEqual(code, 0, output)
        self.assert_scan('homeassistant')
        self.assertEqual(survivors, [])

    def test_D4_D8_wake_failure_prevents_scanner(self):
        code, output, survivors = self.run_script('scan.sh', POLL_STATES='["STARTING"]')
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.records('docker'), [])
        self.assertEqual(survivors, [])

    def assert_onboard(self, expected_token):
        rows = self.records()
        aws = self.records('aws')
        self.assertTrue(aws)
        self.assertEqual(aws[0]['argv'][:2], ['ssm', 'get-parameter'])
        self.assertIn(('--profile', 'sonarqube'), zip(aws[0]['argv'], aws[0]['argv'][1:]))
        self.assertIn('/sonarqube/wake-key', aws[0]['argv'])
        self.assertIn('--with-decryption', aws[0]['argv'])
        writes = [row for row in self.records('security') if row['argv'] == ['-i']]
        self.assertTrue(writes)
        self.assertIn(WAKE, writes[0]['stdin'])
        self.assertLess(rows.index(aws[0]), rows.index(writes[0]))
        secrets = self.records('gh')
        self.assertEqual(len(secrets), 2)
        for name, value in [('SONAR_TOKEN', expected_token), ('SONAR_WAKE_KEY', WAKE)]:
            matching = [row for row in secrets if row['argv'] == ['secret', 'set', name, '-R', 'owner/repo']]
            self.assertEqual(len(matching), 1)
            self.assertEqual(matching[0]['stdin'].rstrip('\n'), value)
            self.assertLess(rows.index(writes[0]), rows.index(matching[0]))
        self.assertEqual(json.loads(self.state_path.read_text())['keychain']['sonarqube-wake-key'], WAKE)

    def test_D6_D7_D8_onboarding_refreshes_stale_wake_key(self):
        self.assertTrue((ROOT / 'docs/caller-workflow.yml').is_file(), 'implementation missing: docs/caller-workflow.yml')
        self.state(keychain={'sonarqube-analysis-token': TOKEN, 'sonarqube-wake-key': STALE})
        code, output, survivors = self.run_script('onboard.sh', 'owner/repo')
        self.assertEqual(code, 0, output)
        self.assert_onboard(TOKEN)
        self.assertIn((ROOT / 'docs/caller-workflow.yml').read_text().strip(), output)
        self.assertEqual(survivors, [])

    def test_D7_D8_missing_token_is_created_after_wake(self):
        self.state(keychain={'sonarqube-wake-key': STALE})
        code, output, survivors = self.run_script('onboard.sh', 'owner/repo', SONAR_WAIT_SECONDS='2')
        self.assertEqual(code, 0, output)
        self.assert_onboard(GENERATED)
        aws = self.records('aws')
        self.assertEqual(len(aws), 2)
        self.assertIn(('--profile', 'sonarqube'), zip(aws[1]['argv'], aws[1]['argv'][1:]))
        self.assertIn('/sonarqube/admin-password', aws[1]['argv'])
        self.assertIn('--with-decryption', aws[1]['argv'])
        rows = self.records()
        polls = self.curls('/api/system/status')
        self.assertTrue(polls)
        writes = [row for row in self.records('security') if row['argv'] == ['-i']]
        self.assertLess(rows.index(writes[0]), rows.index(polls[0]))
        self.assertLess(rows.index(polls[-1]), rows.index(aws[1]))
        generated = self.curls('/api/user_tokens/generate')
        self.assertEqual(len(generated), 1)
        material = ' '.join(generated[0]['argv']) + '\n' + generated[0]['stdin']
        self.assertIn('GLOBAL_ANALYSIS_TOKEN', material)
        self.assertIn('admin:' + ADMIN, generated[0]['stdin'])
        self.assertRegex(material, r'POST|data|form')
        self.assertLess(rows.index(aws[1]), rows.index(generated[0]))
        token_writes = [row for row in writes if GENERATED in row['stdin']]
        self.assertEqual(len(token_writes), 1)
        self.assertLess(rows.index(generated[0]), rows.index(token_writes[0]))
        self.assertTrue(all(rows.index(token_writes[0]) < rows.index(row) for row in self.records('gh')))
        keychain = json.loads(self.state_path.read_text())['keychain']
        self.assertEqual(keychain['sonarqube-analysis-token'], GENERATED)
        self.assertEqual(survivors, [])

    def heartbeat_case(self, status):
        code, output, survivors = self.run_script('scan.sh', SONAR_HEARTBEAT_SECONDS='1',
                                                 SCANNER_SECONDS='3', SCANNER_EXIT=str(status))
        self.assertEqual(code, status, output)
        self.assert_scan('Blue-Glass')
        beats = self.curls('/api/users/current')
        self.assertGreaterEqual(len(beats), 2)
        self.assertGreaterEqual(beats[-1]['time'] - beats[0]['time'], 0.9)
        self.assertEqual(survivors, [], f'D9: heartbeat processes survived: {survivors}')
        count = len(self.records())
        time.sleep(0.15)
        self.assertEqual(len(self.records()), count)

    def test_D9_D8_heartbeat_success_cleanup(self):
        self.heartbeat_case(0)

    def test_D9_D8_heartbeat_failure_cleanup(self):
        self.heartbeat_case(17)


if __name__ == '__main__':
    unittest.main()
