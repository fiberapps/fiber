# Fiber

A music player for iPhone, iPad, and Mac. The queue, the lyrics, and the
Lock Screen stay in Fiber. Songs play in the app.

Copyright (C) 2026 Star. Fiber is free software under the
[GNU General Public License v3.0](LICENSE).

<p align="center">
  <img src="docs/screenshots/home.jpg" width="200" alt="Home, with the demo catalog">
  <img src="docs/screenshots/new.jpg" width="200" alt="New releases">
  <img src="docs/screenshots/player.jpg" width="200" alt="Now playing">
  <img src="docs/screenshots/lyrics.jpg" width="200" alt="Lyrics">
</p>

The pictures above are the built-in demo: invented artists, covers drawn on
the device, and songs synthesized into real audio. It is labelled on every
tab, and you can turn it off in Settings.

## What you can do

- Browse Home, New, Radio, Library, and Search.
- Play with a floating mini-player and a full-screen player.
- Read lyrics large, including word by word when a song has that timing.
- Shuffle, repeat one song, or repeat the queue.
- On a Mac, the cover sits large on the left and the lyrics sit large on the right.
- Import your own files: MP3, AAC, ALAC, FLAC, WAV, and AIFF. A `.lrc` file
  with the same name gives that song synced lyrics.
- Use the equalizer on your files and on the demo.

## Services

Open Settings, then Music Services. A service that is switched off is never
contacted and never asks for permission.

| Service | How playback works |
|---|---|
| Apple Music | MusicKit. Needs a signed build and a subscription to play. |
| Spotify | Plays inside Fiber through Spotify's player. Needs Premium. The first song asks you to enable audio. |
| YouTube Music | Sign in with Google. Fiber plays the audio itself. |

Spotify sign-in uses Authorization Code with PKCE, so Fiber holds no client
secret. YouTube Music keeps the Google session on this device. If a song
cannot be streamed as audio, Fiber says so.

## Build it

You need Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and
iOS 26. There are no third-party packages.

```sh
xcodegen generate
open Fiber.xcodeproj
```

Run the Fiber scheme. With nothing connected, you get the demo catalog.

### Your own keys

Service credentials stay on your machine. Copy `.env.example` to `.env` and
fill it in. That file is ignored by git.

```sh
python3 scripts/prepare_music_token.py
python3 scripts/prepare_spotify_config.py
```

- Apple Music: put your MusicKit `.p8` path, key id, and team id in `.env`.
  The script signs a short-lived developer token. It does not keep the
  private key in the app. The App ID for `fun.staraep.fiber` needs MusicKit.
- Spotify: put `SPOTIFY_CLIENT_ID` in `.env`. Register
  `fiber-spotify-login://callback` (or your own `SPOTIFY_REDIRECT_URI`) in
  the Spotify developer dashboard. While the app is in development mode,
  each account has to be on the dashboard's user list.
- Device signing: copy `Config/Signing.example.xcconfig` to
  `Config/Signing.xcconfig` and set `DEVELOPMENT_TEAM`.

To pack an unsigned iPhone build, run `scripts/package_ipa.sh`. To pack the
Mac app, run `scripts/package_mac.sh`. Those outputs land in `.build/`, which
is not part of this repository. An IPA made that way contains your developer
token and Spotify client id, so share that file only with people you trust.

## License

Fiber is free software: you can use it, share it, and change it under the
terms of the GNU General Public License as published by the Free Software
Foundation, version 3. If you share a modified version, share the source
under the same license. There is no warranty. The full text is in
[LICENSE](LICENSE).
