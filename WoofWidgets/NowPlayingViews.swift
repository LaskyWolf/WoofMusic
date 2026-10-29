//
//  NowPlayingViews.swift
//  WoofWidgets
//

import AppIntents
import SwiftUI
import UIKit
import WidgetKit

extension Color {
    /// 0xRRGGBB.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

extension NowPlayingState {
    /// Dominant artwork color, or the app's accent when there is none.
    var tintColor: Color {
        tint.map { Color(hex: $0) } ?? .red
    }

    /// Same glyphs as the app: an episode swaps play/pause for a microphone.
    var playPauseSymbol: String {
        if isPodcast { return isPlaying ? "mic.fill" : "mic.slash.fill" }
        return isPlaying ? "pause.fill" : "play.fill"
    }
}

/// One timeline entry: the snapshot the app last wrote, or nil.
struct SnapshotEntry<Value>: TimelineEntry {
    let date: Date
    let value: Value?
}

/// Reads one App Group file. The app reloads the timeline whenever it writes the file.
struct SnapshotProvider<Value: Decodable>: TimelineProvider {
    let file: String

    func placeholder(in context: Context) -> SnapshotEntry<Value> {
        SnapshotEntry(date: .now, value: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry<Value>) -> Void) {
        completion(SnapshotEntry(date: .now, value: WidgetStore.read(Value.self, from: file)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry<Value>>) -> Void) {
        let entry = SnapshotEntry(date: Date.now, value: WidgetStore.read(Value.self, from: file))
        completion(Timeline(entries: [entry], policy: .never))
    }
}

/// A JPEG cover, or a note glyph when there is none.
struct CoverImage: View {
    let data: Data?
    var symbol = "music.note"

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.15))
        }
    }
}

/// A round glass button running an intent.
struct IntentCircleButton<Intent: AppIntent>: View {
    let intent: Intent
    let symbol: String
    let label: String
    var size: CGFloat = 34
    var isProminent = false
    var isOn = false

    var body: some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(isProminent ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(isProminent ? Color.white : Color.white.opacity(isOn ? 0.4 : 0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Shown when the app hasn't written anything yet, or can't share anything at all.
struct WidgetPlaceholder: View {
    let symbol: String
    let text: String

    /// Neither an App Group nor the team's Keychain group came through signing.
    private static let noStorage = "Your signing tool removed the shared storage widgets need. Re-sign with App Groups kept."

    var body: some View {
        let canShare = WidgetStore.canShare
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: canShare ? symbol : "exclamationmark.triangle")
                .font(.title2)
            Spacer(minLength: 0)
            Text(canShare ? text : Self.noStorage)
                .font(.subheadline.weight(.medium))
                .lineLimit(4)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
