//
//  ShareCardStudio.swift
//  Trop
//

import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Options

/// One choice in a row of the studio's tray.
protocol ShareCardOption: RawRepresentable, CaseIterable, Identifiable, Hashable where RawValue == String {
    var title: String { get }
}

enum ShareCardBackground: String, ShareCardOption {
    case glow, equalizer, paws, halftone, confetti
    var id: Self { self }

    var title: String {
        switch self {
        case .glow: "Cover Glow"
        case .equalizer: "Equalizer"
        case .paws: "Paws"
        case .halftone: "Halftone"
        case .confetti: "Confetti"
        }
    }
}

enum ShareCardFrame: String, ShareCardOption {
    case polaroid, ticket, cassette, vinyl, cd
    var id: Self { self }

    var title: String {
        switch self {
        case .polaroid: "Polaroid"
        case .ticket: "Ticket"
        case .cassette: "Cassette"
        case .vinyl: "Vinyl"
        case .cd: "CD"
        }
    }
}

enum ShareCardText: String, ShareCardOption {
    case paper, marker, typewriter, chat
    var id: Self { self }

    var title: String {
        switch self {
        case .paper: "Paper"
        case .marker: "Marker"
        case .typewriter: "Typewriter"
        case .chat: "Chat"
        }
    }
}

struct ShareCardStyle: Equatable {
    var background = ShareCardBackground.glow
    var frame = ShareCardFrame.polaroid
    var text = ShareCardText.paper
    /// Which of the cover's three palettes.
    var palette = 0
    var showsTimestamp = true
    var showsCode = false
}

/// An emoji on the card, placed by the user.
struct ShareCardSticker: Identifiable, Equatable {
    let id = UUID()
    let emoji: String
    /// Centre, as a fraction of the card's width and height.
    var position: CGPoint
    var scale: CGFloat = 1
    /// Fixed lean, so stickers don't all stand straight.
    let tilt = Double.random(in: -14...14)
}

/// What a card shows, whatever its look.
struct ShareCardContent {
    let lines: [String]
    let title: String
    let artist: String
    let cover: UIImage?
    let colors: [Color]
    /// Where the first picked line starts, in seconds; nil for a song card.
    let startTime: TimeInterval?
    let videoId: String?

    static let paletteCount = 3

    /// The song link; with `atLine`, it starts playback at the first picked line.
    func link(atLine: Bool) -> URL? {
        guard let videoId else { return nil }
        var address = "https://music.youtube.com/watch?v=\(videoId)"
        if atLine, let startTime, startTime >= 1 { address += "&t=\(Int(startTime))" }
        return URL(string: address)
    }

    /// Three colours from the cover, rotated so each palette leads with a different one.
    func palette(_ index: Int) -> [Color] {
        var base = colors.isEmpty ? [Color(red: 0.23, green: 0.16, blue: 0.42), Color(red: 1, green: 0.54, blue: 0.36)] : colors
        while base.count < 3 {
            base.append(base[base.count - 1].mix(with: .white, by: 0.35))
        }
        let three = Array(base.prefix(3))
        let shift = index % 3
        return Array(three[shift...] + three[..<shift])
    }
}

// MARK: - Card

/// The 9:16 share card: background, framed cover, picked lines, stickers and
/// a footer with the time and a QR code. `phase` (0..<1) is one loop of the
/// moving parts, so a still card and every video frame come from the same view.
struct ShareCard: View {
    let content: ShareCardContent
    let style: ShareCardStyle
    @Binding var stickers: [ShareCardSticker]
    var phase: Double = 0.3
    var code: UIImage?
    /// Points on screen per card point, while the studio edits the stickers.
    var editScale: CGFloat?

    static let size = CGSize(width: 360, height: 640)
    static let paper = Color(red: 1, green: 0.98, blue: 0.94)
    static let ink = Color(red: 0.11, green: 0.08, blue: 0.13)

