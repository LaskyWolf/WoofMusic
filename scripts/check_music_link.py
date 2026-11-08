"""Check MusicLink against real-world link shapes.

Usage: python3 scripts/check_music_link.py (needs a Swift toolchain)
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import quote

root = Path(__file__).resolve().parents[1]
swift = shutil.which("swift")
if not swift:
    raise SystemExit("Swift is required to run the music link checks")

source = "\n".join((root / f"Trop/Utilities/{name}.swift").read_text() for name in ("MusicLink", "ShazamLink"))
video = "dQw4w9WgXcQ"
cases = [
    (f"https://music.youtube.com/watch?v={video}", f'.song(videoId: "{video}")'),
    (f"https://music.youtube.com/watch?v={video}&si=abc&list=RDAMVM{video}", f'.song(videoId: "{video}")'),
    (f"https://www.youtube.com/watch?v={video}", f'.song(videoId: "{video}")'),
    (f"https://m.youtube.com/watch?v={video}", f'.song(videoId: "{video}")'),
    (f"http://youtube.com/watch?v={video}", f'.song(videoId: "{video}")'),
    (f"HTTPS://MUSIC.YouTube.com/watch?v={video}", f'.song(videoId: "{video}")'),
    (f"https://youtu.be/{video}?si=abc", f'.song(videoId: "{video}")'),
    ("https://music.youtube.com/watch?list=PLabc-_1", '.playlist(id: "PLabc-_1")'),
    ("https://music.youtube.com/playlist?list=OLAK5uy_abc", '.playlist(id: "OLAK5uy_abc")'),
    ("https://youtube.com/playlist?list=PLabc&si=x", '.playlist(id: "PLabc")'),
    ("https://music.youtube.com/browse/VLPLabc", '.playlist(id: "VLPLabc")'),
    ("https://music.youtube.com/browse/MPREb_abc", '.album(browseId: "MPREb_abc")'),
    ("https://music.youtube.com/browse/UCabc", '.artist(browseId: "UCabc")'),
    ("https://music.youtube.com/browse/MPCHabc", '.artist(browseId: "MPCHabc")'),
    ("https://music.youtube.com/channel/UCabc", '.artist(browseId: "UCabc")'),
    ("https://music.youtube.com/browse/MPSPPLabc", '.podcast(browseId: "MPSPPLabc")'),
    (f"https://youtube.com/shorts/{video}", f'.song(videoId: "{video}")'),
    (f"https://www.youtube.com/embed/{video}?autoplay=1", f'.song(videoId: "{video}")'),
    (f"https://www.youtube.com/live/{video}", f'.song(videoId: "{video}")'),
    ("https://music.youtube.com/podcast/MPSPPLabc", '.podcast(browseId: "MPSPPLabc")'),
    ("https://music.youtube.com/", "nil"),
    ("https://music.youtube.com/watch", "nil"),
    ("https://music.youtube.com/watch?v=short", "nil"),
    ("https://music.youtube.com/watch?v=dQw4w9WgXc%0A", "nil"),
    ("https://music.youtube.com/playlist", "nil"),
    ("https://music.youtube.com/playlist?list=a/b", "nil"),
    ("https://music.youtube.com/browse/FEmusic_home", "nil"),
    ("https://music.youtube.com/browse/UCabc/extra", "nil"),
    (f"https://youtu.be/{video}/extra", "nil"),
    ("https://youtu.be/", "nil"),
    (f"https://evil.example/watch?v={video}", "nil"),
    (f"https://music.youtube.com.evil.example/watch?v={video}", "nil"),
    (f"ftp://youtube.com/watch?v={video}", "nil"),
    ("https://open.spotify.com/track/abc", "nil"),
    ("https://music.apple.com/album/abc", "nil"),
]
checks = [
    f'precondition(MusicLink(link: URL(string: "{link}")!) == {want}, "{link}")'
    for link, want in cases
]
# woofmusic://open wraps a link, percent-encoded so its own query survives.
wrapped = f"https://music.youtube.com/watch?v={video}&list=PLabc"
checks += [
    f'precondition(MusicLink(openURL: URL(string: "woofmusic://open?url={quote(wrapped, safe="")}")!) == .song(videoId: "{video}"))',
    'precondition(MusicLink(openURL: URL(string: "woofmusic://open")!) == nil)',
    'precondition(MusicLink(openURL: URL(string: "woofmusic://open?url=")!) == nil)',
]
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(source + "\n" + "\n".join(checks) + '\nprint("PASS: music links parse by shape, others are refused")\n')
    subprocess.run([swift, str(path)], cwd=directory, check=True)
