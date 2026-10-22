"""Check SongTitle.display against real-world title shapes.

Usage: python3 scripts/check_song_title.py (needs a Swift toolchain)
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
swift = shutil.which("swift")
if not swift:
    raise SystemExit("Swift is required to run the song title checks")

source = (root / "Trop/Utilities/SongTitle.swift").read_text()
cases = [
    ("We Run", "We Run"),
    ("Song (feat. A & B)", "Song"),
    ("Song (Official Music Video)", "Song"),
    ("Song [Official Video] (feat. X)", "Song"),
    ("Song feat. A, B", "Song"),
    ("Song ft. A", "Song"),
    ("Song (with Billie Eilish)", "Song"),
    ("Song - Remastered 2011", "Song"),
    ("Song (Lyrics)", "Song"),
    ("Song (Remix)", "Song (Remix)"),
    ("Song (Live)", "Song (Live)"),
    ("Song - Live at Wembley", "Song - Live at Wembley"),
    ("Left (Right)", "Left (Right)"),
    ("Daft - Punk", "Daft - Punk"),
    ("(Official Video)", "(Official Video)"),
]
checks = "\n".join(
    f'precondition(SongTitle.display({raw!r}) == {want!r}, "\\({raw!r}) -> \\(SongTitle.display({raw!r}))")'.replace("'", '"')
    for raw, want in cases
)
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(source + "\n" + checks + '\nprint("PASS: song titles drop credits and upload tags, keep versions")\n')
    subprocess.run([swift, str(path)], cwd=directory, check=True)
