//
//  MenuCard.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

import SwiftUI

/// Standard chrome for menu sheets: NavigationStack + padded card column on
/// the grouped background with medium/large detents and a drag indicator.
/// Content needing `navigationDestination` should wrap itself in a `Group`
/// carrying that modifier (it must live inside the NavigationStack).
struct SheetChrome<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    content
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Rounded grouped-background card stacking menu rows with no spacing.
struct MenuCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.sheetRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

/// Tappable menu row: accent icon + title + optional subtitle.
struct MenuRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuRowLabel(icon: icon, title: title, subtitle: subtitle, destructive: destructive)
        }
        .buttonStyle(.plain)
    }
}

/// The label half of `MenuRow`, for rows embedded in a `NavigationLink`.
struct MenuRowLabel: View {
    @Environment(\.settingsStore) private var settings

    let icon: String
    let title: String
    var subtitle: String?
    var destructive: Bool = false

    var body: some View {
        HStack(spacing: DesignTokens.menuRowSpacing) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(destructive ? Color.red : settings.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Metadata preview hosted inside a native grouped-list row.
struct MenuSongPreview: View {
    let title: String
    let artist: String
    let thumbnailURL: String?

    var body: some View {
        HStack(spacing: DesignTokens.rowSpacing) {
            AsyncImageView(url: thumbnailURL)
                .frame(width: DesignTokens.thumbMedium, height: DesignTokens.thumbMedium)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.thumbRadius))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.cardInnerSpacing) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DesignTokens.rowVPadding)
        .accessibilityElement(children: .combine)
    }
}

/// Independent buttons inside a list row need a borderless style so tapping
/// one shortcut does not activate the row's other buttons.
struct MenuShortcutButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @Environment(\.settingsStore) private var settings

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(settings.accentColor)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}
