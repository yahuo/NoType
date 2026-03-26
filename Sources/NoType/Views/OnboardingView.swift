import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: NoTypeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up NoType")
                .font(.largeTitle.bold())

            Text("Enable the two macOS permissions NoType needs for dictation and text insertion.")
                .foregroundStyle(.secondary)

            permissionRow(
                title: "Microphone",
                granted: model.permissionSnapshot.microphoneAuthorized,
                actionTitle: "Open Microphone Settings",
                action: model.openMicrophoneSettings
            )

            permissionRow(
                title: "Accessibility",
                granted: model.permissionSnapshot.accessibilityAuthorized,
                actionTitle: "Open Accessibility Settings",
                action: model.openAccessibilitySettings
            )

            HStack {
                Button("Request Permissions") {
                    Task {
                        await model.requestPermissions()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Refresh Status") {
                    model.bootstrap()
                }
            }

            Spacer()
        }
        .padding(24)
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        GroupBox {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(granted ? .green : .red)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(granted ? "Granted" : "Not granted yet")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(actionTitle, action: action)
            }
        }
    }
}
