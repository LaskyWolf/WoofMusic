"""Check AppUpdater.isNewer against version pairs.

Usage: python3 scripts/check_app_version.py (needs a Swift toolchain)
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
swift = shutil.which("swift")
if not swift:
    raise SystemExit("Swift is required to run the version checks")

source = (root / "Trop/Settings/AppUpdater.swift").read_text()
start = source.index("    nonisolated static func isNewer")
end = source.index("\n    }\n", start) + len("\n    }\n")
function = source[start:end].replace("nonisolated ", "")
cases = [
    ("1.5", "1.4.3", True),
    ("1.4.3", "1.4.3", False),
    ("1.5", "1.5.0", False),
    ("1.10", "1.9", True),
    ("1.4.2", "1.4.3", False),
    ("2", "1.99.9", True),
]
checks = "\n".join(
    f'precondition(V.isNewer("{a}", than: "{b}") == {str(want).lower()}, "{a} vs {b}")'
    for a, b, want in cases
)
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text("enum V {\n" + function + "}\n" + checks + '\nprint("PASS: newer versions compare by number")\n')
    subprocess.run([swift, str(path)], cwd=directory, check=True)
