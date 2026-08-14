import SwiftUI

struct MacOnboardingView: View {
    @ObservedObject var settings: MacSettingsModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Clipboard Keyboard").font(.title)
            Text("Automatic capture is off until you enable it.")
            Toggle("Enable Automatic Capture", isOn: $settings.captureConsentGranted)
        }
        .padding()
        .frame(width: 420)
    }
}
