import AppKit
import Combine
import SwiftUI

@MainActor
final class MemoryBarDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var model: AppModel?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let model = AppModel()
        self.model = model

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "MemoryBar")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("MemoryBar")
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 460, height: 680)
        popover.contentViewController = NSHostingController(rootView: MemoryPopover(model: model))

        model.$isPaused
            .combineLatest(model.$lastError)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &subscriptions)
        updateStatusItem()

        if !UserDefaults.standard.bool(forKey: "ui.hasShownFirstPopover") {
            UserDefaults.standard.set(true, forKey: "ui.hasShownFirstPopover")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateStatusItem() {
        guard let model, let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: model.isPaused ? "brain.head.profile" : "brain.fill",
            accessibilityDescription: "MemoryBar"
        )
        button.image?.isTemplate = true
        button.toolTip = model.isPaused
            ? "MemoryBar is paused"
            : (model.lastError == nil ? "MemoryBar is remembering locally" : "MemoryBar needs attention")
    }
}

@main
struct MemoryBarApp: App {
    @NSApplicationDelegateAdaptor(MemoryBarDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private struct MemoryPopover: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false
    @State private var confirmDelete = false
    @State private var didCopyURL = false

    var body: some View {
        ZStack {
            panelBackdrop

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    metricsCard
                    mcpCard
                    permissionsCard
                    statusMessage
                    settingsCard
                    footer
                }
                .padding(18)
            }
        }
        .frame(width: 460, height: 680)
        .alert("Delete all local memory?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) { model.deleteAllMemory() }
        } message: {
            Text("This permanently removes all observations, episodes, thumbnails, and extracted actions from this Mac.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 58, height: 58)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                        .shadow(color: statusColor.opacity(0.55), radius: model.captureFlash ? 8 : 3)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text("MemoryBar")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(statusColor)
            }

            Spacer()

            captureControl
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var captureControl: some View {
        let label = Label(
            model.isPaused ? "Resume" : "Pause",
            systemImage: model.isPaused ? "play.fill" : "pause.fill"
        )
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 2)

        if #available(macOS 26.0, *) {
            Button { model.togglePaused() } label: { label }
                .buttonStyle(.glassProminent)
                .tint(model.isPaused ? .green : .indigo)
                .controlSize(.large)
        } else {
            Button { model.togglePaused() } label: { label }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(model.isPaused ? .green : .indigo)
                .controlSize(.large)
        }
    }

    private var metricsCard: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    metric(value: uptimeText(now: context.date), label: "Active time")
                    metricDivider
                    metric(value: "\(model.episodeCount)", label: "Episodes")
                    metricDivider
                    metric(value: "\(model.observationCount)", label: "Captures")
                }

                HStack(spacing: 7) {
                    Image(systemName: model.lastCaptureAt == nil ? "clock" : "checkmark.circle.fill")
                        .foregroundStyle(model.lastCaptureAt == nil ? Color.secondary : Color.green)
                    Text(lastCheckText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(17)
            .memoryGlass(cornerRadius: 22)
        }
    }

    private var mcpCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeader(
                title: "Local MCP",
                subtitle: model.mcpError == nil ? "OAuth protected • This Mac only" : "Server needs attention",
                systemImage: "lock.shield.fill",
                color: model.mcpError == nil ? .blue : .orange
            )

            HStack(spacing: 10) {
                Text(model.mcpURL)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Button {
                    model.copyMCPURL()
                    didCopyURL = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        didCopyURL = false
                    }
                } label: {
                    Label(didCopyURL ? "Copied" : "Copy", systemImage: didCopyURL ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
            }
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            if model.authorizedClients.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.key")
                        .foregroundStyle(.secondary)
                    Text("No AI clients authorized yet. Your client will ask for approval when it first connects.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(model.authorizedClients.prefix(4)) { client in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                Text(client.lastUsedAt.map { "Last used \($0.formatted(.relative(presentation: .named)))" }
                                    ?? "Authorized")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 4)

                            Button("Revoke", role: .destructive) {
                                model.revokeMCPClient(id: client.id)
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
        .padding(17)
        .memoryGlass(cornerRadius: 22)
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeader(
                title: "Permissions",
                subtitle: permissionsReady ? "Everything is ready" : "Finish setup to start remembering",
                systemImage: "hand.raised.fill",
                color: permissionsReady ? .green : .orange
            )

            VStack(spacing: 8) {
                permissionRow(
                    title: "Screen Recording",
                    subtitle: "Reads visible work locally",
                    granted: model.screenPermissionGranted,
                    action: model.requestScreenPermission
                )
                permissionRow(
                    title: "Accessibility",
                    subtitle: "Adds app and window context",
                    granted: model.accessibilityPermissionGranted,
                    action: model.requestAccessibilityPermission
                )
            }
        }
        .padding(17)
        .memoryGlass(cornerRadius: 22)
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let error = actionableError {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.orange.opacity(0.20), lineWidth: 1)
            }
        }
    }

    private var settingsCard: some View {
        DisclosureGroup(isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 15) {
                Divider().opacity(0.55)

                Toggle(isOn: Binding(
                        get: { model.retainThumbnails },
                        set: { model.updateRetainThumbnails($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Evidence thumbnails")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Keep small local images with memories")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Excluded applications")
                        .font(.system(size: 14, weight: .semibold))
                    Text("MemoryBar skips apps in this comma-separated list.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        TextField("1Password, Keychain Access", text: Binding(
                            get: { model.excludedAppsText },
                            set: { model.updateExcludedApps($0) }
                        ))
                        .font(.system(size: 13))
                        .textFieldStyle(.roundedBorder)
                        .frame(height: 30)
                }

                HStack(spacing: 9) {
                    Button { model.captureNow() } label: {
                        Label("Capture now", systemImage: "camera.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)

                    Button { model.revealMemoryFile() } label: {
                        Label("Show database", systemImage: "cylinder.split.1x2")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
                .font(.system(size: 13, weight: .semibold))
                .controlSize(.regular)

                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete all local memory…", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            .padding(.top, 13)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.purple.opacity(0.13))
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.system(size: 15, weight: .bold))
                    Text("Privacy, storage and controls")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.secondary)
        .padding(17)
        .memoryGlass(cornerRadius: 22)
    }

    private var footer: some View {
        HStack {
            Label("On-device • No cloud", systemImage: "lock.shield.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.quit() } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 12.5, weight: .semibold))
            }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private var statusColor: Color {
        if model.isPaused { return .orange }
        if actionableError != nil { return .red }
        if !permissionsReady { return .orange }
        return .green
    }

    private var statusTitle: String {
        if model.isPaused { return "Capture paused" }
        if actionableError != nil { return "Needs attention" }
        if !permissionsReady { return "Setup required" }
        return "Remembering locally"
    }

    private var actionableError: String? {
        if let mcpError = model.mcpError { return mcpError }
        if model.screenPermissionGranted { return model.lastError }
        return nil
    }

    private var permissionsReady: Bool {
        model.screenPermissionGranted && model.accessibilityPermissionGranted
    }

    private var lastCheckText: String {
        guard let lastCapture = model.lastCaptureAt else {
            return model.isPaused ? "Capture is paused" : "Waiting for the first capture"
        }
        return "Last checked \(lastCapture.formatted(.relative(presentation: .named)))"
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(width: 1, height: 42)
            .padding(.horizontal, 10)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(title: String, subtitle: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(granted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if !granted {
                Button("Allow", action: action)
                    .font(.system(size: 12.5, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            } else {
                Text("Allowed")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func uptimeText(now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(model.startedAt) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remaining = minutes % 60
        return remaining == 0 ? "\(hours)h" : "\(hours)h \(remaining)m"
    }

    private var panelBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            Circle()
                .fill(.blue.opacity(0.13))
                .frame(width: 280, height: 280)
                .blur(radius: 70)
                .offset(x: -170, y: -255)

            Circle()
                .fill(.purple.opacity(0.11))
                .frame(width: 260, height: 260)
                .blur(radius: 78)
                .offset(x: 190, y: 250)

            LinearGradient(
                colors: [.white.opacity(0.06), .clear, .blue.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct MemoryGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(.blue.opacity(colorScheme == .dark ? 0.05 : 0.025)),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(colorScheme == .dark ? 0.09 : 0.30),
                                    .white.opacity(0.025),
                                    .blue.opacity(colorScheme == .dark ? 0.035 : 0.018)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(colorScheme == .dark ? 0.18 : 0.55),
                                    .white.opacity(0.05),
                                    .primary.opacity(0.07)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.20 : 0.08),
                    radius: 14,
                    y: 7
                )
        }
    }
}

private extension View {
    func memoryGlass(cornerRadius: CGFloat = 20) -> some View {
        modifier(MemoryGlassModifier(cornerRadius: cornerRadius))
    }
}
