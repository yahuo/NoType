import AppKit
import Foundation
import SwiftUI

@MainActor
final class NoTypeAppDelegate: NSObject, NSApplicationDelegate {
    static var launchHandler: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.launchHandler?()
    }
}

@main
struct NoTypeApp: App {
    @NSApplicationDelegateAdaptor(NoTypeAppDelegate.self) private var appDelegate
    @StateObject private var model: NoTypeAppModel

    private let settingsWindowController: SettingsWindowController

    init() {
        let model = NoTypeAppModel()
        _model = StateObject(wrappedValue: model)
        settingsWindowController = SettingsWindowController(model: model)
        NoTypeAppDelegate.launchHandler = {
            model.bootstrap()
        }
    }

    var body: some Scene {
        MenuBarExtra("NoType", systemImage: model.menuBarSymbolName) {
            MenuBarContentView(model: model) {
                settingsWindowController.show()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Setup", id: "onboarding") {
            OnboardingView(model: model)
        }
        .defaultSize(width: 520, height: 360)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: NoTypeAppModel
    private var window: NSWindow?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?

    init(model: NoTypeAppModel) {
        self.model = model
    }

    func show() {
        model.prepareSettings()
        elevateAppForWindowPresentationIfNeeded()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView(model: model)
                .frame(width: 620, height: 480)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.setContentSize(NSSize(width: 620, height: 480))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.delegate = self

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        restoreActivationPolicyIfNeeded()
        return false
    }

    private func elevateAppForWindowPresentationIfNeeded() {
        let currentPolicy = NSApp.activationPolicy()
        guard currentPolicy != .regular else { return }
        previousActivationPolicy = currentPolicy
        NSApp.setActivationPolicy(.regular)
    }

    private func restoreActivationPolicyIfNeeded() {
        guard let previousActivationPolicy else { return }
        NSApp.setActivationPolicy(previousActivationPolicy)
        self.previousActivationPolicy = nil
    }
}