    var body: some View {
        let colors = content.palette(style.palette)
        VStack(spacing: 0) {
            ShareCardFrameView(content: content, kind: style.frame, colors: colors, phase: phase)
                .padding(.top, 52)
            Spacer(minLength: 16)
            if !content.lines.isEmpty {
                ShareCardLinesView(lines: content.lines, kind: style.text, colors: colors)
                    .layoutPriority(1)
            }
            Spacer(minLength: 16)
            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 26)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            ShareCardBackgroundView(kind: style.background, colors: colors, phase: phase)
        }
        .overlay { stickerLayer }
        .clipped()
    }

    private var timestamp: String? {
        guard style.showsTimestamp, let start = content.startTime else { return nil }
        return "▶ " + DurationFormat.playbackTime(start)
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            if code == nil { Spacer(minLength: 0) }
            VStack(alignment: code == nil ? .center : .leading, spacing: 6) {
                Text("🐾 Woof Music")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Self.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Self.paper.opacity(0.92), in: Capsule())
                if let timestamp {
                    Text(timestamp)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
            }
            Spacer(minLength: 0)
            if let code {
                Image(uiImage: code)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("QR code for the song")
            }
        }
    }

    private var stickerLayer: some View {
        ZStack {
            ForEach($stickers) { $sticker in
                ShareCardStickerView(sticker: $sticker, phase: phase, editScale: editScale) {
                    withAnimation(.spring(duration: 0.3)) { stickers.removeAll { $0.id == sticker.id } }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// The card as a 1080×1920 image. ImageRenderer can't wait for async
    /// images, so the cover in `content` is already loaded.
    @MainActor
    static func render(
        content: ShareCardContent, style: ShareCardStyle, stickers: [ShareCardSticker], code: UIImage?, phase: Double = 0.3
    ) -> CGImage? {
        let renderer = ImageRenderer(content: ShareCard(
            content: content, style: style, stickers: .constant(stickers), phase: phase, code: code
        ))
        renderer.scale = 1080 / size.width
        return renderer.cgImage
    }

    /// A QR code of `url`, one pixel per module; draw it without interpolation.
    static func qrCode(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Backgrounds

private struct ShareCardBackgroundView: View {
    let kind: ShareCardBackground
    let colors: [Color]
    let phase: Double

    var body: some View {
        ZStack {
            switch kind {
            case .glow: glow
            case .equalizer: equalizer
            case .paws: paws
            case .halftone: halftone
            case .confetti: confetti
            }
            // Darker toward the bottom, so the lines and the footer stand out on light covers.
            LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .center, endPoint: .bottom)
        }
    }

    /// Two glows circling in opposite directions and breathing twice per loop.
    private var glow: some View {
        let angle = phase * 2 * .pi
        let breath = 40 * sin(2 * angle)
        return ZStack {
            colors[0]
            RadialGradient(
                colors: [colors[1], .clear],
                center: UnitPoint(x: 0.3 + 0.18 * cos(angle), y: 0.25 + 0.12 * sin(angle)),
                startRadius: 0, endRadius: 340 + breath
            )
            RadialGradient(
                colors: [colors[2].opacity(0.85), .clear],
                center: UnitPoint(x: 0.75 - 0.18 * cos(angle), y: 0.72 - 0.12 * sin(angle)),
                startRadius: 0, endRadius: 300 - breath
            )
        }
    }

    /// Equalizer bars along the bottom. Each bar bounces a whole number of
    /// times per loop, so the loop has no seam.
    private var equalizer: some View {
        ZStack {
            LinearGradient(colors: [colors[0], colors[1]], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                let count = 18
                let gap: CGFloat = 6
                let width = (size.width - gap * CGFloat(count + 1)) / CGFloat(count)
                for index in 0..<count {
                    let bounces = Double(1 + index % 3)
                    let wave = sin((phase * bounces + Self.noise(index, 4)) * 2 * .pi)
                    let height = size.height * (0.18 + 0.16 * (wave + 1) + 0.12 * Self.noise(index, 5))
                    let x = gap + CGFloat(index) * (width + gap)
                    let rect = CGRect(x: x, y: size.height - height, width: width, height: height + width / 2)
                    let shading = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [colors[2], colors[2].opacity(0.25)]),
                        startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: size.height)
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: shading)
                }
            }
        }
    }

    /// Paw prints drifting up two rows and right one cell per loop: the
    /// rows' alternating offsets line up again, so the loop has no seam.
    private var paws: some View {
        let ink = Color.white.opacity(0.3)
        return ZStack {
            colors[1]
            Canvas { context, size in
                let cell: CGFloat = 64
                var row = 0
                var y = -cell - CGFloat(phase) * cell * 2
                while y < size.height + cell {
                    var x = -cell + CGFloat(phase) * cell + (row.isMultiple(of: 2) ? 0 : cell / 2)
                    while x < size.width + cell {
                        Self.drawPaw(in: &context, at: CGPoint(x: x, y: y), size: 22, tilt: row.isMultiple(of: 2) ? -0.3 : 0.3, color: ink)
                        x += cell
                    }
                    y += cell
                    row += 1
                }
            }
        }
    }

    private var halftone: some View {
        ZStack {
            LinearGradient(colors: [colors[2], colors[1]], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                let step: CGFloat = 12
                var y: CGFloat = 0
                while y < size.height + step {
                    var x: CGFloat = 0
                    // Dots grow toward the bottom, like a comic print.
                    let radius = 0.8 + 3.4 * y / size.height
                    while x < size.width + step {
                        let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(colors[0].opacity(0.55)))
                        x += step
                    }
                    y += step
                }
            }
        }
    }

    /// Pieces fall one or two card heights per loop, so the loop has no seam.
    private var confetti: some View {
        let palette = [colors[1], colors[2], Color.white]
        return ZStack {
            colors[0]
            Canvas { context, size in
                for index in 0..<46 {
                    let laps = Double(1 + index % 2)
                    let fall = (Self.noise(index, 2) + phase * laps).truncatingRemainder(dividingBy: 1)
                    let x = Self.noise(index, 1) * size.width
                    let y = fall * (size.height + 40) - 20
                    var piece = context
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .degrees(Self.noise(index, 3) * 360 + phase * 360 * laps))
                    let rect = CGRect(x: -4, y: -7, width: 8, height: 14)
                    piece.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(palette[index % palette.count]))
                }
            }
        }
    }

    /// A repeatable 0..<1 value for a confetti piece.
    static func noise(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43_758.5453
        return value - value.rounded(.down)
    }

    static func drawPaw(in context: inout GraphicsContext, at center: CGPoint, size: CGFloat, tilt: Double, color: Color) {
        var paw = context
        paw.translateBy(x: center.x, y: center.y)
        paw.rotate(by: .radians(tilt))
        let pad = CGRect(x: -size * 0.32, y: -size * 0.05, width: size * 0.64, height: size * 0.5)
        paw.fill(Path(ellipseIn: pad), with: .color(color))
        let toes: [CGPoint] = [
            CGPoint(x: -size * 0.36, y: -size * 0.2), CGPoint(x: -size * 0.13, y: -size * 0.38),
            CGPoint(x: size * 0.13, y: -size * 0.38), CGPoint(x: size * 0.36, y: -size * 0.2)
        ]
        let toe = size * 0.2
        for point in toes {
            paw.fill(Path(ellipseIn: CGRect(x: point.x - toe / 2, y: point.y - toe / 2, width: toe, height: toe * 1.15)), with: .color(color))
        }
    }
}

