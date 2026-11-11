#!/usr/bin/env python3
"""Bundle the Spotify app registration (Client ID + redirect URI) into the app.

Reads SPOTIFY_CLIENT_ID and SPOTIFY_REDIRECT_URI from Fiber's .env and, for any
that are missing, from Tune's .env (override the path with TUNE_ENV). A Client
ID is public by design (the sign-in uses PKCE, so there is no client secret),
but it is still kept out of git and out of the console.

Without a Client ID the file is removed and the app shows Spotify as unavailable.
"""
from pathlib import Path
import json, os, sys, urllib.error, urllib.parse, urllib.request, base64, hashlib, secrets

root = Path(__file__).resolve().parents[1]
out = root / 'Fiber/Resources/SpotifyConfig.json'
DEFAULT_REDIRECT = 'fiber-spotify-login://callback'


def read_env(path):
    values = {}
    if not path.is_file():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        if line.startswith('export '):
            line = line[len('export '):]
        name, value = line.split('=', 1)
        value = value.strip()
        if value[:1] in ('"', "'") and value[-1:] == value[:1] and len(value) >= 2:
            value = value[1:-1]
        elif ' #' in value:
            value = value.split(' #', 1)[0].strip()
        values[name.strip()] = value
    return values


own = read_env(root / '.env')
tune = read_env(Path(os.environ.get('TUNE_ENV', Path.home() / 'Tune/.env')))
client_id = own.get('SPOTIFY_CLIENT_ID') or tune.get('SPOTIFY_CLIENT_ID') or ''
redirect = own.get('SPOTIFY_REDIRECT_URI') or tune.get('SPOTIFY_REDIRECT_URI') or DEFAULT_REDIRECT

if not client_id:
    out.unlink(missing_ok=True)
    print('Spotify: no SPOTIFY_CLIENT_ID in .env (or Tune/.env); Spotify will show as unavailable.')
    sys.exit(0)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def check_registration():
    """Ask Spotify's sign-in page whether it accepts this Client ID and redirect URI."""
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    query = urllib.parse.urlencode({
        'client_id': client_id, 'response_type': 'code', 'redirect_uri': redirect,
        'code_challenge_method': 'S256', 'code_challenge': challenge, 'scope': 'user-read-private',
    })
    request = urllib.request.Request('https://accounts.spotify.com/authorize?' + query, headers={'User-Agent': 'Fiber build check'})
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=20) as reply:
            return reply.status, ''
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode('utf-8', 'replace')
    except OSError as error:
        return None, str(error)


status, body = check_registration()
if status in (200, 301, 302, 303, 307):
    verdict = 'Spotify accepted the Client ID and redirect URI.'
elif status is None:
    verdict = 'Spotify could not be reached to check the registration (' + body + '); bundling anyway.'
elif status == 400 and 'redirect' in body.lower():
    verdict = ('WARNING: Spotify does not recognise the redirect URI ' + redirect + '. Add it under Redirect URIs '
               'in the Spotify developer dashboard, or sign-in will fail.')
elif status == 400:
    verdict = 'WARNING: Spotify rejected the Client ID (HTTP 400). Check SPOTIFY_CLIENT_ID.'
else:
    verdict = 'Spotify answered HTTP ' + str(status) + ' when checking the registration; bundling anyway.'

out.write_text(json.dumps({'clientID': client_id, 'redirectURI': redirect}))
os.chmod(out, 0o600)
print('Spotify config bundled (redirect ' + redirect + '). ' + verdict)
