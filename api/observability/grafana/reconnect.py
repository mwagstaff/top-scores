#!/usr/bin/env python3
"""Repair Top Scores Grafana on Sky without restarting application services.

Run with --apply to back up and repair, or without it to verify panel queries.
Uses the existing Mini Viewer credential; never prints credentials.
"""
import argparse
import base64
import datetime
import json
import os
from pathlib import Path
import time
import urllib.parse
import urllib.request


def migrate(value):
    if isinstance(value, str):
        for port, job in ((3011, 'app-top-scores'), (3013, 'app-top-scores-scraper'),
                          (3014, 'app-top-scores-monitor')):
            value = value.replace(f'job="top-scores",instance=~".*:{port}"', f'job="{job}"')
        return value.replace('job="top-scores"', 'job=~"app-top-scores(|-.*)"')
    if isinstance(value, list):
        return [migrate(v) for v in value]
    if isinstance(value, dict):
        return {k: migrate(v) for k, v in value.items()}
    return value


def panels(items):
    for panel in items:
        yield panel
        yield from panels(panel.get('panels', []))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    root = Path.home() / '.local/share/server-tooling-monitoring'
    password = (root / 'secrets/GRAFANA_PASSWORD').read_text().strip()
    headers = {
        'Authorization': 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode(),
        'Host': 'api.skynolimit.dev', 'X-Forwarded-Proto': 'https',
        'Content-Type': 'application/json',
    }

    def request(path, body=None, method=None):
        req = urllib.request.Request('http://127.0.0.1:3001/api' + path,
                                     json.dumps(body).encode() if body is not None else None,
                                     headers, method=method)
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.load(response)

    folder = 'top-scores-dashboards'
    dashboards = {d['uid']: request('/dashboards/uid/' + d['uid']) for d in
                  request('/search?type=dash-db&limit=1000') if d.get('folderUid') == folder}
    if not dashboards:
        raise RuntimeError('Top Scores folder contains no dashboards')
    uid = 'top-scores-prometheus'
    source = request('/datasources/uid/' + uid)
    if args.apply:
        token = (root / 'secrets/KIDSPLORERS_GRAFANA_READER').read_text().strip()
        upstream = ('http://mikes-mac-mini.dog-rattlesnake.ts.net:13000'
                    '/api/datasources/proxy/uid/monitoring-prometheus')
        query = urllib.parse.urlencode({'query': 'up{job=~"app-top-scores(|-.*)"}'})
        req = urllib.request.Request(upstream + '/api/v1/query?' + query,
                                     headers={'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.load(response)['data']['result']
        if not result or any(x['value'][1] != '1' for x in result):
            raise RuntimeError('Top Scores scrapes are not healthy')
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        backup = root / 'backups' / ('top-scores-grafana-' + stamp)
        backup.mkdir(parents=True, mode=0o700)
        for name, data in {**dashboards, uid: source}.items():
            with os.fdopen(os.open(backup / (name + '.json'), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as f:
                json.dump(data, f, indent=2)
        print('Backup:', backup)
        source.update(url=upstream, access='proxy', basicAuth=False)
        source['jsonData'] = dict(source.get('jsonData', {}), httpMethod='GET',
                                  timeInterval='15s', httpHeaderName1='Authorization')
        source['secureJsonData'] = {'httpHeaderValue1': 'Bearer ' + token}
        request('/datasources/uid/' + uid, source, 'PUT')
        for saved in dashboards.values():
            updated = migrate(saved['dashboard'])
            if updated != saved['dashboard']:
                result = request('/dashboards/db', {
                    'dashboard': updated, 'folderUid': saved['meta']['folderUid'],
                    'overwrite': True, 'message': 'Use active Top Scores monitoring jobs',
                })
                if result.get('status') != 'success':
                    raise RuntimeError('Dashboard save failed')
                saved['dashboard'] = updated

    health = request('/datasources/uid/' + uid + '/health')
    if health.get('status') != 'OK':
        raise RuntimeError('Datasource health failed')
    print('Datasource: healthy')
    end = int(time.time() * 1000)
    errors = []
    total = 0
    for dashboard_uid, saved in dashboards.items():
        dashboard = saved['dashboard']
        variables = {v['name']: v.get('current', {}).get('value', '') for v in
                     dashboard.get('templating', {}).get('list', [])}
        checked = 0
        empty = []
        for panel in panels(dashboard.get('panels', [])):
            for target in panel.get('targets', []):
                if not target.get('expr') or target.get('hide'):
                    continue
                expr = target['expr']
                for key, value in {**variables, '__rate_interval': '1m', '__interval': '1m',
                                   '__range': '6h', '__range_s': '21600'}.items():
                    expr = expr.replace('${' + key + '}', str(value)).replace('$' + key, str(value))
                query = dict(target, expr=expr, datasource=target.get('datasource', panel.get('datasource')),
                             intervalMs=60000, maxDataPoints=400)
                try:
                    result = request('/ds/query', {'from': str(end - 21600000), 'to': str(end), 'queries': [query]})
                    frames = []
                    for item in result['results'].values():
                        if item.get('error') or item.get('status', 200) != 200:
                            raise RuntimeError(item.get('error', str(item.get('status'))))
                        frames.extend(item.get('frames', []))
                    if not any(any(values for values in f.get('data', {}).get('values', [])) for f in frames):
                        empty.append(panel['title'] + '/' + target.get('refId', 'A'))
                except Exception as exc:
                    errors.append((dashboard_uid, panel['title'], str(exc)))
                checked += 1
        total += checked
        print(dashboard_uid + ': ' + str(checked) + ' queries; empty=' + json.dumps(empty), flush=True)
    print(f'{len(dashboards)} dashboards, {total} queries, {len(errors)} errors')
    for error in errors:
        print(error)
    if errors:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
