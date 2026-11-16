<div align="center">

<img src=".github/assets/banner.svg" width="100%" alt="Woof Music: YouTube Music, native on iPhone" />

[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-black?logo=apple)](#install)
[![SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)](Trop)
[![Player: mpv](https://img.shields.io/badge/player-mpv-691f69)](https://mpv.io)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE.txt)
[![Release](https://img.shields.io/github/v/release/LaskyWolf/WoofMusic?include_prereleases&label=release)](https://github.com/LaskyWolf/WoofMusic/releases)

**A free, open source YouTube Music client for iPhone, written in SwiftUI.**
It plays without ads and mixes songs like a DJ.

<img src=".github/assets/1.png" width="31%" alt="Home" />&nbsp;
<img src=".github/assets/2.png" width="31%" alt="Player" />&nbsp;
<img src=".github/assets/3.png" width="31%" alt="Queue" />

<sub>The app's screens, with music content replaced by placeholders.</sub>

</div>

## Highlights

| | |
| --- | --- |
| 🎧 **AutoMix** | Beat-matched transitions: the two songs share a tempo and the bass swaps on the bar. |
| 🌊 **Smart Crossfade** | Fades into the next song where the current one winds down. |
| ⬇️ **Real downloads** | Songs, albums and playlists play offline, and a badge marks what is saved across the app. |
| 👤 **Separate accounts** | Each Google account keeps its own library, downloads, history, Recap and linked services. |
| 🧊 **Native iOS 26** | Liquid Glass controls, system menus and zoom transitions, with icons that move when you use them. |

## Features

- Your YouTube Music Home, Explore, moods and genres, with Flow, On Repeat, Rewind and artist mixes
- AutoMix, equalizer, sleep timer, landscape player and song comments
- Library sync, playlist editing, offline downloads and multi-select
- Listen Together rooms that work with Metrolist
- Synced lyrics from five providers, translated on the device
- Several Google accounts, search, activity inbox and Incognito mode
- Widgets, Siri and Shortcuts, Last.fm, ListenBrainz and Discord
- Opens YouTube, YouTube Music and Shazam links from any app

## Speed

- Home opens on the last saved page, or on the sections built from your library, before YouTube answers.
- The next song's stream address is loaded while the current one plays, so skipping starts at once.
- Covers of the neighbouring songs load ahead of a swipe.
- Images are held in a memory-limited cache.

## Privacy

- The app has no analytics and no server of its own. It talks to YouTube Music directly.
- SponsorBlock receives the ID of each song you play. Turn off the non-music skip in Settings to stop that.
- Lyrics providers receive the title and artist of songs they look up.
- YouTube Music receives each play while you are signed in, so it appears in your history.
- Last.fm, ListenBrainz and Discord receive what you play only after you connect them.
- The log file stays on the iPhone until you share it from Settings.

## Install

You need iOS 26 or later and a YouTube Music account. This project does not publish IPA files, so you build your own.

1. Fork this repository.
2. Open the **Actions** tab and run the **iPhone Build** workflow.
3. Download the `WoofMusic-iOS` artifact from the finished run. It contains `WoofMusic-<version>.ipa`.
4. Sideload it with a tool that re-signs apps with your Apple ID: AltStore, SideStore, Feather or KravaSign. AltStore PAL is not supported.
5. Open Woof Music and sign in from the top of Settings.

### Build on a Mac

You need Xcode.

```bash
./build_ipa.sh
```

The IPA is written to `build/WoofMusic-<version>.ipa`. The version comes from `MARKETING_VERSION` in the Xcode project.

### Discord Social SDK

Discord Rich Presence uses Discord's Social SDK, a proprietary binary that is not in this repository. Without it the app builds and runs, and Discord login shows an error.

To enable it:
1. Download `DiscordSocialSdk-<version>.zip` (the C++ one) from the Discord Developer Portal.
2. Attach it to a release tagged `discord-sdk` in a **private** repository. A release in a public repository can be downloaded by anyone.
   ```bash
   gh release create discord-sdk --repo <owner>/<private-repo> DiscordSocialSdk-<version>.zip
   ```
3. Create a fine-grained personal access token with read-only **Contents** access to that private repository, then add it and the repository name to this repository's Actions settings:
   ```bash
   gh secret set DISCORD_SDK_TOKEN --repo <owner>/<repo>
   ```
   ```bash
   gh variable set DISCORD_SDK_REPO --repo <owner>/<repo> --body <owner>/<private-repo>
   ```
   The workflow downloads the SDK from there. If it can't, the build continues without it and shows a warning.
4. For a local build, put `discord_partner_sdk.xcframework` in `build/discord/`.

## Credits

Woof Music is a fork of [Trop](https://github.com/686udjie/Trop) by 686udjie.

- [SwiftyTube](https://github.com/686udjie/SwiftyTube): Swift InnerTube client for YouTube Music requests, sign-in and session renewal
- [InnerTubeX](https://github.com/MetrolistGroup/innertubex): extended InnerTube API library for Kotlin
- [zemer-cipher](https://github.com/ZemerTeam/zemer-cipher): YouTube cipher deobfuscation and PoToken generation
- [Metrolist](https://github.com/MetrolistGroup/Metrolist): YouTube Music client for Android
- [mpv](https://mpv.io): audio playback
- [SponsorBlock](https://sponsor.ajay.app): community data on non-music segments

## License

[GPLv3](LICENSE.txt), like Trop. Woof Music is not affiliated with, endorsed or sponsored by Google or YouTube.