// MARK: - Frames

private struct ShareCardFrameView: View {
    let content: ShareCardContent
    let kind: ShareCardFrame
    let colors: [Color]
    let phase: Double

    private static let ink = ShareCard.ink

    var body: some View {
        switch kind {
        case .polaroid: polaroid
        case .ticket: ticket
        case .cassette: cassette
        case .vinyl: vinyl
        case .cd: cd
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover = content.cover {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [colors[1], colors[0]], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func titles(titleSize: CGFloat, alignment: HorizontalAlignment, color: Color, lineLimit: Int = 2) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(content.title)
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
            Text(content.artist)
                .font(.system(size: titleSize * 0.76, weight: .semibold, design: .rounded))
                .opacity(0.65)
        }
        .lineLimit(lineLimit)
        .minimumScaleFactor(0.7)
        .foregroundStyle(color)
    }

    /// The cover as a taped photo with the title written under it.
    private var polaroid: some View {
        let side: CGFloat = 184
        return VStack(spacing: 10) {
            coverImage
                .frame(width: side, height: side)
                .clipped()
            titles(titleSize: 17, alignment: .center, color: Self.ink, lineLimit: 1)
                .frame(width: side)
        }
        .padding([.horizontal, .top], 11)
        .padding(.bottom, 14)
        .background(Color.white)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        .overlay(alignment: .top) {
            // Translucent tape holding the photo on.
            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 92, height: 26)
                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                .rotationEffect(.degrees(3))
                .offset(y: -13)
        }
        .rotationEffect(.degrees(-5))
    }

