//
//  DetailStateContainer.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Centered spinner + message placeholder used while content loads.
struct LoadingStateView: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

/// An error state with a button to try again.
struct RetryStateView: View {
    let title: String
    let systemImage: String
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await retry() } }
                .buttonStyle(.bordered)
        }
    }
}

/// The scrolling page with its loading / error / empty / content states,
/// shared by the detail screens.
/// `noun` derives the standard copy ("Loading album…", "Couldn't load album",
/// "No album data", "Could not parse album details").
struct DetailStateContainer<Data, Content: View>: View {
    var isLoading: Bool
    var error: Error?
    var data: Data?
    var noun: String
    var emptyIcon: String
    var retry: () async -> Void
    @ViewBuilder var content: (Data) -> Content

    var body: some View {
        ScrollView {
            if isLoading {
                LoadingStateView("Loading \(noun)...")
                    .containerRelativeFrame(.vertical)
            } else if let error = error {
                RetryStateView(
                    title: "Couldn't load \(noun)",
                    systemImage: "exclamationmark.circle",
                    message: error.localizedDescription,
                    retry: retry
                )
                .containerRelativeFrame(.vertical)
            } else if let data = data {
                content(data)
            } else {
                RetryStateView(
                    title: "No \(noun) data",
                    systemImage: emptyIcon,
                    message: "Could not parse \(noun) details",
                    retry: retry
                )
                .containerRelativeFrame(.vertical)
            }
        }
        .scrollDisabled(isLoading || error != nil || data == nil)
        .miniPlayerTracksScroll()
    }
}

/// The line a detail page shows when it has nothing to list.
struct DetailEmptyLabel: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
