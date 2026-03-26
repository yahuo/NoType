import SwiftUI

struct HUDPanelView: View {
    @ObservedObject var model: NoTypeAppModel
    @State private var isAnimatingBars = false

    var body: some View {
        VStack(spacing: 8) {
            if showsStatusPill {
                statusPill
            }

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
    private var statusPill: some View {
        Text(statusLine)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.84))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10))
                    )
            )
            .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
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
                symbol: model.phase == .processing ? "hourglass" : "checkmark",
                accent: .white
            ) {
                if model.phase == .recording {
                    model.stopDictationFromUI()
                }
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
            WaveformBarsView(isAnimating: isAnimatingBars)
                .frame(height: 20)
        case .processing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(isChinese ? "处理中" : "Processing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
        case .inserted:
            Label(isChinese ? "已插入" : "Inserted", systemImage: "checkmark.circle.fill")
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

    private var showsStatusPill: Bool {
        switch model.phase {
        case .recording, .processing:
            true
        case .failed, .inserted, .idle, .onboarding:
            false
        }
    }

    private var isChinese: Bool {
        model.settings.language == .zhCN
    }

    private var statusLine: String {
        switch model.phase {
        case .recording:
            if model.currentMicrophoneName == "System Default" {
                return isChinese ? "使用中 Auto-detect 麦克风" : "Using Auto-detect microphone"
            }
            return isChinese ? "使用中 \(model.currentMicrophoneName)" : "Using \(model.currentMicrophoneName)"
        case .processing:
            return isChinese ? "正在转写语音" : "Transcribing audio"
        case .failed:
            return isChinese ? "听写失败" : "Dictation Failed"
        case .inserted:
            return isChinese ? "已插入文本" : "Inserted"
        case .idle, .onboarding:
            return "NoType"
        }
    }
}

private struct WaveformBarsView: View {
    let isAnimating: Bool

    private let baseHeights: [CGFloat] = [6, 9, 12, 16, 14, 18, 13, 16, 10, 7]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(baseHeights.enumerated()), id: \.offset) { index, height in
                Capsule(style: .continuous)
                    .fill(index == 4 || index == 5 ? Color.red.opacity(0.95) : Color.white.opacity(0.92))
                    .frame(width: 3, height: animatedHeight(for: index, base: height))
                    .animation(
                        .easeInOut(duration: 0.55)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.05),
                        value: isAnimating
                    )
            }
        }
    }

    private func animatedHeight(for index: Int, base: CGFloat) -> CGFloat {
        isAnimating ? base : max(6, base * 0.45)
    }
}