    /// A concert ticket with punched notches on both sides.
    private var ticket: some View {
        HStack(spacing: 14) {
            coverImage
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text("ADMIT ONE · WOOF")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Self.ink.opacity(0.55))
                titles(titleSize: 19, alignment: .leading, color: Self.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .frame(width: 304)
        .background(Color(red: 1, green: 0.97, blue: 0.9))
        .mask {
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                    ForEach([0, proxy.size.width], id: \.self) { x in
                        Circle()
                            .frame(width: 26, height: 26)
                            .position(x: x, y: proxy.size.height / 2)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        .rotationEffect(.degrees(2))
    }

    /// A tape with the title on its label and reels that turn.
    private var cassette: some View {
        let turn = Angle.degrees(phase * 720)
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                coverImage
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("SIDE A")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Self.ink.opacity(0.55))
                    titles(titleSize: 16, alignment: .leading, color: Self.ink, lineLimit: 1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(colors[2].mix(with: .white, by: 0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 44) {
                ForEach(0..<2, id: \.self) { _ in
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 7, dash: [5, 5]))
                        .frame(width: 52, height: 52)
                        .overlay(Circle().fill(Color.white.opacity(0.9)).frame(width: 14, height: 14))
                        .rotationEffect(turn)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 30)
            .background(Color.black.opacity(0.35), in: Capsule())
        }
        .padding(14)
        .frame(width: 300)
        .background(Color(red: 0.13, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .rotationEffect(.degrees(-2))
    }

    /// The record half out of its sleeve, turning once per loop.
    private var vinyl: some View {
        let side: CGFloat = 200
        return VStack(spacing: 14) {
            ZStack(alignment: .leading) {
                record(side: side)
                    .rotationEffect(.degrees(phase * 360))
                    .offset(x: 70)
                coverImage
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 10, x: 4, y: 6)
            }
            .frame(width: side + 70, alignment: .leading)
            titles(titleSize: 18, alignment: .center, color: .white, lineLimit: 1)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .frame(width: 280)
        }
    }

    /// The cover printed on a CD, turning once per loop.
    private var cd: some View {
        let side: CGFloat = 250
        return VStack(spacing: 16) {
            ZStack {
                coverImage
                    .frame(width: side, height: side)
                // Rainbow sheen of the disc surface.
                Circle()
                    .fill(AngularGradient(colors: [.clear, .cyan.opacity(0.25), .clear, .pink.opacity(0.22), .clear, .yellow.opacity(0.2), .clear], center: .center))
                    .blendMode(.screen)
                // The clear plastic ring round the hole.
                Circle()
                    .fill(.white.opacity(0.35))
                    .frame(width: side * 0.3, height: side * 0.3)
                Circle()
                    .stroke(.white.opacity(0.5), lineWidth: 1)
                    .frame(width: side * 0.3, height: side * 0.3)
                Circle()
                    .frame(width: side * 0.12, height: side * 0.12)
                    .blendMode(.destinationOut)
            }
            .frame(width: side, height: side)
            .clipShape(Circle())
            .compositingGroup()
            .overlay { Circle().stroke(.white.opacity(0.35), lineWidth: 1) }
            .rotationEffect(.degrees(phase * 360))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
            titles(titleSize: 18, alignment: .center, color: .white, lineLimit: 1)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .frame(width: 280)
        }
    }

    private func record(side: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.07))
            ForEach(0..<9, id: \.self) { ring in
                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    .padding(CGFloat(10 + ring * 7))
            }
            // Light catching the grooves.
            Circle()
                .fill(AngularGradient(colors: [.clear, .white.opacity(0.12), .clear, .clear, .white.opacity(0.08), .clear], center: .center))
            Circle()
                .fill(colors[1])
                .frame(width: side * 0.34, height: side * 0.34)
            Circle()
                .fill(Color.black)
                .frame(width: 8, height: 8)
        }
        .frame(width: side, height: side)
    }
}

// MARK: - Lines

private struct ShareCardLinesView: View {
    let lines: [String]
    let kind: ShareCardText
    let colors: [Color]

    private static let ink = ShareCard.ink

