from http import client
import json
import os
import urllib.parse
from pathlib import Path

repo = os.environ['REPO']
token = os.environ['GITHUB_TOKEN']
owner, repo_name = repo.split('/')

def request(path, params=None):
    conn = client.HTTPSConnection('api.github.com')
    headers = {
        'Authorization': f'Bearer {token}',
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'github-actions-hosts-export'
    }
    query = ''
    if params:
        query = '?' + urllib.parse.urlencode(params)
    conn.request('GET', f'/repos/{owner}/{repo_name}{path}{query}', headers=headers)
    resp = conn.getresponse()
    if resp.status >= 400:
        raise SystemExit(f'HTTP {resp.status}: {resp.read().decode()}')
    payload = json.loads(resp.read())
    link = resp.getheader('Link') or ''
    conn.close()
    return payload, link

def has_next(link_header):
    if not link_header:
        return False
    for part in link_header.split(','):
        if 'rel="next"' in part:
            return True
    return False

page = 1
runners = []
while True:
    payload, link = request('/actions/runners', params={'per_page': 100, 'page': page})
    runners.extend(payload.get('runners', []))
    if not has_next(link):
        break
    page += 1

lines = ['runners:']
for runner in runners:
    labels = runner.get('labels', [])
    label_names = ','.join(sorted(lbl.get('name', '') for lbl in labels))
    lines.append(f"  - name: {runner.get('name')}")
    lines.append(f"    os: {runner.get('os')}")
    lines.append(f"    status: {runner.get('status')}")
    lines.append(f"    busy: {runner.get('busy')}")
    lines.append(f"    labels: {label_names}")
    lines.append('')

Path('.github/data/runtime-runners.yml').write_text('\n'.join(lines) + '\n')
