import SwiftUI

/// First-launch welcome screen. Explains what Bezel does and how to enable
/// USB debugging on the phone before connecting.
struct WelcomeView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandMark(size: 64)
                .padding(.top, 30)
                .padding(.bottom, 14)

            Text("Welcome to Bezel")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Mirror and record your Android phone on your Mac over USB — nothing is installed on the phone and no account is needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Text("Before you start")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.6)
                .padding(.top, 22)
                .padding(.bottom, 4)

            ForEach(Array(WelcomeView.steps.enumerated()), id: \.offset) { index, step in
                stepRow(index + 1, step)
            }

            Spacer(minLength: 8)

            HStack(spacing: 18) {
                ForEach(WelcomeView.features) { feature in
                    VStack(spacing: 5) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Text(feature.title)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 96)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Personal use only — free, no telemetry, and nothing leaves your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Already set up? Pick your device in the top bar and press Connect (⌘↩).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

            HStack {
                Spacer()
                Button("Get started") {
                    state.settings.hasSeenWelcome = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 32)
        .padding(.top, 4)
        .frame(width: 520, height: 620)
    }

    private func stepRow(_ number: Int, _ step: WelcomeStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 13, weight: .medium))
                Text(step.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WelcomeStep {
    let title: String
    let detail: String
}

private struct WelcomeFeature: Identifiable {
    let title: String
    let icon: String
    var id: String { title }
}

extension WelcomeView {
    fileprivate static let steps: [WelcomeStep] = [
        WelcomeStep(
            title: "Turn on Developer options",
            detail: "On the phone: Settings → About phone, then tap “Build number” seven times until it says “You are now a developer.”"
        ),
        WelcomeStep(
            title: "Enable USB debugging",
            detail: "Settings → System → Developer options, turn it on, then enable “USB debugging.”"
        ),
        WelcomeStep(
            title: "Plug in and approve",
            detail: "Connect with a data-capable USB cable, then approve “Allow USB debugging?” on the phone (check “Always allow”) and macOS’s accessory prompt."
        ),
        WelcomeStep(
            title: "Connect in Bezel",
            detail: "Pick your device in the top bar and press Connect (⌘↩). Then record, screenshot, or add the Mac camera as a picture-in-picture overlay."
        )
    ]

    fileprivate static let features: [WelcomeFeature] = [
        WelcomeFeature(title: "Mirror", icon: "iphone.gen3"),
        WelcomeFeature(title: "Record", icon: "record.circle"),
        WelcomeFeature(title: "Webcam PiP", icon: "camera.filters"),
        WelcomeFeature(title: "Keyboard", icon: "keyboard")
    ]
}
