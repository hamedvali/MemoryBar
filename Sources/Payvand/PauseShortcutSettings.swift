import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Settings row for the global pause shortcut, including recording a new one.
///
/// It owns the key monitor so the lifetime of that monitor is tied to the view
/// that shows it: leaving Settings, or closing the popover, always tears it down.
struct PauseShortcutSettings: View {
    @ObservedObject var model: AppModel
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(
                    get: { model.pauseShortcutEnabled },
                    set: { model.updatePauseShortcutEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause shortcut")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Pause or resume capture from any app.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

            if model.pauseShortcutEnabled {
                HStack(spacing: 10) {
                    Button { isRecording ? cancelRecording() : beginRecording() } label: {
                        Text(isRecording ? "Press keys…" : model.pauseShortcut.displayName)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .frame(minWidth: 86)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(isRecording ? .indigo : nil)

                    Text(isRecording ? "Hold a modifier and press a key. Esc cancels." : "Click to change")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if model.pauseShortcutUnavailable {
                    Label(
                        "Another app is already using this shortcut. Pick a different one.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                }
            }
        }
        .onDisappear(perform: cancelRecording)
    }

    private func beginRecording() {
        guard monitor == nil else { return }
        isRecording = true
        model.suspendPauseShortcut()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode != UInt16(kVK_Escape) else {
                cancelRecording()
                return nil
            }
            let modifiers = HotKeyCombination.carbonModifiers(from: event.modifierFlags)
            // A bare key would swallow that key in every app, so keep listening
            // until the user holds at least one modifier.
            guard modifiers != 0 else { return nil }
            stopMonitoring()
            model.updatePauseShortcut(
                HotKeyCombination(
                    keyCode: UInt32(event.keyCode),
                    carbonModifiers: modifiers,
                    keyLabel: HotKeyCombination.label(for: event)
                )
            )
            return nil
        }
    }

    private func cancelRecording() {
        guard monitor != nil else { return }
        stopMonitoring()
        model.resumePauseShortcut()
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
