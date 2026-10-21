// Glyph geometry adapted from f728743/AppleMusicStylePlayer, ForwardLabel.swift.
// Copyright (c) 2025 Alexey Vorobyov. MIT license in AppleMusicStylePlayer-LICENSE.txt.

import SwiftUI

struct AnimatedSkipLabel: View {
    let backwards: Bool
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        KeyframeAnimator(initialValue: 0.0, trigger: trigger) { progress in
            RollingSkipGlyph(size: 28, progress: reduceMotion ? 0 : progress)
                .scaleEffect(x: backwards ? -1 : 1)
        } keyframes: { _ in
            LinearKeyframe(1.0, duration: 0.27)
            MoveKeyframe(0.0)
        }
        .accessibilityHidden(true)
    }
}

struct RollingSkipGlyph: View {
    let size: CGFloat
    var progress: Double
    let sideFraction = 0.3

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                gliph
                    .padding(.leading, leftOffset)
                    .opacity(progress)

                gliph
                    .frame(width: size / 2)

                gliph
                    .frame(width: rightWidth)
                    .padding(.trailing, rightOffset)
                    .opacity(1 - progress)
            }
        }
        .frame(width: width, height: size)
    }

    var side: CGFloat { size * sideFraction }
    var width: CGFloat { size + side * 2 }

    var leftOffset: CGFloat {
        let res = min(sideFraction, progress) * size +
            (1 - leftGrowthProgress) * side +
            rightProtrusionProgress * side
        return res
    }

    var rightOffset: CGFloat {
        let res = max(0, sideFraction - progress) * size
            + rightShrinkProgress * side
        return res
    }

    var rightWidth: CGFloat {
        let res = (size / 2) * (1 - scaleProgress)
        return res
    }

    var scaleProgress: Double {
        max(0, (progress - sideFraction) / (1.0 - sideFraction))
    }

    var leftGrowthProgress: Double {
        let progress = min(1, progress / sideFraction)
        return sqrt(progress)
    }

    var linearRightShrinkProgress: Double {
        let progress = max(0, scaleProgress - (1 - sideFraction * 2)) / sideFraction / 2
        return progress
    }

    var rightShrinkProgress: Double {
        return linearRightShrinkProgress * linearRightShrinkProgress
    }

    var rightProtrusionProgress: Double {
        linearRightShrinkProgress - rightShrinkProgress
    }

    var gliph: some View {
        Image(systemName: "play.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

