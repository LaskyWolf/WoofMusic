//
//  PlaybackSpeed.swift
//  Trop
//

import Observation
import SwiftUI

/// Playback speed of the current item. A podcast episode starts at the speed
/// last picked for its show; anything else starts at 1×. Reloading the same
/// item (resume, repeat) keeps its speed.
@MainActor
@Observable
final class PlaybackSpeed {
    static let shared = PlaybackSpeed()

    static let lowest = 0.5
    static let highest: Double = 3
    static let step = 0.05
    /// Labelled under the dial; VoiceOver moves between them.
    static let presets = [0.75, 1, 1.25, 1.5, 2]
    /// Speeds where the dial gives a haptic notch.
    static let notches = [1, 1.25, 1.5, 2]

    private(set) var rate: Double = 1
    /// The item `rate` belongs to, and its show when it is a podcast episode.
    @ObservationIgnored private var videoId: String?
    @ObservationIgnored private var podcastId: String?

    private static let showRatesKey = "playback.podcastSpeeds"
    /// Speed per podcast id.
    @ObservationIgnored private var showRates =
        UserDefaults.standard.dictionary(forKey: PlaybackSpeed.showRatesKey) as? [String: Double] ?? [:]

    private init() {}

    /// The show of an episode. Episodes are stored with their show when its page loads.
    static func show(ofEpisode videoId: String?) async -> String? {
        guard let videoId else { return nil }
        let episode: EpisodeEntity? = (try? await DatabaseService.shared.fetchOne(EpisodeEntity.self, key: videoId)) ?? nil
        return episode?.podcastId
    }

    /// Picks the speed for the item about to load and returns it.
    @discardableResult
    func select(videoId: String?, podcastId: String?) -> Double {
        guard videoId == nil || videoId != self.videoId else { return rate }
        self.videoId = videoId
        self.podcastId = podcastId
        rate = podcastId.flatMap { showRates[$0] } ?? 1
        return rate
    }

    /// Sets the speed chosen by the user, rounded to `step`, and remembers it for the episode's show.
    func set(_ value: Double) {
        // n / 20 rather than n * 0.05, so 1.25 and 1.5 come out exact.
        let stepsPerUnit = (1 / Self.step).rounded()
        let snapped = min(Self.highest, max(Self.lowest, (value * stepsPerUnit).rounded() / stepsPerUnit))
        guard snapped != rate else { return }
        rate = snapped
        PlayerController.shared.setSpeed(snapped)
        guard let podcastId else { return }
        showRates[podcastId] = snapped
        UserDefaults.standard.set(showRates, forKey: Self.showRatesKey)
    }

    /// "1×", "1.25×".
    static func label(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

// MARK: - Dial

/// Speed dial under the progress bar: the podcast tiles' tuning scale, swiped
/// sideways under a fixed needle, with the presets as buttons below.
struct PlaybackSpeedDial: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let speed = PlaybackSpeed.shared
    @State private var hapticCount = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(PlaybackSpeed.label(speed.rate))
                    .font(.title3.weight(.bold).monospacedDigit())
                SpeedTimeLeft(rate: speed.rate)
                Spacer()
                SpeedKnob(rate: speed.rate)
            }
            .padding(.horizontal, 14)

            SpeedScale(rate: speed.rate) { apply($0) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback speed")
                .accessibilityValue(PlaybackSpeed.label(speed.rate))
                .accessibilityAdjustableAction { direction in
                    let rate = speed.rate
                    let target = direction == .increment
                        ? PlaybackSpeed.presets.first(where: { $0 > rate + 0.001 })
                        : PlaybackSpeed.presets.last(where: { $0 < rate - 0.001 })
                    if let target { apply(target, haptic: true) }
                }

            HStack(spacing: 6) {
                ForEach(PlaybackSpeed.presets, id: \.self) { preset in
                    let isSelected = abs(speed.rate - preset) < 0.001
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
                            apply(preset, haptic: true)
                        }
                    } label: {
                        Text(PlaybackSpeed.label(preset).dropLast())
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 36)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.55) : .white.opacity(0.1))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PlaybackSpeed.label(preset))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.impact(weight: .light), trigger: hapticCount)
    }

    /// Haptic notch on a preset tap, or when the speed reaches or passes a notch.
    private func apply(_ value: Double, haptic: Bool = false) {
        let old = speed.rate
        speed.set(value)
        let new = speed.rate
        let crossedNotch = PlaybackSpeed.notches.contains { abs($0 - old) > 0.001 && ($0 - old) * ($0 - new) <= 0 }
        if haptic || crossedNotch { hapticCount &+= 1 }
    }
}

