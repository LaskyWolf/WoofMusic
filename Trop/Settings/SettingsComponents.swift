//
//  SettingsComponents.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct SettingsNavigationRow<Destination: View>: View {
    @Environment(SettingsStore.self) private var settings
    let title: String
    let icon: String
    @ViewBuilder var destination: () -> Destination

    init(_ title: String, icon: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.icon = icon
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: icon)
        }
        .tint(settings.accentColor)
    }
}

struct SettingsToggleRow: View {
    @Environment(SettingsStore.self) private var settings
    let title: String
    let icon: String?
    @Binding var isOn: Bool

    init(_ title: String, icon: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
        .tint(settings.accentColor)
    }
}

struct SettingsPickerRow<T: SettingsOption>: View {
    @Environment(SettingsStore.self) private var settings
    let title: String
    let icon: String?
    @Binding var selection: T

    init(_ title: String, icon: String? = nil, selection: Binding<T>) {
        self.title = title
        self.icon = icon
        self._selection = selection
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(Array(T.allCases)) { option in
                Text(option.displayName).tag(option)
            }
        } label: {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
        .id(settings.accentName)
        .tint(settings.accentColor)
    }
}
