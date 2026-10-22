# Woof Music

A free and open source YouTube Music client for iOS, built on [Trop](https://github.com/686udjie/Trop) by 686udjie.

## Features

- No ads
- Stream songs and podcasts from YouTube Music
- Synced lyrics (Musixmatch, Netease, Kugou, LRCLIB, Genius), with offset, editing and search
- Library sync (playlists, albums, artists, podcasts, liked songs)
- Custom playlist covers, synced to your YouTube Music account
- Downloads for offline listening, with full-size cover art
- Play Next queue, song radio and listening history
- System volume bar, equalizer and AirPlay in the player
- Last.fm scrobbling and Discord Rich Presence
- Custom app icons and themes

## What differs from Trop

- Native iOS menus for songs, the player and lyrics
- Account sign-in lives at the top of Settings
- Library opens with Liked Songs, My Top 100 and Downloads shortcuts
- The player shows a short title (no "feat." or "Official Video" tags) and a system volume bar
- Video mode and Spotify Canvas are removed

## Installation

Requires iOS 26 or later and a YouTube Music account (sign in through the in-app web view).

The IPA is unsigned: sideload it with a tool that re-signs apps with your Apple ID, such as AltStore, SideStore or Feather. AltStore PAL is not supported.

### Build the IPA

- **GitHub Actions:** fork this repo, then run the **iPhone Build** workflow from the Actions tab. The IPA is attached to the run as the `Music-iOS` artifact.
- **Locally (macOS with Xcode):** run `./build_ipa.sh`. The output is `build/Music.ipa`.

## Notable mentions

- [Trop](https://github.com/686udjie/Trop) — the app Woof Music is based on
- [InnerTubeX](https://github.com/MetrolistGroup/innertubex) — eXtended InnerTube API library for Kotlin
- [zemer-cipher](https://github.com/ZemerTeam/zemer-cipher) — YouTube cipher deobfuscation and PoToken generation
- [Metrolist](https://github.com/MetrolistGroup/Metrolist) — YouTube Music client for Android

## License

This repo is licensed under [GPLv3](LICENSE.txt), like Trop. Woof Music is not affiliated with, endorsed, or sponsored by Google or YouTube.
