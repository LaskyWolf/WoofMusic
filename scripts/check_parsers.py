"""Check the small parsers behind Notifications, History, Recap and library paging.

Usage: python3 scripts/check_parsers.py (needs a Swift toolchain)
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
swift = shutil.which("swift")
if not swift:
    raise SystemExit("Swift is required to run the parser checks")


def cut(path, start, end="\n    }\n"):
    source = (root / path).read_text()
    first = source.index(start)
    return source[first:source.index(end, first) + len(end)]


key = cut("Trop/Activity/ReleaseFeed.swift", "    static func key(")
day = cut("Trop/History/HistoryViewModel.swift", "    static func day(forTitle")
shelf = cut("Trop/Profile/RecapService.swift", "    static func shelfDate(")
token = cut("Trop/Services/LibraryPages.swift", "    static func nextPageToken")
json = cut("Trop/Activity/ActivityView.swift", "enum ActivityJSON", "/// The notifications")
album = cut("Trop/Networking/Models/YTItem.swift", "private func albumBrowseId", "\n}\n").replace("private ", "")

checks = r'''
let cal = Calendar.current
// Tuesday 17 November 2026, noon.
let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))!
func ymd(_ date: Date?) -> String {
    guard let date else { return "nil" }
    let c = cal.dateComponents([.year, .month, .day], from: date)
    return "\(c.year!)-\(c.month!)-\(c.day!)"
}
func expect(_ got: String?, _ want: String?, _ label: String) {
    precondition(got == want, "\(label): got \(got ?? "nil"), want \(want ?? "nil")")
}

// Deezer and YouTube titles match by letters and digits only.
for (title, want) in [("From Zero (Deluxe)", "fromzerodeluxe"), ("from zero deluxe", "fromzerodeluxe"),
                      ("AC/DC", "acdc"), ("\u{200B}Drake", "drake"), ("1989 (Taylor's Version)", "1989taylorsversion")] {
    expect(K.key(title), want, "key \(title)")
}

// History shelf titles that name one day.
for (title, want) in [("Today", "2026-11-17"), (" yesterday ", "2026-11-16"), ("Sunday", "2026-11-15"),
                      ("Tuesday", "2026-11-10"), ("November 12", "2026-11-12"), ("December 3", "2025-12-3"),
                      ("Nov 12, 2024", "2024-11-12"), ("Last week", "nil")] {
    expect(ymd(H.day(forTitle: title, now: now)), want, "day \(title)")
}

// Recap and History place period shelves on one day inside the period.
for (title, want) in [("Today", "2026-11-17"), ("Last week", "2026-11-10"), ("Last month", "2026-10-17"),
                      ("September", "2026-9-15"), ("December", "2025-12-15"), ("March 2024", "2024-3-15"), ("Someday", "nil")] {
    expect(ymd(R.shelfDate(title, now: now, calendar: cal)), want, "shelf \(title)")
}

// Library pages: the next page's token, in either shape.
func parsed(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8)) }
for (text, want) in [
    (#"{"a":{"continuations":[{"nextContinuationData":{"continuation":"A"}}]}}"#, "A"),
    (#"{"x":{"continuationEndpoint":{"continuationCommand":{"token":"B"}}}}"#, "B"),
    (#"[{"nextContinuationData":{"continuation":"A"}}]"#, "A"),
    (#"{"contents":[]}"#, nil),
] as [(String, String?)] {
    expect(L.nextPageToken(in: parsed(text)), want, "token \(text)")
}

// Song rows take the album only from a run that opens an album page.
for (text, want) in [
    (#"{"text":"A","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_x"}}}"#, "MPREb_x"),
    (#"{"text":"A","navigationEndpoint":{"browseEndpoint":{"browseId":"OLAK5uy_a","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}"#, "OLAK5uy_a"),
    (#"{"text":"B","navigationEndpoint":{"browseEndpoint":{"browseId":"UCabc","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}}"#, nil),
    (#"{"text":"3:45"}"#, nil),
    (#"{"text":"S","navigationEndpoint":{"watchEndpoint":{"videoId":"abc"}}}"#, nil),
] as [(String, String?)] {
    expect(albumBrowseId(parsed(text) as! [String: Any]), want, "album \(text)")
}

print("PASS: release keys, history days, shelf dates, page tokens and album runs")
'''

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(
        "import Foundation\n"
        + json + "\n"
        + "enum K {\n" + key + "}\n"
        + "enum H {\n" + day + "}\n"
        + "enum R {\n" + shelf + "}\n"
        + "enum L {\n" + token + "}\n"
        + album + "\n"
        + checks
    )
    subprocess.run([swift, str(path)], cwd=directory, check=True)
