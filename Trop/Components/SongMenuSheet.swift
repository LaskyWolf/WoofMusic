//
//  SongMenuSheet.swift
//  Trop
//

import SwiftUI

/// Song rows and the full player share the same actions and Settings-style menu.
struct SongMenuSheet: View {
    let song: SongItem
    var onNavigate: ((DetailRoute) -> Void)?

    var body: some View {
        PlayerMenuSheet(song: song, onNavigate: onNavigate)
    }
}
