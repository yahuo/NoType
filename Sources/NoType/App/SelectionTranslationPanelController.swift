import AppKit
import SwiftUI

@MainActor
final class SelectionTranslationPanelController: NSObject, NSWindowDelegate {
    private let model: SelectionTranslationModel
    private var panel: NSPanel?

    init(model: SelectionTranslationModel) {
        self.model = model
    }

    func show() {
        panel?.orderOut(nil)
        model.start { [weak self] in
            self?.present()
        }
    }

    func close() {
        model.cancel()
        panel?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    private func present() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "NoType · 选词翻译"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 360, height: 260)
            panel.delegate = self
            self.panel = panel
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: SelectionTranslationView(model: model) { [weak self] in
            self?.close()
        })
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let screen {
            let visibleFrame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - panel.frame.width / 2,
                y: visibleFrame.midY - panel.frame.height / 2
            ))
        }
        panel.orderFrontRegardless()
    }
}
