# Woof Music

A free and open source YouTube Music client for iOS, built on [Trop](https://github.com/686udjie/Trop) by 686udjie.

## What's new in Woof Music

### Playback

- **AutoMix:** beat-matched transitions that match the tempo of the two songs and swap the bass on the bar, like a DJ
- **Smart Crossfade:** fades into the next song where the current one winds down
- **Skip non-music parts** of music videos (intros, skits) with SponsorBlock
- Pull down anywhere on the player to close it
- Equalizer presets with a curve preview for each one
- **Sleep timer** in the player's ⋯ menu: 5 to 60 minutes, or the end of the song

### Library

- Playlist editing: name and cover in one sheet; covers sync to your YouTube Music account
- Add a cover when creating a playlist
- Library opens with Liked Songs, My Top 100 and Downloads shortcuts
- Song rows show download progress
- Colorful Moods & Genres cards in Explore

### Integrations

- **ListenBrainz** scrobbling, next to Last.fm
- **Siri and Shortcuts:** shuffle liked songs, play/pause, next song ("Shuffle my liked songs in Woof Music"), play some music, and search and play a song or artist ("Play a song in Woof Music", then say the name)
- **Home Screen quick actions:** Search, Shuffle Liked Songs, Downloads, Resume

### Interface

- Native iOS menus for songs, the player and lyrics
- Account sign-in lives at the top of Settings
- The player shows a short title (no "feat." or "Official Video" tags) and a system volume bar
- Video mode and Spotify Canvas are removed

## Also from Trop

- No ads
- Stream songs and podcasts from YouTube Music
- Synced lyrics (Musixmatch, Netease, Kugou, LRCLIB, Genius), with offset, editing and search
- Library sync (playlists, albums, artists, podcasts, liked songs)
- Downloads for offline listening, with full-size cover art
- Play Next queue, song radio and listening history
- Last.fm scrobbling and Discord Rich Presence
- AirPlay, custom app icons and themes

## Installation

Requires iOS 26 or later and a YouTube Music account (sign in through the in-app web view).

The IPA is unsigned: sideload it with a tool that re-signs apps with your Apple ID, such as AltStore, SideStore, Feather or Kravasign. AltStore PAL is not supported.

### Build the IPA

- **GitHub Actions:** fork this repo, then run the **iPhone Build** workflow from the Actions tab. The IPA is attached to the run as the `Music-iOS` artifact.
- **Locally (macOS with Xcode):** run `./build_ipa.sh`. The output is `build/Music.ipa`.

### Discord Social SDK

Discord Rich Presence uses Discord's Social SDK, a proprietary binary that is not in this repo. Without it the app builds and runs, and Discord login shows an error.

To enable it, download `discord_partner_sdk.xcframework` from the Discord Developer Portal, zip it, host the zip at a private URL and save the URL as the repository secret `DISCORD_SOCIAL_SDK_URL`. For a local build, put the xcframework in `build/discord/`.

## Notable mentions

- [Trop](https://github.com/686udjie/Trop) — the app Woof Music is based on
- [SwiftyTube](https://github.com/686udjie/SwiftyTube) — Swift InnerTube client: YouTube Music requests, sign-in and session renewal
- [InnerTubeX](https://github.com/MetrolistGroup/innertubex) — eXtended InnerTube API library for Kotlin
- [zemer-cipher](https://github.com/ZemerTeam/zemer-cipher) — YouTube cipher deobfuscation and PoToken generation
- [Metrolist](https://github.com/MetrolistGroup/Metrolist) — YouTube Music client for Android

## License

This repo is licensed under [GPLv3](LICENSE.txt), like Trop. Woof Music is not affiliated with, endorsed, or sponsored by Google or YouTube.
