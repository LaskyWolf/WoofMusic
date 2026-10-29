//
//  RecapHomeCard.swift
//  Trop
//

import SwiftUI

/// Takes Keep Listening's place on Home during the first week of a month,
/// opening last month's Woof Recap. `fallback` (Keep Listening) shows instead
/// when last month has no history, play history is off, or ✕ hid the card for that month.
struct RecapHomeCard<Fallback: View>: View {
    @ViewBuilder let fallback: Fallback

    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("recap.dismissedMonth") private var dismissedMonth = ""
    @State private var hasHistory = false
    @State private var showsRecap = false
    @State private var rimTurned = false

    /// Days at the start of a month that the card shows.
    static var visibleDays: Int { 7 }

    private let interval = RecapService.lastMonth()

    /// "2026-09": the recap month the card is for.
    private var monthKey: String {
        let parts = Calendar.current.dateComponents([.year, .month], from: interval.start)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    private var isInWindow: Bool {
        Calendar.current.component(.day, from: Date()) <= Self.visibleDays
    }

    private var showsCard: Bool {
        isInWindow && hasHistory && dismissedMonth != monthKey && settings.trackPlayHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsCard {
                card
                    .padding(.horizontal, DesignTokens.screenHPadding)
                    .padding(.bottom, DesignTokens.sectionGap)
                    .transition(.opacity)
            } else {
                fallback
                    .transition(.opacity)
            }
        }
        .task {
            guard isInWindow, dismissedMonth != monthKey else { return }
            let found = await RecapService.hasHistory(in: interval)
            withAnimation(.smooth(duration: 0.35)) { hasHistory = found }
        }
        .recapStory(isPresented: $showsRecap, interval: interval)
    }

    private var card: some View {
        let month = RecapService.monthName(interval)
        return Button { showsRecap = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New · Woof Recap")
                        .font(.caption2.weight(.bold))
                        .tracking(1.3)
                        .textCase(.uppercase)
                        .foregroundStyle(RecapPalette.gold)
                    Text("Your \(month) in Woof is ready ✨")
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    Text("Minutes, top song and badges")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(.white, in: Circle())
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(16)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(ZoomPressStyle())
        .accessibilityHint("Watch")
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.smooth(duration: 0.3)) { dismissedMonth = monthKey }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("Hide \(month) Recap")
        }
    }

    /// Dark card with a turning rainbow rim and a soft glow; the rim stands still with Reduce Motion.
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            rimGradient
                .mask { shape.strokeBorder(lineWidth: 6).blur(radius: 12) }
                .opacity(0.55)
            shape.fill(
                RadialGradient(colors: [RecapPalette.gold.opacity(0.25), .clear],
                               center: UnitPoint(x: 0.85, y: 0.2), startRadius: 0, endRadius: 140)
            )
            .background(shape.fill(Color(red: 0.08, green: 0.06, blue: 0.15)))
            rimGradient
                .mask { shape.strokeBorder(lineWidth: 2) }
        }
        .onAppear {
            guard !reduceMotion else { return }
            // One turn every 5 s, run by the animation system instead of redrawing each frame.
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) { rimTurned = true }
        }
    }

    /// A still gradient that turns under the rim mask. It is a square wider than the
    /// card's diagonal, so turning never shows its corners; the margin covers the glow.
    private var rimGradient: some View {
        let rim = [RecapPalette.teal, RecapPalette.gold, Color(red: 0.73, green: 0.55, blue: 1),
                   Color(red: 1, green: 0.48, blue: 0.66), RecapPalette.teal]
        return GeometryReader { geo in
            let side = hypot(geo.size.width, geo.size.height) + 60
            AngularGradient(colors: rim, center: .center)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(rimTurned && !reduceMotion ? 360 : 0))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
