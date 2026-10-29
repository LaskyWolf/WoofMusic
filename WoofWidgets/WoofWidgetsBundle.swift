//
//  WoofWidgetsBundle.swift
//  WoofWidgets
//

import SwiftUI
import WidgetKit

@main
struct WoofWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TurntableWidget()
        QuickPicksWidget()
        StatsWidget()
    }
}
