import AppKit
import ApplicationServices
import Foundation

enum AccessibilityReader {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func focusedWindow() -> WindowContext {
        let system = AXUIElementCreateSystemWide()
        guard let app = elementAttribute(system, kAXFocusedApplicationAttribute as CFString) else {
            return fallbackContext()
        }

        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        let running = NSRunningApplication(processIdentifier: pid)
        let appName = running?.localizedName ?? "Unknown"
        let bundleID = running?.bundleIdentifier ?? "pid.\(pid)"

        let window = elementAttribute(app, kAXFocusedWindowAttribute as CFString)
        let title = window.flatMap { stringAttribute($0, kAXTitleAttribute as CFString) }
            ?? stringAttribute(app, kAXTitleAttribute as CFString)
            ?? "Untitled"
        let document = window.flatMap { stringAttribute($0, kAXDocumentAttribute as CFString) }
            ?? window.flatMap { stringAttribute($0, kAXURLAttribute as CFString) }

        let focused = elementAttribute(system, kAXFocusedUIElementAttribute as CFString)
        return WindowContext(
            appName: appName,
            bundleIdentifier: bundleID,
            windowTitle: title,
            documentURL: document,
            focusedRole: focused.flatMap { stringAttribute($0, kAXRoleAttribute as CFString) },
            focusedValue: focused.flatMap { bounded(stringAttribute($0, kAXValueAttribute as CFString)) },
            selectedText: focused.flatMap { bounded(stringAttribute($0, kAXSelectedTextAttribute as CFString)) }
        )
    }

    private static func fallbackContext() -> WindowContext {
        guard let running = NSWorkspace.shared.frontmostApplication else { return .unknown }
        return WindowContext(
            appName: running.localizedName ?? "Unknown",
            bundleIdentifier: running.bundleIdentifier ?? "pid.\(running.processIdentifier)",
            windowTitle: "Untitled"
        )
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let value else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func bounded(_ value: String?) -> String? {
        value.map { String($0.prefix(4_000)) }
    }
}
