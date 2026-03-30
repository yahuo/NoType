import SwiftUI

struct HUDPanelView: View {
    @ObservedObject var model: NoTypeAppModel
    @State private var isAnimatingBars = false

    var body: some View {
        VStack(spacing: 8) {
            controlBar

            if model.phase == .failed, let errorMessage = model.errorMessage {
                failureCard(errorMessage)
            }
        }
        .frame(width: 356, alignment: .center)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .onAppear {
            isAnimatingBars = true
        }
    }

    @ViewBuilder
    private var controlBar: some View {
        HStack(spacing: 14) {
            hudButton(symbol: "xmark", accent: Color.white.opacity(0.16)) {
                model.cancelFromUI()
            }

            centerIndicator
                .frame(maxWidth: .infinity)

            hudButton(
                symbol: model.phase == .recording ? "checkmark" : "hourglass",
                accent: .white
            ) {
                model.stopDictationFromUI()
            }
            .disabled(model.phase != .recording)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 194)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
    }

    @ViewBuilder
    private var centerIndicator: some View {
        switch model.phase {
        case .recording:
            WaveformBarsView(level: model.waveformLevel, isAnimating: isAnimatingBars)
                .frame(height: 20)
        case .transcribing:
            progressIndicator(label: isChinese ? "处理中" : "Processing")
        case .refining:
            progressIndicator(label: isChinese ? "改写中" : "Rewriting")
        case .inserted:
            Label(isChinese ? "已插入" : "Inserted", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
        case .copiedToClipboard:
            Label(isChinese ? "已复制" : "Copied", systemImage: "doc.on.doc.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
        case .failed:
            Label(isChinese ? "失败" : "Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
        case .idle, .onboarding:
            HStack(spacing: 5) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .medium))
                Text("NoType")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.92))
        }
    }

    private func progressIndicator(label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
        }
    }

    private func hudButton(symbol: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(accent)
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent == .white ? .black : .white)
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func failureCard(_ errorMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isChinese ? "听写失败" : "Dictation failed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(errorMessage)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08))
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private var isChinese: Bool {
        model.settings.language.usesChineseCopy
    }
}

private struct WaveformBarsView: View {
    let level: Double
    let isAnimating: Bool

    private let baseHeights: [CGFloat] = [6, 9, 12, 16, 14, 18, 13, 16, 10, 7]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { context in
            let timestamp = context.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(baseHeights.enumerated()), id: \.offset) { index, height in
                    Capsule(style: .continuous)
                        .fill(index == 4 || index == 5 ? Color.red.opacity(0.95) : Color.white.opacity(0.92))
                        .frame(width: 3, height: animatedHeight(for: index, base: height, timestamp: timestamp))
                }
            }
        }
    }

    private func animatedHeight(for index: Int, base: CGFloat, timestamp: TimeInterval) -> CGFloat {
        let jitter = 1 + CGFloat(sin(timestamp * 7.5 + Double(index) * 0.65)) * 0.08
        let scaledLevel = max(0.18, CGFloat(level))
        let target = max(6, base * (0.45 + scaledLevel * 1.35) * jitter)
        return isAnimating ? target : max(6, base * 0.45)
    }
}
