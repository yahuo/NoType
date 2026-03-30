import AppKit
import SwiftUI

@MainActor
final class HUDPanelController {
    private var panel: NSPanel?
    private let baseSize = NSSize(width: 356, height: 132)
    private let extendedSize = NSSize(width: 356, height: 176)

    func attach(to model: NoTypeAppModel) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: baseSize),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isFloatingPanel = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = NSHostingView(rootView: HUDPanelView(model: model))
            self.panel = panel
        }
    }

    func update(for model: NoTypeAppModel, animated: Bool) {
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: HUDPanelView(model: model))
        if model.phase.hudVisible {
            let size = model.phase == .failed ? extendedSize : baseSize
            panel.setContentSize(size)
            panel.setFrame(frame(for: size), display: true)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func frame(for size: NSSize) -> NSRect {
        let screen = currentScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            return NSRect(origin: .zero, size: size)
        }

        let visibleFrame = screen.visibleFrame
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 36,
            width: size.width,
            height: size.height
        )
    }

    private func currentScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
