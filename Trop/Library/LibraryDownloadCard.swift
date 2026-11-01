//
//  LibraryDownloadCard.swift
//  Trop
//

import SwiftUI

/// Follows a download of several songs under Library's shortcut tiles. It stays
/// after the last song until it's tapped or closed, so the result isn't missed
/// on another tab. Observes DownloadManager on its own, so progress doesn't
/// redraw the whole Library.
struct LibraryDownloadCard: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(SettingsStore.self) private var settings

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    init() {}

    var body: some View {
        if let batch = downloadManager.batchProgress {
            Button {
                if batch.isDone { downloadManager.clearFinishedBatch() }
                AppRouter.shared.libraryPath.append(DetailRoute.downloads)
            } label: {
                content(batch)
            }
            .buttonStyle(ZoomPressStyle(scale: 0.98))
            .accessibilityHint("Opens Downloads")
            .overlay(alignment: .trailing) {
                if batch.isDone { closeButton }
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.bottom, DesignTokens.sectionGap)
            .transition(.opacity)
        }
    }

    private func content(_ batch: DownloadManager.BatchProgress) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(batch))
                .font(.title3.weight(.semibold))
                .foregroundStyle(batch.failed > 0 && batch.isDone ? Color.orange : settings.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .glyphMotion(batch.isDone ? .downloadDone : .arrowDrop, trigger: batch.isDone, playsOnAppear: !batch.isDone)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title(batch))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail(batch))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            if !batch.isDone {
                Text("\(Int(batch.fraction * 100))%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(settings.accentColor)
            }
        }
        .padding(12)
        // Room for the close button once it's done.
        .padding(.trailing, batch.isDone ? 28 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { progressFill(batch) }
        .background(Color(.secondarySystemBackground))
        .clipShape(shape)
        .contentShape(shape)
    }

    /// The song rows' download look: a tinted fill growing with a solid bar under it.
    private func progressFill(_ batch: DownloadManager.BatchProgress) -> some View {
        GeometryReader { geo in
            if !batch.isDone {
                let width = geo.size.width * CGFloat(batch.fraction)
                ZStack(alignment: .bottomLeading) {
                    settings.accentColor.opacity(0.18)
                        .frame(width: width)
                    settings.accentColor
                        .frame(width: width, height: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: batch.fraction)
    }

    private var closeButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) { downloadManager.clearFinishedBatch() }
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(IconPressStyle(motion: .deflate))
        .accessibilityLabel("Close")
    }

    private func symbol(_ batch: DownloadManager.BatchProgress) -> String {
        guard batch.isDone else { return "arrow.down.to.line" }
        return batch.failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    private func title(_ batch: DownloadManager.BatchProgress) -> String {
        guard batch.isDone else { return "Downloading \(batch.total) songs" }
        return batch.failed > 0
            ? "\(batch.completed) of \(batch.total) songs downloaded"
            : "\(batch.total) songs downloaded"
    }

    private func detail(_ batch: DownloadManager.BatchProgress) -> String {
        guard batch.isDone else { return "\(batch.completed + batch.failed) of \(batch.total) done" }
        guard batch.failed > 0 else { return "Ready to play offline" }
        return batch.failureReason.map { "\(batch.failed) failed. \($0)" } ?? "\(batch.failed) failed."
    }
}
