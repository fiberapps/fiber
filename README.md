<p align="center">
  <img src="Fiber/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="Fiber">
</p>

<h1 align="center">Fiber</h1>

<p align="center">A music player for iPhone, iPad, and Mac. Lyrics, a real queue, and playback that stays in the app.</p>

<p align="center">
  <a href="https://github.com/staraepp/fiber/releases/tag/v0.1.0">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/version-v0.1.0.svg?variant=secondary&size=sm&mode=dark&logo=git">
      <img alt="Version 0.1.0" src="https://shieldcn.dev/badge/version-v0.1.0.svg?variant=secondary&size=sm&mode=light&logo=git">
    </picture>
  </a>
  <a href="https://github.com/staraepp/fiber/releases/latest">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/github/release/staraepp/fiber.svg?variant=secondary&size=sm&mode=dark">
      <img alt="Release" src="https://shieldcn.dev/github/release/staraepp/fiber.svg?variant=secondary&size=sm&mode=light">
    </picture>
  </a>
  <a href="LICENSE">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/license-GPL--3.0.svg?variant=secondary&size=sm&mode=dark&logo=lu:scale">
      <img alt="License GPL-3.0" src="https://shieldcn.dev/badge/license-GPL--3.0.svg?variant=secondary&size=sm&mode=light&logo=lu:scale">
    </picture>
  </a>
  <a href="https://github.com/staraepp/fiber/stargazers">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/github/stars/staraepp/fiber.svg?variant=secondary&size=sm&mode=dark">
      <img alt="GitHub Stars" src="https://shieldcn.dev/github/stars/staraepp/fiber.svg?variant=secondary&size=sm&mode=light">
    </picture>
  </a>
  <a href="https://github.com/staraepp/fiber/network">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/github/forks/staraepp/fiber.svg?variant=secondary&size=sm&mode=dark">
      <img alt="GitHub Forks" src="https://shieldcn.dev/github/forks/staraepp/fiber.svg?variant=secondary&size=sm&mode=light">
    </picture>
  </a>
  <a href="https://github.com/staraepp/fiber/actions/workflows/protect.yml">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/github/ci/staraepp/fiber.svg?variant=secondary&size=sm&mode=dark">
      <img alt="CI" src="https://shieldcn.dev/github/ci/staraepp/fiber.svg?variant=secondary&size=sm&mode=light">
    </picture>
  </a>
</p>

<p align="center">
  <img src="docs/screenshots/home.jpg" width="22%" alt="Home">
  <img src="docs/screenshots/new.jpg" width="22%" alt="New">
  <img src="docs/screenshots/player.jpg" width="22%" alt="Now playing">
  <img src="docs/screenshots/lyrics.jpg" width="22%" alt="Lyrics">
</p>

The pictures are the built-in demo: invented artists, covers drawn on the device, and songs you can actually play. It is labelled on every tab, and you can turn it off in Settings.

## Play

- Home, New, Radio, Library, and Search.
- A floating mini-player, and a full-screen player with large lyrics.
- Shuffle, repeat one song, or repeat the queue.
- On a Mac, the cover sits large on the left and the lyrics sit large on the right.
- Your own files: MP3, AAC, ALAC, FLAC, WAV, and AIFF. A matching `.lrc` file adds synced lyrics.
- An equalizer for your files and the demo.

Apple Music, Spotify, and YouTube Music are in Settings. A service that is switched off is never contacted. Spotify and YouTube Music play inside Fiber. Spotify needs Premium, and the first song asks you to enable audio. YouTube Music signs in with Google.

## Build

Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and iOS 26. No third-party packages.

```sh
xcodegen generate
open Fiber.xcodeproj
```

Run the Fiber scheme. With nothing connected, you get the demo.

Service keys stay on your machine. Copy `.env.example` to `.env` (git ignores it), then:

```sh
python3 scripts/prepare_music_token.py
python3 scripts/prepare_spotify_config.py
```

For a device build, copy `Config/Signing.example.xcconfig` to `Config/Signing.xcconfig` and set your team. `scripts/package_ipa.sh` and `scripts/package_mac.sh` write into `.build/`, which is not in this repo.

## License

Fiber is free software under the [GNU General Public License v3.0](LICENSE). You can use it, share it, and change it. If you share a modified version, share the source under the same license.

Copyright (C) 2026 Star.

<p align="center">made with ♡ by <a href="https://github.com/staraepp">Star</a></p>
