import SwiftUI
import AppKit

/// Trackpad › Settings: everything about how gestures are recognized and how the trackpad scrolls.
struct TrackpadSettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var deviceCount = TrackpadEngine.shared.deviceCount
    @State private var running = TrackpadEngine.shared.isRunning
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Trackpad gestures", isOn: $store.config.general.trackpadEnabled)
                LabeledContent("Swipe distance") {
                    HStack {
                        Slider(value: $store.config.general.swipeThreshold, in: 0.04...0.3)
                        Text(String(format: "%.2f", store.config.general.swipeThreshold)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Direction strictness") {
                    HStack {
                        Slider(value: $store.config.general.swipeAxisRatio, in: 1...4, step: 0.25)
                        Text(String(format: "%.2f", store.config.general.swipeAxisRatio)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Stepper(value: $store.config.general.tapMaxDurationMs, in: 100...600, step: 25) {
                    LabeledContent("Max tap duration", value: "\(store.config.general.tapMaxDurationMs) ms")
                }
                Stepper(value: $store.config.general.gestureCooldownMs, in: 0...1000, step: 50) {
                    LabeledContent("Cooldown between gestures", value: "\(store.config.general.gestureCooldownMs) ms")
                }
                LabeledContent("Ignore touches larger than") {
                    HStack {
                        Slider(value: $store.config.general.maxTouchSize, in: 0...8, step: 0.5)
                        Text(store.config.general.maxTouchSize == 0 ? L("off") : String(format: "%.1f", store.config.general.maxTouchSize)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } header: { Text("Gesture recognition") } footer: {
                Text("Swipe distance is in normalized trackpad units (1.0 = full width). Direction strictness is how much the main axis must dominate (1 = any diagonal counts, 2 = at least twice the other axis). Touch size is the contact-area value from the multitouch frames; fingertips are usually 1–2.5, palms larger — the Event Viewer’s Trackpad page shows live values.")
            }

            Section {
                Toggle("Block scrolling while 3+ fingers are down (BTT-style)", isOn: $store.config.general.suppressScrollAfterGesture)
                Stepper(value: $store.config.general.scrollSuppressTailMs, in: 0...1000, step: 50) {
                    LabeledContent("Keep blocking after the fingers lift", value: "\(store.config.general.scrollSuppressTailMs) ms")
                }
                .disabled(!store.config.general.suppressScrollAfterGesture)
                Toggle("Reverse trackpad scrolling (trackpad only)", isOn: $store.config.general.trackpadReverseScroll)
                LabeledContent("Trackpad scroll speed") {
                    HStack {
                        Slider(value: $store.config.general.trackpadScrollSpeed, in: 0.25...3, step: 0.25)
                        Text(String(format: "%.2f×", store.config.general.trackpadScrollSpeed)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            } header: { Text("Scrolling") } footer: {
                Text("Blocking only applies to finger counts that have a gesture trigger; two-finger scrolling is never touched. Reverse / speed here affect the trackpad and the Magic Mouse surface; the Mouse tab has the same controls for mouse wheels, and the Mouse tab’s excluded apps are honoured here too.")
            }

            Section {
                LabeledContent("Multitouch devices", value: TrackpadEngine.shared.isAvailable ? L("%lld detected · engine %@", deviceCount, running ? L("running") : L("idle")) : L("framework unavailable"))
                HStack {
                    Button("Restart Engine") { TrackpadEngine.shared.restart(); refresh() }
                    Button("System Trackpad Settings…") { SystemGestures.openTrackpadSettings() }
                    Button("Event Viewer (live touches)…") {
                        MainWindowController.shared.show(.eventViewer)
                    }
                }
            } header: { Text("Devices") } footer: {
                Text("The engine runs only while at least one gesture trigger is enabled (or the Event Viewer’s Trackpad page is open). Tap-to-click, tracking speed and the system’s own gestures live in System Settings; turn off the system gesture that shares a finger count with your triggers to avoid double actions.")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func refresh() {
        deviceCount = TrackpadEngine.shared.deviceCount
        running = TrackpadEngine.shared.isRunning
    }
}
