import AppKit
import SwiftUI
import WhatCableAppKit

/// Settings panel shown in place of the main popover content. Pushes a
/// "Done" header and groups toggles by purpose. All preferences live on
/// `AppSettings` and are persisted to UserDefaults.
struct SettingsView: View {
    var dismiss: (() -> Void)? = nil

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            if let dismiss {
                header(dismiss: dismiss)
                Divider()
            }
            SettingsForm()
        }
        .frame(minWidth: 400, minHeight: 320, maxHeight: 640)
    }

    private func header(dismiss: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "gearshape")
                .scaledFont(.title2)
            Text(String(localized: "Settings", bundle: _appLocalizedBundle)).scaledFont(.headline, weight: .bold)
            Spacer()
            Button(String(localized: "Done", bundle: _appLocalizedBundle), action: dismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}

struct SettingsForm: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Launch at login", bundle: _appLocalizedBundle), isOn: $settings.launchAtLogin)
                Toggle(String(localized: "Show in menu bar", bundle: _appLocalizedBundle), isOn: $settings.useMenuBarMode)
            } header: {
                sectionHeader("Behavior")
            } footer: {
                Text(settings.useMenuBarMode
                     ? String(localized: "Lives in the menu bar with no Dock icon.", bundle: _appLocalizedBundle)
                     : String(localized: "Runs as a regular Dock app with a window.", bundle: _appLocalizedBundle))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "Show technical details", bundle: _appLocalizedBundle), isOn: $settings.showTechnicalDetails)
                Toggle(String(localized: "Hide empty ports", bundle: _appLocalizedBundle), isOn: $settings.hideEmptyPorts)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(localized: "Font size", bundle: _appLocalizedBundle))
                        Spacer()
                        Text(verbatim: "\(Int((settings.fontSize * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.fontSize, in: AppSettings.fontSizeRange, step: 0.1)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    MenuBarIconPicker(selection: $settings.menuBarIcon)
                } label: {
                    Text(String(localized: "Menu bar icon", bundle: _appLocalizedBundle))
                }

                Toggle(String(localized: "Show charging watts in the menu bar", bundle: _appLocalizedBundle), isOn: $settings.showChargingWatts)

                Picker(selection: $settings.preferredLanguage) {
                    Text(String(localized: "System Default", bundle: _appLocalizedBundle)).tag("")
                    Divider()
                    ForEach(AppLanguages.available) { language in
                        Text(verbatim: language.name).tag(language.id)
                    }
                } label: {
                    Text(String(localized: "Language", bundle: _appLocalizedBundle))
                }
                .pickerStyle(.menu)
            } header: {
                sectionHeader("Display")
            }

            Section {
                Toggle(String(localized: "Notify on cable changes", bundle: _appLocalizedBundle), isOn: $settings.notifyOnChanges)
            } header: {
                sectionHeader("Notifications")
            }

            Section {
                TestKitSettingsSection()
            } header: {
                sectionHeader("COMMUNITY")
            }

            Section {
                let builders = PluginRegistry.shared.settingsProSectionBuilders
                if builders.isEmpty {
                    Link(String(localized: "Upgrade to WhatCable Pro", bundle: _appLocalizedBundle),
                         destination: URL(string: "https://www.whatcable.uk/pro")!)
                } else {
                    ForEach(builders.indices, id: \.self) { i in
                        builders[i]()
                    }
                }
            } header: {
                sectionHeader("Pro")
            }
        }
        .formStyle(.grouped)
        .scaledFont(.body)
        .toggleStyle(.switch)
    }

    /// A section header in the small uppercase grey style, scaled with the
    /// font-size preference. `title` is an English key looked up in the app
    /// bundle, then uppercased (a no-op for non-Latin scripts).
    private func sectionHeader(_ title: String) -> some View {
        Text(String(localized: String.LocalizationValue(title), bundle: _appLocalizedBundle).uppercased())
            .scaledFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
    }
}

/// A row of selectable glyph buttons for choosing the menu bar icon. Shows
/// the actual SF Symbols so the choice is visual, and hides any symbol that
/// isn't available on this macOS.
struct MenuBarIconPicker: View {
    @Binding var selection: String

    private var availableIcons: [String] {
        AppSettings.menuBarIconChoices.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }

    /// Friendly, localised name for an SF Symbol, used for the tooltip and
    /// VoiceOver. Falls back to the raw symbol name for any future addition.
    private func label(for symbolName: String) -> String {
        switch symbolName {
        case "cable.connector":
            return String(localized: "Cable", bundle: _appLocalizedBundle)
        case "cable.connector.horizontal":
            return String(localized: "Cable, horizontal", bundle: _appLocalizedBundle)
        case "bolt.fill":
            return String(localized: "Bolt", bundle: _appLocalizedBundle)
        case "powerplug.fill":
            return String(localized: "Power plug", bundle: _appLocalizedBundle)
        case "powercord.fill":
            return String(localized: "Power cord", bundle: _appLocalizedBundle)
        default:
            return symbolName
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(availableIcons, id: \.self) { name in
                Button {
                    selection = name
                } label: {
                    Image(systemName: name)
                        .scaledFont(.body)
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == name ? Color.accentColor.opacity(0.25) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selection == name ? Color.accentColor : Color.secondary.opacity(0.3),
                                        lineWidth: selection == name ? 1.5 : 1)
                        )
                }
                .buttonStyle(.plain)
                .help(label(for: name))
                .accessibilityLabel(label(for: name))
                .accessibilityAddTraits(selection == name ? [.isSelected] : [])
            }
        }
    }
}
