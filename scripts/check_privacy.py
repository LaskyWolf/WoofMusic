"""Run source guards everywhere and real token-store checks when Swift is installed.

Usage: python3 scripts/check_privacy.py
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def violations(source):
    patterns = (
        r"Log\.[^\n]*cookie\.value",
        r"Log\.[^\n]*dataSyncId\.prefix",
        r"Log\.[^\n]*(?:url|URL)[^\n]*prefix\(",
        r"Log\.[^\n]*(?:FFmpeg output|bodyStr\.prefix)",
        r"(?:UserDefaults\.standard\.set|@AppStorage)\([^\n]*sessionKey",
    )
    return [pattern for pattern in patterns if re.search(pattern, source)]


swift_files = list((ROOT / "Trop").rglob("*.swift"))
failures = [(str(p.relative_to(ROOT)), violations(p.read_text())) for p in swift_files]
failures = [(p, hits) for p, hits in failures if hits]
assert not failures, failures
# Controls prove the guard rejects both truncated secrets and plaintext persistence.
assert violations('Log.login.debug("Cookie: \\(cookie.value.prefix(20))")')
assert violations('UserDefaults.standard.set(sessionKey, forKey: LastFMDefaults.sessionKeyKey)')
print("PASS: credential and signed-link source guards")

swift = shutil.which("swift")
if not swift:
    print("BLOCKED: Swift token-store execution requires a Swift toolchain")
    raise SystemExit(2)

stubs = r'''
import Foundation
enum LastFMDefaults {
    static let sessionKeyKey = "privacy-regression.session"
    static let usernameKey = "privacy-regression.username"
}
enum Log {
    static let lastfm = Sink()
    struct Sink { func error(_ message: String) {} }
}
final class SecureStore {
    static var values: [String: Data] = [:]
    static var failSave = false
    static var blockedAccount: String?
    enum Failure: Error { case unavailable }
    init(service: String) {}
    func save(_ data: Data, for key: String) throws {
        if Self.failSave || key == Self.blockedAccount { throw Failure.unavailable }
        Self.values[key] = data
    }
    func load(for key: String) throws -> Data? { Self.values[key] }
    func delete(for key: String) throws { Self.values.removeValue(forKey: key) }
}
'''
source = (ROOT / "Trop/LastFM/LastFMTokenStore.swift").read_text()
# Only visibility changes: exercise the actual production implementation in isolation.
source = source.replace("private init()", "init()")
checks = r'''
let defaults = UserDefaults.standard
defer {
    defaults.removeObject(forKey: LastFMDefaults.sessionKeyKey)
    defaults.removeObject(forKey: LastFMDefaults.usernameKey)
}
defaults.set("legacy-secret", forKey: LastFMDefaults.sessionKeyKey)
let migrated = LastFMTokenStore()
assert(migrated.retrieveSessionKey() == "legacy-secret")
assert(defaults.object(forKey: LastFMDefaults.sessionKeyKey) == nil)
assert(String(data: SecureStore.values["sessionKey"]!, encoding: .utf8) == "legacy-secret")
SecureStore.blockedAccount = "username"
try migrated.store(sessionKey: "new-secret", username: "listener")
assert(migrated.retrieveUsername() == "listener")
SecureStore.blockedAccount = nil
assert(defaults.object(forKey: LastFMDefaults.sessionKeyKey) == nil)
assert(LastFMTokenStore().retrieveSessionKey() == "new-secret")
SecureStore.failSave = true
do {
    try migrated.store(sessionKey: "must-not-stick", username: "listener")
    assertionFailure("Keychain failures must reach the caller")
} catch {}
assert(migrated.retrieveSessionKey() == "new-secret")
SecureStore.failSave = false
migrated.clear()
assert(migrated.retrieveSessionKey() == nil)
assert(SecureStore.values.isEmpty)
assert(defaults.object(forKey: LastFMDefaults.sessionKeyKey) == nil)
print("PASS: legacy migration, Keychain-only storage, write failure, logout")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(stubs + source + checks)
    subprocess.run([swift, str(path)], check=True)