    var body: some View {
        // ponytail: fixed sizes for 1–2 vs 3–4 lines; very long lines shrink via minimumScaleFactor.
        let fontSize: CGFloat = lines.count <= 2 ? 21 : 17
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                row(line, index: index, fontSize: fontSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private func row(_ line: String, index: Int, fontSize: CGFloat) -> some View {
        let isEven = index.isMultiple(of: 2)
        switch kind {
        case .paper:
            Text(line)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(Self.ink)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ShareCard.paper, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 0, y: 2)
                .rotationEffect(.degrees(isEven ? -1.5 : 1.5))
                .padding(.leading, isEven ? 0 : 18)
        case .marker:
            Text(line)
                .font(.custom("MarkerFelt-Wide", size: fontSize + 3))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .background(alignment: .bottom) {
                    // A highlighter stroke behind the lower half of the words.
                    Rectangle()
                        .fill(colors[1].opacity(0.85))
                        .frame(height: fontSize * 0.55)
                        .offset(y: -2)
                }
                .shadow(color: colors[0].opacity(0.9), radius: 0, x: 2, y: 2)
        case .typewriter:
            Text(line)
                .font(.custom("AmericanTypewriter-Semibold", size: fontSize - 2))
                .foregroundStyle(Self.ink)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.96, green: 0.94, blue: 0.89))
                .overlay(alignment: .leading) {
                    Rectangle().fill(colors[1]).frame(width: 4)
                }
        case .chat:
            // The lines answer each other, like messages.
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: isEven ? 4 : 18,
                bottomTrailingRadius: isEven ? 18 : 4, topTrailingRadius: 18, style: .continuous
            )
            Text(line)
                .font(.system(size: fontSize - 1, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.ink)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(isEven ? Color.white : colors[2].mix(with: .white, by: 0.6), in: shape)
                .frame(maxWidth: .infinity, alignment: isEven ? .leading : .trailing)
        }
    }
}

// MARK: - Stickers

private struct ShareCardStickerView: View {
    @Binding var sticker: ShareCardSticker
    let phase: Double
    let editScale: CGFloat?
    let onRemove: () -> Void

    @State private var dragStart: CGPoint?
    @State private var scaleStart: CGFloat?

    var body: some View {
        // A gentle wiggle, twice per loop.
        let wiggle = sin(phase * 4 * .pi + sticker.tilt) * 6
        Text(verbatim: sticker.emoji)
            .font(.system(size: 52 * sticker.scale))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            .rotationEffect(.degrees(sticker.tilt + wiggle))
            // Before position: after it, the view is card-sized and the gestures miss.
            .contentShape(Rectangle())
            .onTapGesture(perform: onRemove)
            .gesture(drag.simultaneously(with: pinch), including: editScale == nil ? .none : .all)
            .allowsHitTesting(editScale != nil)
            .position(x: sticker.position.x * ShareCard.size.width, y: sticker.position.y * ShareCard.size.height)
            .accessibilityLabel("Sticker \(sticker.emoji)")
            .accessibilityAction(named: "Remove", onRemove)
    }

    /// Global coordinates, divided by the preview scale: the card is drawn scaled down in the studio.
    private var drag: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let scale = editScale ?? 1
                let start = dragStart ?? sticker.position
                dragStart = start
                let x = start.x + value.translation.width / scale / ShareCard.size.width
                let y = start.y + value.translation.height / scale / ShareCard.size.height
                sticker.position = CGPoint(x: min(max(x, 0.05), 0.95), y: min(max(y, 0.05), 0.95))
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = scaleStart ?? sticker.scale
                scaleStart = start
                sticker.scale = min(max(start * value.magnification, 0.5), 3)
            }
            .onEnded { _ in scaleStart = nil }
    }
}

// MARK: - Studio

/// The share card editor: a live preview, a tray of looks and stickers, and
/// Share as a photo or a 4-second looping video. The last look is remembered.
struct ShareCardStudio: View {
    let content: ShareCardContent

    @AppStorage("shareCard.background") private var backgroundRaw = ShareCardBackground.glow.rawValue
    @AppStorage("shareCard.frame") private var frameRaw = ShareCardFrame.polaroid.rawValue
    @AppStorage("shareCard.text") private var textRaw = ShareCardText.paper.rawValue
    @AppStorage("shareCard.palette") private var palette = 0
    @AppStorage("shareCard.timestamp") private var showsTimestamp = true
    @AppStorage("shareCard.code") private var showsCode = false
    @AppStorage("shareCard.video") private var exportsVideo = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stickers: [ShareCardSticker] = []
    @State private var diceTrigger = 0
    @State private var exportProgress: Double?
    @State private var exportFailed = false

