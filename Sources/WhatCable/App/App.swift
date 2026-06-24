import SwiftUI
import AppKit
import Combine
import os.log
import WhatCableCore
import WhatCableDarwinBackend
import WhatCableAppKit
import WhatCablePlugins

// Launch diagnostics use `.notice`, not `.info`, on purpose. `log stream`
// and `log show` hide info/debug unless you pass `--level info`, so the
// simple command we hand non-technical users (issue #221) would show
// nothing. `.notice` is the lowest level a plain `log` command displays.
private let log = Logger(subsystem: "uk.whatcable.whatcable", category: "lifecycle")

@main
struct WhatCableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        bootstrapPlugins(registry: .shared)
    }

    var body: some Scene {
        // Headless - UI is owned by AppDelegate (status item + popover, or
        // a regular window, depending on AppSettings.useMenuBarMode).
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button(String(localized: "About \(AppInfo.name)", bundle: _appLocalizedBundle)) {
                        delegate.showAboutPanel()
                    }
                }
                CommandGroup(after: .appInfo) {
                    Button(String(localized: "Check for Updates…", bundle: _appLocalizedBundle)) {
                        UpdateChecker.shared.check(silent: false)
                    }
                }
                CommandGroup(after: .windowSize) {
                    let items = PluginRegistry.shared.menuItems[.afterWindowSize] ?? []
                    ForEach(items) { item in
                        Button(item.title) { item.action() }
                    }
                }
                CommandGroup(after: .toolbar) {
                    Button(String(localized: "Refresh", bundle: _appLocalizedBundle)) {
                        delegate.menuRefresh()
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
                CommandGroup(replacing: .help) {
                    Button(String(localized: "WhatCable on GitHub", bundle: _appLocalizedBundle)) {
                        NSWorkspace.shared.open(AppInfo.helpURL)
                    }
                }
                CommandGroup(replacing: .appSettings) {
                    Button(String(localized: "Settings…", bundle: _appLocalizedBundle)) {
                        delegate.showSettingsPanel(nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    let settingsItems = PluginRegistry.shared.menuItems[.appSettingsArea] ?? []
                    ForEach(settingsItems) { item in
                        Button(item.title) { item.action() }
                    }
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    static let refreshSignal = RefreshSignal.shared

    // Menu bar mode
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    // Window mode
    private var window: NSWindow?

    // Onboarding
    private var welcomeWindow: NSWindow?
    private var onboardingMenuBarChoice = true

    private var cancellables: Set<AnyCancellable> = []

    /// The last rounded-watts value we painted onto the status item title, so
    /// we can skip the expensive layout pass when the value hasn't changed.
    private var lastShownWatts: Int? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.notice("launch: version=\(AppInfo.version, privacy: .public) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
        registerWidgetExtension()
        NSWindow.allowsAutomaticWindowTabbing = false

        ProcessInfo.processInfo.setValue(AppInfo.name, forKey: "processName")

        WatcherHub.shared.start()
        NotificationManager.shared.start()
        WidgetDataWriter.shared.start()
        UpdateChecker.shared.start()
        log.notice("launch: subsystems started")

        // Run launch hooks here, after all singletons have been started.
        // Hooks registered by plugins may call into NotificationManager,
        // WidgetDataWriter, UpdateChecker, or WatcherHub; running them in
        // App.init() (before applicationDidFinishLaunching) meant those
        // singletons were still in their private init and not yet started.
        let launchHooks = PluginRegistry.shared.launchHooks
        if !launchHooks.isEmpty {
            Task { @MainActor in
                for hook in launchHooks { await hook() }
            }
        }

        if AppSettings.shared.needsOnboarding {
            showWelcomeWindow()
        } else {
            applyDisplayMode(menuBar: AppSettings.shared.useMenuBarMode)
            log.notice("launch: display mode applied, menuBar=\(AppSettings.shared.useMenuBarMode)")
        }

        // Live-switch when the user flips the toggle in Settings.
        AppSettings.shared.$useMenuBarMode
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] menuBar in
                self?.applyDisplayMode(menuBar: menuBar)
            }
            .store(in: &cancellables)

        // Live-swap the menu bar glyph when the user picks a new one.
        AppSettings.shared.$menuBarIcon
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] symbolName in
                self?.updateMenuBarIcon(symbolName)
            }
            .store(in: &cancellables)

        // Repaint the watts label whenever the watcher publishes a new value.
        // The watcher recomputes on WatcherHub's existing poll cadence (1 Hz
        // visible, 30 s idle) and only publishes on change, so there's no
        // separate per-second timer and no IOKit read in the app target.
        WatcherHub.shared.powerWatcher.$chargerInputWatts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarWatts()
            }
            .store(in: &cancellables)

        AppSettings.shared.$showChargingWatts
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.lastShownWatts = nil  // force a repaint on toggle
                // Turn the watcher's charger-in read on/off with the toggle.
                self.syncChargerWattsReading()
                self.updateMenuBarWatts()
            }
            .store(in: &cancellables)

        // Pin toggle: the menu item and the in-app button both write
        // RefreshSignal.keepOpen; this applies it to the live popover.
        Self.refreshSignal.$keepOpen
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keepOpen in
                self?.popover?.behavior = keepOpen ? .applicationDefined : .transient
            }
            .store(in: &cancellables)

        // A plugin (header button or status-menu item) sets a Pro-screen
        // route; bring the surface forward so the user sees it. The route
        // itself is rendered by ContentView. Nil (Back) needs no action.
        Self.refreshSignal.$activeProScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] route in
                guard route != nil else { return }
                self?.presentMainSurface()
            }
            .store(in: &cancellables)
    }

    /// Bring the single content surface forward (popover in menu-bar
    /// mode, window in desktop mode) without changing any navigation
    /// state. Used when navigation is triggered from outside the popover.
    private func presentMainSurface() {
        NSApp.activate()
        if AppSettings.shared.useMenuBarMode {
            if let button = statusItem?.button, let popover, !popover.isShown {
                togglePopover(from: button)
            }
        } else if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            setUpWindowMode()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TestKitRunner.shared.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // In window mode, closing the window quits the app. In menu bar mode
        // there's no window to close, so this is harmless either way.
        !AppSettings.shared.useMenuBarMode
    }

    // MARK: - Onboarding

    private func showWelcomeWindow() {
        NSApp.setActivationPolicy(.regular)
        let host = NSHostingController(
            rootView: ScaledHost {
                WelcomeView(
                    onSelectionChanged: { [weak self] useMenuBar in
                        self?.onboardingMenuBarChoice = useMenuBar
                    },
                    onComplete: { [weak self] useMenuBar in
                        self?.completeOnboarding(useMenuBar: useMenuBar)
                    }
                )
            }
        )
        let w = NSWindow(contentViewController: host)
        w.title = AppInfo.name
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        let scale = AppSettings.shared.fontSize
        w.setContentSize(NSSize(width: 420 * scale, height: 480 * scale))
        w.center()
        welcomeWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        log.notice("launch: showing onboarding window")
    }

    private func completeOnboarding(useMenuBar: Bool) {
        guard let w = welcomeWindow else { return }
        welcomeWindow = nil
        AppSettings.shared.hasCompletedOnboarding = true
        AppSettings.shared.useMenuBarMode = useMenuBar
        applyDisplayMode(menuBar: useMenuBar)
        log.notice("launch: onboarding complete, menuBar=\(useMenuBar)")
        DispatchQueue.main.async { w.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === welcomeWindow {
            completeOnboarding(useMenuBar: onboardingMenuBarChoice)
            return false
        }
        return true
    }

    /// Track window-mode visibility for the poll cadence. macOS sets
    /// `.visible` when any part of the window is on screen and clears it when
    /// the window is miniaturised or fully covered, so this follows real
    /// visibility, not just key focus. Only the main content window matters;
    /// the transient welcome window is ignored.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        WatcherHub.shared.setUIVisible(changed.occlusionState.contains(.visible))
    }

    // MARK: - Display mode

    private func applyDisplayMode(menuBar: Bool) {
        if menuBar {
            tearDownWindowMode()
            setUpMenuBarMode()
            NSApp.setActivationPolicy(.accessory)
        } else {
            tearDownMenuBarMode()
            NSApp.setActivationPolicy(.regular)
            setUpWindowMode()
            NSApp.activate()
        }
    }

    private func setUpMenuBarMode() {
        if popover == nil {
            let p = NSPopover()
            p.behavior = Self.refreshSignal.keepOpen ? .applicationDefined : .transient
            p.animates = true
            let host = NSHostingController(
                rootView: ScaledHost {
                    ContentView().environmentObject(Self.refreshSignal)
                }
            )
            host.sizingOptions = [.preferredContentSize]
            p.contentViewController = host
            p.delegate = self
            popover = p
            log.notice("menuBar: popover created")
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                applyMenuBarIcon(to: button, symbolName: AppSettings.shared.menuBarIcon)
                button.target = self
                button.action = #selector(handleClick(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                log.notice("menuBar: statusItem button configured, hasImage=\(button.image != nil), frame=\(button.frame.debugDescription, privacy: .public)")
            } else {
                log.error("menuBar: statusItem.button is nil, removing broken item")
                NSStatusBar.system.removeStatusItem(item)
                return
            }
            statusItem = item
            log.notice("menuBar: statusItem created, isVisible=\(item.isVisible)")
        }
        // Turn on the watcher's charger-in read if the toggle is already on, then
        // paint the initial label from whatever it has published.
        syncChargerWattsReading()
        updateMenuBarWatts()
    }

    /// Tell the shared power watcher whether to compute the live charger-in
    /// wattage. Only needed while the readout is enabled AND we're in menu-bar
    /// mode (the only place the label shows); off the rest of the time so no
    /// SMC / battery read runs. The watcher computes on WatcherHub's existing
    /// poll cadence, so there is no separate per-second timer here.
    private func syncChargerWattsReading() {
        WatcherHub.shared.powerWatcher.readsChargerInputWatts =
            AppSettings.shared.showChargingWatts && statusItem != nil
    }

    /// Set the status-item glyph, falling back to a short text label if the
    /// SF Symbol is unavailable on this macOS (keeps the menu bar usable).
    ///
    /// A fixed SymbolConfiguration pins every glyph to 16pt regular so the
    /// button width stays constant regardless of which symbol is chosen.
    /// Without it, symbols with different intrinsic sizes shift the button
    /// bounds mid-session and misalign the popover anchor (issue #313).
    private func applyMenuBarIcon(to button: NSStatusBarButton, symbolName: String) {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: AppInfo.name)
        if let image {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            let sizedImage = image.withSymbolConfiguration(config) ?? image
            sizedImage.isTemplate = true
            button.image = sizedImage
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            log.warning("menuBar: SF Symbol \(symbolName, privacy: .public) returned nil, using text fallback")
            button.image = nil
            button.imagePosition = .noImage
            button.title = "WC"
        }
        button.needsLayout = true
        button.needsDisplay = true
        button.layoutSubtreeIfNeeded()
    }

    /// Swap the live menu bar glyph when the user picks a new one in Settings.
    ///
    /// The anchor only drifts when the button geometry changes. Reseating the
    /// popover (close + reopen) causes a visible blink, so it is done only
    /// when the button width actually changes after the swap. When the
    /// SymbolConfiguration size-pinning keeps the width stable (the common
    /// case), the popover is left alone.
    private func updateMenuBarIcon(_ symbolName: String) {
        guard let button = statusItem?.button else { return }
        let widthBefore = button.frame.width
        applyMenuBarIcon(to: button, symbolName: symbolName)
        reseatPopoverAfterWidthChange(button: button, widthBefore: widthBefore)
    }

    /// Re-anchor the popover after the status-item button changed width, so its
    /// arrow stays centred on the button. This works by closing and reopening,
    /// so it must never run while the popover is pinned (`keepOpen`): that close
    /// would dismiss a popover the user deliberately kept open. With the live
    /// watts label on, the label changes width as the number changes (e.g.
    /// 9W -> 10W), so without this guard a pinned popover snapped shut whenever
    /// the wattage ticked over. When pinned we accept a slightly off-centre
    /// arrow rather than shutting the window.
    private func reseatPopoverAfterWidthChange(button: NSStatusBarButton, widthBefore: CGFloat) {
        guard !Self.refreshSignal.keepOpen else { return }
        guard button.frame.width != widthBefore, let popover, popover.isShown else { return }
        popover.performClose(nil)
        togglePopover(from: button)
    }

    /// Paint the status-item title from the watcher's published charger-in watts.
    ///
    /// Called when the watcher publishes a new value, when the toggle changes,
    /// and on menu-bar setup. Only repaints when the rounded value actually
    /// changes, to avoid layout churn. When the toggle is off, or on battery, or
    /// watts are 0/unavailable, hides the title and restores the icon-only layout.
    ///
    /// The IOKit read itself lives in the watcher and only runs while the readout
    /// is on, so users who have the feature off (the default) pay no read cost.
    private func updateMenuBarWatts() {
        guard let button = statusItem?.button else { return }
        guard AppSettings.shared.useMenuBarMode else { return }

        // Nothing to show when the toggle is off (the default state).
        guard AppSettings.shared.showChargingWatts else {
            // Guard on whether the label is actually displayed, not the cache.
            // The sink nils lastShownWatts before calling here, so the old
            // `guard lastShownWatts != nil` check would always bail out early
            // and leave the stale "NNW" text in the menu bar until restart.
            guard !button.attributedTitle.string.isEmpty else { return }
            clearWattsLabel(on: button)
            return
        }

        let watts = WatcherHub.shared.powerWatcher.chargerInputWatts
        let shouldShow = watts > 0

        if shouldShow {
            guard watts != lastShownWatts else { return }
            lastShownWatts = watts
            // Reserve a constant width so the menu bar item doesn't resize (and
            // the popover doesn't drift) when the value crosses 9 -> 10. U+2007
            // is the FIGURE SPACE: in a monospaced-digit font it is exactly one
            // digit wide, so a padded single digit lines up with a double digit.
            let digits = String(watts)
            let padded = digits.count < 2
                ? String(repeating: "\u{2007}", count: 2 - digits.count) + digits
                : digits
            let label = "\(padded)W"
            let widthBefore = button.frame.width
            let attr = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                ]
            )
            button.attributedTitle = attr
            button.imagePosition = .imageLeft
            reseatPopoverAfterWidthChange(button: button, widthBefore: widthBefore)
        } else {
            // Guard on actual displayed state, not the cache, for the same
            // reason as the toggle-off branch above.
            guard !button.attributedTitle.string.isEmpty else { return }
            clearWattsLabel(on: button)
        }
    }

    /// Clears the watts label from the status bar button and restores the
    /// icon-only layout. Reseats the popover if the button width changes
    /// (Settings renders inside the popover; an unconditional reseat would
    /// blink it unnecessarily).
    private func clearWattsLabel(on button: NSStatusBarButton) {
        lastShownWatts = nil
        let widthBefore = button.frame.width
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        button.imagePosition = .imageOnly
        reseatPopoverAfterWidthChange(button: button, widthBefore: widthBefore)
    }

    private func tearDownMenuBarMode() {
        // Leaving menu-bar mode: stop the watcher reading charger-in watts.
        WatcherHub.shared.powerWatcher.readsChargerInputWatts = false
        if let popover, popover.isShown { popover.performClose(nil) }
        popover = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        lastShownWatts = nil
    }

    private func setUpWindowMode() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            WatcherHub.shared.setUIVisible(true)
            return
        }
        let host = NSHostingController(
            rootView: ScaledHost {
                ContentView().environmentObject(Self.refreshSignal)
            }
        )
        let w = NSWindow(contentViewController: host)
        w.title = AppInfo.name
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 760, height: 540))
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        // Window is on screen: poll at the live cadence. Occlusion changes
        // (miniaturise, fully covered) flip this back via the delegate below.
        WatcherHub.shared.setUIVisible(true)
    }

    private func tearDownWindowMode() {
        window?.delegate = nil
        window?.close()
        window = nil
        // No surface left in window mode: drop to the idle poll cadence.
        WatcherHub.shared.setUIVisible(false)
    }

    // MARK: - Status item handling (menu bar mode)

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu(from: sender)
        } else {
            // ⌥-click momentarily reveals the technical-details view,
            // matching the macOS convention used by Wi-Fi / Volume /
            // Bluetooth menus. The flag is cleared when the popover closes
            // (see popoverDidClose), so the persistent preference in
            // AppSettings is what survives across opens.
            Self.refreshSignal.optionHeld = event.modifierFlags.contains(.option)
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            Self.refreshSignal.bump()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(.init(title: String(localized: "Refresh", bundle: _appLocalizedBundle), action: #selector(menuRefresh), keyEquivalent: "r"))
        let pinItem = NSMenuItem(title: String(localized: "Keep window open", bundle: _appLocalizedBundle), action: #selector(menuTogglePin), keyEquivalent: "p")
        pinItem.state = Self.refreshSignal.keepOpen ? .on : .off
        menu.addItem(pinItem)
        menu.addItem(.separator())
        menu.addItem(.init(title: String(localized: "Settings…", bundle: _appLocalizedBundle), action: #selector(menuSettings), keyEquivalent: ","))
        for builder in PluginRegistry.shared.nsMenuItemBuilders[.statusItemMenu] ?? [] {
            menu.addItem(builder())
        }
        menu.addItem(.init(title: String(localized: "Check for Updates…", bundle: _appLocalizedBundle), action: #selector(menuCheckUpdates), keyEquivalent: ""))
        let testKitItem = NSMenuItem(
            title: String(localized: "Contribute Diagnostic Data…", bundle: _appLocalizedBundle),
            action: #selector(menuRunTestKit),
            keyEquivalent: ""
        )
        if TestKitRunner.shared.isRunning {
            testKitItem.isEnabled = false
        }
        menu.addItem(testKitItem)
        menu.addItem(.separator())
        menu.addItem(.init(title: String(localized: "About \(AppInfo.name)", bundle: _appLocalizedBundle), action: #selector(showAboutPanel), keyEquivalent: ""))
        menu.addItem(.init(title: String(localized: "WhatCable on GitHub", bundle: _appLocalizedBundle), action: #selector(menuHelp), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(.init(title: String(localized: "Quit \(AppInfo.name)", bundle: _appLocalizedBundle), action: #selector(menuQuit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuTogglePin() {
        // The $keepOpen sink applies this to the live popover.
        Self.refreshSignal.keepOpen.toggle()
    }

    @objc func menuRefresh() {
        Self.refreshSignal.bump()
    }

    @objc private func menuSettings() {
        showSettings()
    }

    @objc func showSettingsPanel(_ sender: Any?) {
        showSettings()
    }


    private func showSettings() {
        NSApp.activate()
        Self.refreshSignal.showSettings = true
        if AppSettings.shared.useMenuBarMode {
            if let button = statusItem?.button, let popover, !popover.isShown {
                togglePopover(from: button)
            }
        } else {
            if let window {
                window.makeKeyAndOrderFront(nil)
            } else {
                setUpWindowMode()
            }
        }
    }

    @objc func showAboutPanel() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "\(AppInfo.tagline)\n\n\(AppInfo.credit)",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: "",
            .credits: credits,
            .init(rawValue: "Copyright"): AppInfo.copyright
        ])
    }


    @objc private func menuRunTestKit() {
        showSettings()
        Self.refreshSignal.showTestKitConsent = true
    }

    @objc private func menuCheckUpdates() {
        UpdateChecker.shared.check(silent: false)
    }

    @objc private func menuHelp() {
        NSWorkspace.shared.open(AppInfo.helpURL)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Widget extension registration

    /// Tell PluginKit about our widget extension on every launch.
    ///
    /// Launch Services can accumulate stale extension entries across app
    /// upgrades (especially Homebrew cask upgrades). When pkd sees multiple
    /// entries for the same bundle ID, its dedup logic can reject all of
    /// them, leaving "Final plugin count: 0" and no widget in the gallery.
    /// Explicitly adding the appex bypasses the stale-entry collision.
    private func registerWidgetExtension() {
        guard let appexURL = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("WhatCableWidget.appex") else { return }
        // Capture the path as a plain String before leaving the main actor.
        // pluginkit talks to the pkd daemon over XPC, which can be slow at
        // login or right after an upgrade. Running it synchronously here would
        // stall the launch. Task.detached (not Task) is required: a plain Task
        // started inside a @MainActor context still runs on the main thread,
        // which would not help. Detached runs on a background thread entirely
        // outside the main actor.
        let appexPath = appexURL.path
        Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            task.arguments = ["-a", appexPath]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    log.notice("launch: registered widget extension via pluginkit")
                } else {
                    log.warning("launch: pluginkit -a exited with status \(task.terminationStatus)")
                }
            } catch {
                log.warning("launch: pluginkit -a failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - NSPopoverDelegate

    nonisolated func popoverDidShow(_ notification: Notification) {
        // Popover is on screen: poll at the live cadence so readings tick.
        Task { @MainActor in WatcherHub.shared.setUIVisible(true) }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            // Drop to the idle cadence only if a menu-bar popover still exists.
            // This callback also fires when the popover is torn down to switch
            // into window mode: that close arrives late (after setUpWindowMode
            // has already marked the window visible), so treating it as
            // "nothing visible" would wrongly park window mode at the idle
            // cadence. By then tearDownMenuBarMode has set `popover` to nil, so
            // this guard skips it; a normal user-dismissed close leaves the
            // popover non-nil and correctly drops to idle.
            if self.popover != nil { WatcherHub.shared.setUIVisible(false) }
            Self.refreshSignal.optionHeld = false
            Self.refreshSignal.showSettings = false
            Self.refreshSignal.showTestKitConsent = false
        }
    }
}

