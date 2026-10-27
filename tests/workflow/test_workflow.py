import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASE = 'https://sonar.sebastiansuarez.dev'
YAML = "puts JSON.generate(YAML.safe_load(STDIN.read, aliases: true))"


def load(path):
    result = subprocess.run(['ruby', '-ryaml', '-rjson', '-e', YAML], input=path.read_text(),
                            text=True, capture_output=True, timeout=2, check=True)
    value = json.loads(result.stdout)
    if 'true' in value and 'on' not in value:
        value['on'] = value.pop('true')
    return value


def expression(value):
    return re.sub(r'\s+', '', str(value)).removeprefix('${{').removesuffix('}}')


class WorkflowAcceptance(unittest.TestCase):
    def setUp(self):
        self.path = ROOT / '.github/workflows/sonarqube-scan.yml'
        self.caller_path = ROOT / 'docs/caller-workflow.yml'
        self.assertTrue(self.path.is_file(), 'implementation missing: .github/workflows/sonarqube-scan.yml')
        self.assertTrue(self.caller_path.is_file(), 'implementation missing: docs/caller-workflow.yml')
        self.workflow = load(self.path)
        self.caller = load(self.caller_path)

    def job(self):
        self.assertIn('scan', self.workflow['jobs'])
        return self.workflow['jobs']['scan']

    def step(self, name):
        steps = self.job()['steps']
        found = [(index, step) for index, step in enumerate(steps) if step.get('id') == name]
        self.assertEqual(len(found), 1, f'exactly one step id={name}')
        return found[0]

    def test_E2_workflow_call_interface_and_project_key(self):
        trigger = self.workflow['on']['workflow_call']
        for name in ('SONAR_TOKEN', 'SONAR_WAKE_KEY'):
            self.assertIs(trigger['secrets'][name]['required'], True)
        project = trigger['inputs']['project-key']
        self.assertEqual(project['type'], 'string')
        self.assertFalse(project.get('required', False))
        self.assertEqual(project.get('default', ''), '')
        _, scan = self.step('scan')
        args = scan['with']['args']
        self.assertIn('-Dsonar.projectKey=${{inputs.project-key||github.event.repository.name}}',
                      re.sub(r'\s+', '', args))

    def test_E3_only_default_branch_scans(self):
        self.assertEqual(expression(self.job()['if']), "github.ref==format('refs/heads/{0}',github.event.repository.default_branch)")

    def test_E4_full_checkout_and_sha_pins(self):
        checkout = [step for step in self.job()['steps'] if step.get('uses', '').startswith('actions/checkout@')]
        self.assertEqual(len(checkout), 1)
        self.assertEqual(str(checkout[0]['with']['fetch-depth']), '0')

        def walk(value):
            if isinstance(value, dict):
                for key, child in value.items():
                    if key == 'uses':
                        self.assertRegex(child, r'^[^@]+@[a-fA-F0-9]{40}$')
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)
        walk(self.workflow)

    def test_E5_bounded_wake_before_scan(self):
        wake_index, wake = self.step('wake')
        scan_index, scan = self.step('scan')
        self.assertLess(wake_index, scan_index)
        self.assertGreater(float(wake['timeout-minutes']), 0)
        self.assertLessEqual(float(wake['timeout-minutes']), 15)
        self.assertFalse(wake.get('continue-on-error', False))
        script = wake['run']
        self.assertIn(BASE + '/api/system/status', script)
        self.assertIn('X-Sonar-Wake-Key', script)
        self.assertIn('SONAR_WAKE_KEY', script)
        self.assertEqual(expression(wake['env']['SONAR_WAKE_KEY']), 'secrets.SONAR_WAKE_KEY')
        self.assertRegex(script, r'\b(while|until|for)\b')
        self.assertRegex(script, r'\bUP\b')
        self.assertIn('curl', script)
        self.assertIn('sleep', script)
        self.assertRegex(scan['uses'], r'^SonarSource/sonarqube-scan-action@[a-fA-F0-9]{40}$')
        self.assertEqual(scan['env']['SONAR_HOST_URL'], BASE)
        self.assertEqual(expression(scan['env']['SONAR_TOKEN']), 'secrets.SONAR_TOKEN')

    def test_E6_caller_triggers_and_secret_mapping(self):
        trigger = self.caller['on']
        self.assertIn('workflow_dispatch', trigger)
        self.assertEqual(trigger['push']['branches'], ['main'])
        jobs = list(self.caller['jobs'].values())
        calls = [job for job in jobs if job.get('uses') == 'sebastian-suarez/sonarqube/.github/workflows/sonarqube-scan.yml@main']
        self.assertEqual(len(calls), 1)
        for name in ('SONAR_TOKEN', 'SONAR_WAKE_KEY'):
            self.assertEqual(expression(calls[0]['secrets'][name]), 'secrets.' + name)

    def test_E7_background_heartbeat_between_wake_and_scan(self):
        wake_index, _ = self.step('wake')
        heartbeat_index, heartbeat = self.step('heartbeat')
        scan_index, _ = self.step('scan')
        self.assertLess(wake_index, heartbeat_index)
        self.assertLess(heartbeat_index, scan_index)
        script = heartbeat['run']
        self.assertIn(BASE + '/api/users/current', script)
        self.assertIn('Authorization: Bearer', script)
        self.assertIn('SONAR_TOKEN', script)
        self.assertRegex(script, r'-K\s+-')
        self.assertRegex(script, r'(?m)&\s*(?:#.*)?$')
        self.assertEqual(expression(heartbeat['env']['SONAR_TOKEN']), 'secrets.SONAR_TOKEN')
        interval = float(heartbeat.get('env', {}).get('SONAR_HEARTBEAT_SECONDS', 300))
        self.assertGreater(interval, 0)
        self.assertLessEqual(interval, 300)
        self.assertRegex(script, r'sleep\s+(?:["\x27]?\$\{?SONAR_HEARTBEAT_SECONDS|(?:[1-9]\d?|[12]\d\d|300)\b)')
        for job in self.workflow['jobs'].values():
            for step in job.get('steps', []):
                self.assertNotRegex(step.get('run', ''), r'\$\{\{\s*secrets\.')


if __name__ == '__main__':
    unittest.main()
