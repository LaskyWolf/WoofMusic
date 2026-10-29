//
//  StatsWidget.swift
//  WoofWidgets
//

import SwiftUI
import WidgetKit

/// This month so far: minutes, weekly bars, streak, top song, top artists and badges.
struct StatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.stats, provider: SnapshotProvider<StatsSnapshot>(file: WidgetStore.statsFile)) { entry in
            StatsView(stats: entry.value)
                .widgetURL(WidgetLink.recap)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(hex: 0x123D4A), Color(hex: 0x0B0D12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("Woof Stats")
        .description("Your listening this month, from Woof Recap.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct StatsView: View {
    @Environment(\.widgetFamily) private var family
    let stats: StatsSnapshot?

    private static let gold = Color(hex: 0xFFD36E)
    private static let teal = Color(hex: 0x5FB3A8)

    var body: some View {
        if let stats, !stats.isTracking {
            WidgetPlaceholder(symbol: "chart.bar.xaxis", text: "Turn on Track Play History in Settings to count your listening")
        } else if let stats {
            switch family {
            case .systemSmall: small(stats)
            case .systemLarge: large(stats)
            default: medium(stats)
            }
        } else {
            WidgetPlaceholder(symbol: "chart.bar.xaxis", text: "Open Woof Music to build your stats")
        }
    }

    private func heading(_ stats: StatsSnapshot) -> some View {
        Text("\(stats.monthName) · Woof")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Self.gold)
    }

    private func minutes(_ stats: StatsSnapshot, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(stats.minutes, format: .number)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
            Text("min")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .lineLimit(1)
    }

    /// One bar per week of the month, scaled to the busiest week.
    private func bars(_ stats: StatsSnapshot, height: CGFloat) -> some View {
        let peak = max(stats.weeklyMinutes.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(stats.weeklyMinutes.enumerated()), id: \.offset) { index, value in
                let isLast = index == stats.weeklyMinutes.count - 1
                Capsule()
                    .fill(isLast ? Self.gold : Self.teal.opacity(0.75))
                    .frame(height: max(4, height * CGFloat(value) / CGFloat(peak)))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }

    /// One paw per day of the streak goal, lit for the days already in the streak.
    private func paws(_ stats: StatsSnapshot, size: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<stats.streakGoal, id: \.self) { day in
                Text("🐾")
                    .font(.system(size: size))
                    .opacity(day < stats.streakDays ? 1 : 0.22)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(stats.streakDays)-day streak")
    }

    private func small(_ stats: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(stats)
            minutes(stats, size: 30)
            bars(stats, height: 26)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("🐾 \(stats.streakDays) days")
                if let artist = stats.topArtists.first {
                    Text("#1 \(artist.name)").lineLimit(1)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ stats: StatsSnapshot) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                heading(stats)
                minutes(stats, size: 30)
                Spacer(minLength: 0)
                bars(stats, height: 34)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let song = stats.topSong {
                    Text("Top Song")
                        .font(.system(size: 9, weight: .heavy))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        CoverImage(data: song.artwork)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                            Text("\(stats.topSongPlays) plays").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        }
                        .foregroundStyle(.white)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    paws(stats, size: 10)
                    Text("\(stats.streakDays)/\(stats.streakGoal)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func large(_ stats: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    heading(stats)
                    minutes(stats, size: 32)
                }
                Spacer(minLength: 0)
                bars(stats, height: 40)
                    .frame(width: 90)
            }
            paws(stats, size: 14)
            if !stats.topArtists.isEmpty {
                sectionTitle("Top Artists")
                ForEach(Array(stats.topArtists.enumerated()), id: \.offset) { index, artist in
                    HStack(spacing: 8) {
                        CoverImage(data: artist.artwork, symbol: "person.fill")
                            .frame(width: 30, height: 30)
                            .clipShape(Circle())
                        Text("\(index + 1) · \(artist.name)")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(artist.minutes) min")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)
            if !stats.badges.isEmpty {
                sectionTitle("Badges")
                HStack(spacing: 6) {
                    ForEach(Array(stats.badges.prefix(7).enumerated()), id: \.offset) { _, badge in
                        BadgeGem(badge: badge)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.6))
    }
}

/// A badge as a hexagon gem, greyed out while locked.
private struct BadgeGem: View {
    let badge: StatsSnapshot.Badge

    var body: some View {
        let light = badge.colors.first.map { Color(hex: $0) } ?? .gray
        let dark = badge.colors.last.map { Color(hex: $0) } ?? .gray
        Hexagon()
            .fill(LinearGradient(colors: [light, dark], startPoint: .top, endPoint: .bottom))
            .frame(width: 34, height: 38)
            .overlay { Text(badge.emoji).font(.system(size: 16)) }
            .saturation(badge.isUnlocked ? 1 : 0)
            .opacity(badge.isUnlocked ? 1 : 0.35)
            .accessibilityElement()
            .accessibilityLabel(badge.isUnlocked ? badge.name : "\(badge.name), locked")
    }
}

/// Pointy-top hexagon.
private struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY + h * 0.25))
        path.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY + h * 0.75))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.75))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.25))
        path.closeSubpath()
        return path
    }
}
