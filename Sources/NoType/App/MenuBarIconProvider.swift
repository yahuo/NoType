import AppKit

/// Generates template `NSImage`s for the menu bar status item.
enum MenuBarIconProvider {

    /// Idle — calm waveform.
    static let idle = makeWaveform(heights: [4, 7, 11, 7, 4])

    /// Recording — taller, active waveform.
    static let recording = makeWaveform(heights: [6, 10, 14, 10, 6])

    /// Transcribing / refining.
    static let transcribing = makeSystemSymbol("ellipsis.circle.fill")

    /// Successfully inserted or copied.
    static let success = makeSystemSymbol("checkmark.circle.fill")

    /// Failure.
    static let failed = makeSystemSymbol("exclamationmark.triangle.fill")

    // MARK: - Private

    private static func makeWaveform(heights: [CGFloat]) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let barWidth: CGFloat = 2
        let spacing: CGFloat = 1.5
        let image = NSImage(size: size, flipped: false) { rect in
            let count = CGFloat(heights.count)
            let totalWidth = count * barWidth + (count - 1) * spacing
            let startX = (rect.width - totalWidth) / 2

            NSColor.black.setFill()
            for (i, h) in heights.enumerated() {
                let x = startX + CGFloat(i) * (barWidth + spacing)
                let y = (rect.height - h) / 2
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                    xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func makeSystemSymbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }
}