/// "32 min left" at the current speed. Its own view so only this text redraws as `currentTime` ticks.
private struct SpeedTimeLeft: View {
    let rate: Double
    private let np = NowPlaying.shared

    var body: some View {
        if np.duration > 0 {
            let seconds = max(0, np.duration - np.currentTime) / rate
            Text("\(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// A small dark knob whose yellow mark turns with the speed. Decoration only.
private struct SpeedKnob: View {
    let rate: Double

    var body: some View {
        let turn = (rate - PlaybackSpeed.lowest) / (PlaybackSpeed.highest - PlaybackSpeed.lowest)
        Circle()
            .fill(RadialGradient(
                colors: [Color(white: 0.36), Color(white: 0.11)],
                center: UnitPoint(x: 0.35, y: 0.3),
                startRadius: 0,
                endRadius: 22
            ))
            .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(TuningScale.needleColor)
                    .frame(width: 2, height: 9)
                    .padding(.top, 3)
            }
            .frame(width: 34, height: 34)
            .rotationEffect(.degrees(turn * 270 - 135))
            .accessibilityHidden(true)
    }
}

/// `TuningScale`'s ticks, one per speed step, moving under a fixed centred
/// needle. Numbers every 0.5×, accent dots at the haptic notches.
private struct SpeedScale: View {
    let rate: Double
    let onChange: (Double) -> Void

    @State private var dragStartRate: Double?

    private static let height: CGFloat = 46
    /// 140 pt per 1×.
    private static let pointsPerUnit = TuningScale.tickSpacing / CGFloat(PlaybackSpeed.step)

    var body: some View {
        let lowest = PlaybackSpeed.lowest
        let stepCount = Int(((PlaybackSpeed.highest - lowest) / PlaybackSpeed.step).rounded())
        let spacing = TuningScale.tickSpacing
        let perUnit = Self.pointsPerUnit
        let width = CGFloat(stepCount) * spacing + 1
        let notchXs = PlaybackSpeed.notches.map { CGFloat($0 - lowest) * perUnit }
        let numbers = Array(stride(from: lowest, through: PlaybackSpeed.highest, by: 0.5))

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    var ticks = Path()
                    for i in 0...stepCount {
                        // Every fifth tick (0.25×) is full height, like `TuningScale`.
                        let height: CGFloat = i % 5 == 0 ? 20 : 10
                        ticks.addRect(CGRect(x: CGFloat(i) * spacing, y: size.height - height, width: 1, height: height))
                    }
                    context.fill(ticks, with: .color(.white.opacity(0.4)))
                    var dots = Path()
                    for x in notchXs {
                        dots.addEllipse(in: CGRect(x: x - 2, y: 15, width: 5, height: 5))
                    }
                    context.fill(dots, with: .color(.accentColor))
                }
                ForEach(numbers, id: \.self) { value in
                    Text(value.formatted(.number.precision(.fractionLength(0...1))))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .position(x: CGFloat(value - lowest) * perUnit, y: 6)
                }
            }
            .frame(width: width, height: Self.height)
            .offset(x: geo.size.width / 2 - CGFloat(rate - lowest) * perUnit)
        }
        .frame(height: Self.height)
        .clipped()
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.12),
                    .init(color: .white, location: 0.88),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .overlay {
            Capsule()
                .fill(TuningScale.needleColor)
                .frame(width: 2)
                .shadow(color: TuningScale.needleColor.opacity(0.9), radius: 3)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = dragStartRate ?? rate
                    if dragStartRate == nil { dragStartRate = rate }
                    // Dragging left brings higher speeds under the needle.
                    onChange(start - Double(value.translation.width / perUnit))
                }
                .onEnded { _ in dragStartRate = nil }
        )
    }
}
