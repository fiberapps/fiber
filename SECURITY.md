# Security

Fiber keeps account material on the machine that is signed in.

- Spotify refresh tokens and YouTube Music session cookies go in the Keychain.
- Apple Music keys and Spotify app registration stay in a local `.env`. The
  prepare scripts write build products that git ignores.
- Do not open a pull request that adds `.env`, `AppleMusicToken.json`,
  `SpotifyConfig.json`, a `.p8` key, or a provisioning profile.

If you find a vulnerability, please report it privately from the Security
tab of this repository. Give Fiber a chance to fix it before you publish
the details.
