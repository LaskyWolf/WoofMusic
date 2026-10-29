//
//  NowPlayingLiveActivity.swift
//  WoofWidgets
//

import ActivityKit
import SwiftUI
import WidgetKit

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenNowPlaying(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ArtworkView(state: state, size: 52, cornerRadius: 12)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PlaybackButtons(state: state)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.center) {
                    SongTitles(state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SongProgress(state: state)
                        .padding(.top, 4)
                }
            } compactLeading: {
                ArtworkView(state: state, size: 24, cornerRadius: 6)
            } compactTrailing: {
                Image(systemName: state.stateSymbol)
                    .foregroundStyle(state.tintColor)
            } minimal: {
                ArtworkView(state: state, size: 24, cornerRadius: 12)
            }
            .keylineTint(state.tintColor)
        }
    }
}

private struct LockScreenNowPlaying: View {
    let state: NowPlayingState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(state: state, size: 52, cornerRadius: 10)
                SongTitles(state: state)
                Spacer(minLength: 8)
                PlaybackButtons(state: state)
            }
            SongProgress(state: state)
        }
        .padding(16)
    }
}
