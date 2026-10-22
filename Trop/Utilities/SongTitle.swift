//
//  SongTitle.swift
//  Trop
//

import Foundation

/// Short display titles for tight spaces such as the full player.
/// Lists keep the full title; this only drops credits and upload tags.
enum SongTitle {
    /// Words that mark a bracketed group or dash suffix as removable.
    /// "Remix", "Live" and "Acoustic" stay: they name a different version.
    private static let fluff = #"feat\.?|ft\.?|featuring|with |prod\.?|official|video|audio|lyrics?|visuali[sz]er|m/?v|remaster(ed)?|\bhd\b|\bhq\b|\b4k\b|explicit|clean version"#

    /// "Song (feat. A & B) [Official Video]" → "Song".
    static func display(_ raw: String) -> String {
        var s = raw
        // (…) and […] groups containing a fluff word.
        s = s.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*(?:"# + fluff + #")[^\)\]]*[\)\]]"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        // Unbracketed credits: "Song feat. A", "Song ft. A".
        s = s.replacingOccurrences(
            of: #"\s+(?:feat\.?|ft\.|featuring)\s.*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        // Dash suffixes: "Song - Remastered 2011", "Song - Official Video".
        s = s.replacingOccurrences(
            of: #"\s+[-–—]\s+[^-–—]*(?:"# + fluff + #")[^-–—]*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? raw : s
    }
}
