<p align="center">
  <img src="Fiber/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="132" alt="Fiber">
</p>

<h1 align="center">Fiber</h1>

<p align="center">
  a little music player for your phone, your iPad, and your Mac.<br>
  the song plays here. the queue stays here. the lyrics get big.
</p>

<p align="center">
  <a href="https://github.com/staraepp/fiber/releases/tag/v0.1.0"><img alt="0.1.0" src="https://img.shields.io/badge/0.1.0-ff8fa3?style=flat"></a>
  <a href="LICENSE"><img alt="GPL-3.0" src="https://img.shields.io/badge/GPL--3.0-ffc2d4?style=flat"></a>
  <a href="https://github.com/staraepp/fiber/stargazers"><img alt="stars" src="https://img.shields.io/github/stars/staraepp/fiber?style=flat&color=ff8fa3&label=stars"></a>
</p>

<br>

<table>
  <tr>
    <td width="25%" align="center"><img src="docs/screenshots/home.jpg" alt="Home"><br><sub>home</sub></td>
    <td width="25%" align="center"><img src="docs/screenshots/new.jpg" alt="New"><br><sub>new</sub></td>
    <td width="25%" align="center"><img src="docs/screenshots/player.jpg" alt="Now playing"><br><sub>now playing</sub></td>
    <td width="25%" align="center"><img src="docs/screenshots/lyrics.jpg" alt="Lyrics"><br><sub>lyrics</sub></td>
  </tr>
</table>

<p align="center"><sub>the demo that comes with Fiber. invented artists, covers drawn on the device, songs you can actually hear. every tab says so. turn it off in Settings whenever you like.</sub></p>

## what's in it

Home, New, Radio, Library, and Search, with a little player floating over the tabs. Open a song and the whole screen becomes the player: shuffle, repeat one song, or repeat the queue.

Lyrics can follow the words when a song knows them. Bring your own MP3, AAC, ALAC, FLAC, WAV, or AIFF from Library, and a `.lrc` file with the same name sings along. The equalizer is there for those files, and for the demo.

On a Mac, the cover sits big on the left and the lyrics sit big on the right.

## the accounts you already have

Settings → Music Services. Leave a switch off and Fiber never bothers that service.

Apple Music plays through MusicKit, so it wants a signed build and a subscription. Spotify plays inside Fiber and wants Premium. The first song asks you, once, to enable audio. YouTube Music signs in with the Google account that holds your library, then Fiber plays the audio itself. If a song can't be streamed, Fiber tells you.

## make your own

Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and iOS 26. No extra packages.

```sh
xcodegen generate
open Fiber.xcodeproj
```

Run the Fiber scheme. With nothing connected, the demo is already playing.

Your keys stay on your computer. Copy `.env.example` to `.env`, then:

```sh
python3 scripts/prepare_music_token.py
python3 scripts/prepare_spotify_config.py
```

For a phone, copy `Config/Signing.example.xcconfig` to `Config/Signing.xcconfig` and write your team id. `scripts/package_ipa.sh` makes an unsigned iPhone package, and `scripts/package_mac.sh` makes the Mac app. Both land in `.build/`, which is not in this repo. The iPhone package contains your developer token, so only hand it to someone you trust.

## license

Copyright (C) 2026 Star.

Fiber is free software under the [GNU General Public License v3.0](LICENSE). Use it, share it, change it. If you pass a changed copy along, pass the source along too, under the same license.
