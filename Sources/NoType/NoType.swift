import AppKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class NoTypeAppDelegate: NSObject, NSApplicationDelegate {
    static var launchHandler: (() -> Void)?
    static var reopenHandler: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore().load()
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        Self.launchHandler?()
        if ASRDiagnosticsCommand.shouldRun {
            Task { @MainActor in
                let code = await ASRDiagnosticsCommand.run()
                exit(code)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        Self.reopenHandler?()
        return false
    }
}

@main
struct NoTypeApp: App {
    @NSApplicationDelegateAdaptor(NoTypeAppDelegate.self) private var appDelegate
    @StateObject private var model: NoTypeAppModel

    private let modelContainer: ModelContainer
    private let settingsWindowController: SettingsWindowController

    init() {
        do {
            let configuration = ModelConfiguration(url: try Self.storeURL())
            let container = try ModelContainer(
                for: DictationSessionRecord.self,
                configurations: configuration
            )
            modelContainer = container
            let model = NoTypeAppModel(modelContainer: container)
            let settingsWindowController = SettingsWindowController(model: model)
            _model = StateObject(wrappedValue: model)
            self.settingsWindowController = settingsWindowController
            NoTypeAppDelegate.launchHandler = {
                model.bootstrap()
            }
            NoTypeAppDelegate.reopenHandler = {
                settingsWindowController.show()
            }
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra("NoType", systemImage: model.menuBarSymbolName) {
            MenuBarContentView(model: model, openSettings: {
                settingsWindowController.show()
            })
        }
        .menuBarExtraStyle(.window)
        .modelContainer(modelContainer)

        Window("Setup", id: "onboarding") {
            OnboardingView(model: model)
        }
        .defaultSize(width: 500, height: 340)
        .modelContainer(modelContainer)

        Window("History", id: "history") {
            HistoryWindowView()
        }
        .defaultSize(width: 760, height: 520)
        .modelContainer(modelContainer)
    }

    private static func storeURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("NoType", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("notype.store")
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
        elevateAppForWindowPresentationIfNeeded()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView(model: model)
                .frame(width: 600, height: 560)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.setContentSize(NSSize(width: 600, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.delegate = self

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
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