    static let stickerChoices = ["🐾", "✨", "🎧", "🌙", "💖", "🔥", "🐶", "🐺", "⭐️", "🎤"]

    private var style: ShareCardStyle {
        ShareCardStyle(
            background: ShareCardBackground(rawValue: backgroundRaw) ?? .glow,
            frame: ShareCardFrame(rawValue: frameRaw) ?? .polaroid,
            text: ShareCardText(rawValue: textRaw) ?? .paper,
            palette: palette,
            showsTimestamp: showsTimestamp,
            showsCode: showsCode
        )
    }

    private var hasTimestamp: Bool { content.startTime != nil }

    private var code: UIImage? {
        guard showsCode, let link = content.link(atLine: showsTimestamp) else { return nil }
        return ShareCard.qrCode(for: link)
    }

    var body: some View {
        let code = code
        VStack(spacing: 14) {
            preview(code: code)
            tray
            shareRow(code: code)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Shuffle", systemImage: "dice", action: shuffle)
                    .accessibilityHint("Picks a random look. Shaking the iPhone does the same.")
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: diceTrigger)
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in shuffle() }
        .alert("Couldn't make the video", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again, or share the card as a photo.")
        }
    }

    // MARK: Preview

    private func preview(code: UIImage?) -> some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / ShareCard.size.width, proxy.size.height / ShareCard.size.height)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || exportProgress != nil)) { context in
                let phase = reduceMotion ? 0.3 : Self.phase(at: context.date)
                ShareCard(content: content, style: style, stickers: $stickers, phase: phase, code: code, editScale: scale)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: ShareCard.size.width * scale, height: ShareCard.size.height * scale, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            // A bounce for each shuffle.
            .keyframeAnimator(initialValue: CGFloat(1), trigger: diceTrigger) { content, bounce in
                content.scaleEffect(reduceMotion ? 1 : bounce)
            } keyframes: { _ in
                CubicKeyframe(CGFloat(0.94), duration: 0.08)
                SpringKeyframe(CGFloat(1), duration: 0.35, spring: .bouncy)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Card preview. Drag stickers to move them, pinch to resize, tap to remove.")
    }

    /// One loop of the moving parts lasts as long as the video.
    static func phase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: ShareCardVideo.seconds) / ShareCardVideo.seconds
    }

    // MARK: Tray

    private var tray: some View {
        VStack(alignment: .leading, spacing: 10) {
            chipRow("Background", options: ShareCardBackground.allCases, selected: $backgroundRaw)
            chipRow("Frame", options: ShareCardFrame.allCases, selected: $frameRaw)
            if !content.lines.isEmpty {
                chipRow("Text", options: ShareCardText.allCases, selected: $textRaw)
            }
            HStack(alignment: .bottom, spacing: 16) {
                group("Colours") {
                    HStack(spacing: 8) {
                        ForEach(0..<ShareCardContent.paletteCount, id: \.self) { index in
                            paletteSwatch(index)
                        }
                    }
                }
                group("Stickers") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            if !stickers.isEmpty {
                                Button {
                                    withAnimation(.spring(duration: 0.3)) { stickers.removeAll() }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.red)
                                        .frame(width: 36, height: 36)
                                        .background(.quaternary, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove all stickers")
                                .transition(.scale.combined(with: .opacity))
                            }
                            ForEach(Self.stickerChoices, id: \.self) { emoji in
                                Button { addSticker(emoji) } label: {
                                    Text(verbatim: emoji)
                                        .font(.title3)
                                        .frame(width: 36, height: 36)
                                        .background(.quaternary, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Add \(emoji) sticker")
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if hasTimestamp {
                    toggleChip("Time", systemImage: "play.circle", isOn: $showsTimestamp)
                }
                toggleChip("QR Code", systemImage: "qrcode", isOn: $showsCode)
                Spacer(minLength: 0)
                Picker("Format", selection: $exportsVideo) {
                    Text("Photo").tag(false)
                    Text("Video").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chipRow<Option: ShareCardOption>(
        _ title: String, options: [Option], selected: Binding<String>
    ) -> some View {
        group(title) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options) { option in
                        chip(option.title, isSelected: selected.wrappedValue == option.rawValue) {
                            selected.wrappedValue = option.rawValue
                        }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggleChip(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
                .background(isOn.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func paletteSwatch(_ index: Int) -> some View {
        let colors = content.palette(index)
        return Button { palette = index } label: {
            Circle()
                .fill(LinearGradient(colors: [colors[1], colors[0]], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 30)
                .overlay {
                    Circle().strokeBorder(palette == index ? Color.primary : Color.clear, lineWidth: 2)
                        .padding(-3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colours \(index + 1)")
        .accessibilityAddTraits(palette == index ? .isSelected : [])
    }

    // MARK: Share

    private func shareRow(code: UIImage?) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await share(code: code) }
            } label: {
                Group {
                    if let exportProgress {
                        ProgressView(value: exportProgress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(.horizontal, 20)
                    } else {
                        Label(exportsVideo ? "Share Video" : "Share", systemImage: "square.and.arrow.up")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(exportProgress != nil)

            if let link = content.link(atLine: showsTimestamp) {
                Button {
                    presentShareSheet(items: [link])
                } label: {
                    Image(systemName: "link")
                        .font(.headline)
                        .frame(width: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Share Link Only")
            }
        }
    }

    private func share(code: UIImage?) async {
        let link = content.link(atLine: showsTimestamp)
        if exportsVideo {
            exportProgress = 0
            defer { exportProgress = nil }
            do {
                let url = try await ShareCardVideo.export(content: content, style: style, stickers: stickers, code: code) { progress in
                    exportProgress = progress
                }
                presentShareSheet(items: [url])
            } catch {
                Log.player.error("SHARE_CARD video export failed: \(error)")
                exportFailed = true
            }
        } else if let image = ShareCard.render(content: content, style: style, stickers: stickers, code: code) {
            // The link rides along as the message.
            presentShareSheet(items: [UIImage(cgImage: image)] + (link.map { [$0.absoluteString] } ?? []))
        }
    }

    // MARK: Actions

    private func addSticker(_ emoji: String) {
        let spot = CGPoint(x: Double.random(in: 0.25...0.75), y: Double.random(in: 0.3...0.7))
        withAnimation(.spring(duration: 0.35, bounce: 0.4)) {
            stickers.append(ShareCardSticker(emoji: emoji, position: spot))
        }
    }

    /// A random look: background, frame, text style and colours.
    private func shuffle() {
        guard exportProgress == nil else { return }
        withAnimation(.smooth(duration: 0.3)) {
            backgroundRaw = ShareCardBackground.allCases.randomElement()?.rawValue ?? backgroundRaw
            frameRaw = ShareCardFrame.allCases.randomElement()?.rawValue ?? frameRaw
            textRaw = ShareCardText.allCases.randomElement()?.rawValue ?? textRaw
            palette = Int.random(in: 0..<ShareCardContent.paletteCount)
        }
        diceTrigger += 1
    }
}

// MARK: - Video

/// Writes the card as a looping H.264 video: `seconds` long, one loop of the
/// moving parts, so it repeats without a jump.
@MainActor
enum ShareCardVideo {
    static let seconds = 4.0
    static let framesPerSecond: Int32 = 24
    private static let pixelSize = CGSize(width: 1080, height: 1920)

    enum ExportError: Error { case setup, frame }

    static func export(
        content: ShareCardContent, style: ShareCardStyle, stickers: [ShareCardSticker], code: UIImage?,
        progress: (Double) -> Void
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Woof Music Card.mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(pixelSize.width),
            kCVPixelBufferHeightKey as String: Int(pixelSize.height)
        ])
        guard writer.canAdd(input) else { throw ExportError.setup }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.setup }
        writer.startSession(atSourceTime: .zero)

        let count = Int(seconds * Double(framesPerSecond))
        for frame in 0..<count {
            try Task.checkCancellation()
            let phase = Double(frame) / Double(count)
            guard let image = ShareCard.render(content: content, style: style, stickers: stickers, code: code, phase: phase) else {
                throw ExportError.frame
            }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let pool = adaptor.pixelBufferPool, let buffer = pixelBuffer(from: image, pool: pool) else {
                throw ExportError.frame
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond))
            progress(Double(frame + 1) / Double(count))
            // Lets the progress bar draw between frames.
            await Task.yield()
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.setup }
        return url
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
        return buffer
    }
}

// MARK: - Shake

extension Notification.Name {
    /// Posted when the iPhone is shaken; the share card studio shuffles its look.
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
