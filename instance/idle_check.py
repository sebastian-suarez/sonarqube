import base64
import datetime
import json
import os
import subprocess
import sys
import time
import urllib.request

WINDOW = 1800
SCALE_IN = ['aws', 'autoscaling', 'set-desired-capacity', '--auto-scaling-group-name', 'sonarqube',
            '--desired-capacity', '0', '--no-honor-cooldown', '--region', 'us-east-1']


def is_activity(line, now):
    try:
        _, _, login, rest = line.split(' ', 3)
        stamp = datetime.datetime.strptime(rest[1:rest.index(']')], '%d/%b/%Y:%H:%M:%S %z').timestamp()
    except ValueError:
        return False
    return login != '-' and not line.rstrip().endswith(' "sonarqube-idle-check"') and now - stamp < WINDOW


def recently_active(now):
    try:
        with open(os.environ.get('SONAR_ACCESS_LOG', '/var/log/sonarqube/access.log'), errors='replace') as log:
            return any(is_activity(line, now) for line in log)
    except OSError:
        return False


def ce_busy():
    try:
        with open(os.environ.get('SONAR_ADMIN_PASSWORD_FILE', '/run/sonarqube/admin-password')) as file:
            credentials = base64.b64encode(('admin:' + file.read().rstrip('\n')).encode()).decode()
        request = urllib.request.Request(
            os.environ.get('SONAR_CE_URL', 'http://localhost:9000/api/ce/activity_status'),
            headers={'Authorization': 'Basic ' + credentials, 'User-Agent': 'sonarqube-idle-check'})
        with urllib.request.urlopen(request, timeout=float(os.environ.get('SONAR_CE_TIMEOUT_SECONDS', '5'))) as response:
            activity = json.load(response)
            return response.status == 200 and (activity['pending'] > 0 or activity['inProgress'] > 0)
    except Exception:
        return False


def main():
    now = float(os.environ.get('SONAR_NOW_EPOCH', time.time()))
    with open(os.environ.get('SONAR_UPTIME_FILE', '/proc/uptime')) as file:
        uptime = float(file.read().split()[0])
    if uptime < WINDOW or recently_active(now) or ce_busy():
        return 0
    return subprocess.call(SCALE_IN)


sys.exit(main())
