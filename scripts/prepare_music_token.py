#!/usr/bin/env python3
"""Generate a 30-day developer token locally; never package the signing key."""
from pathlib import Path
import base64, datetime, json, os, subprocess
root = Path(__file__).resolve().parents[1]
values = {}
for line in (root / '.env').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        name, value = line.split('=', 1)
        values[name.strip()] = json.loads(value) if value.strip().startswith('"') else value.strip()
result = subprocess.run(['swift', str(root / 'scripts/lib/AppleMusicToken.swift'),
    values['APPLE_TEAM_ID'], values['APPLE_MUSIC_KEY_ID'], values['APPLE_MUSIC_KEY_FILE']],
    capture_output=True, text=True)
if result.returncode:
    raise SystemExit('Developer token signing failed; check local .env and key file.')
token = result.stdout.strip()
validation = subprocess.run(['curl', '--silent', '--show-error', '--max-time', '30',
    '--output', '/dev/null', '--write-out', '%{http_code}', '--header', '@-',
    'https://api.music.apple.com/v1/catalog/us/genres'],
    input='Authorization: Bearer ' + token + '\n', capture_output=True, text=True)
if validation.returncode or validation.stdout != '200':
    raise SystemExit('Apple Music token validation failed: HTTP ' + validation.stdout)
claims = json.loads(base64.urlsafe_b64decode(token.split('.')[1] + '=='))
out = root / 'Fiber/Resources/AppleMusicToken.json'
out.write_text(json.dumps({'token': token, 'expiresAt': claims['exp']}))
os.chmod(out, 0o600)
print('Developer token accepted by Apple Music; expires ' + datetime.datetime.fromtimestamp(claims['exp'], datetime.timezone.utc).strftime('%Y-%m-%d') + '.')
