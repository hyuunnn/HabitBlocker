import AppKit
import ApplicationServices

struct FrontContext: Equatable {
    var appName: String
    var windowTitle: String
    var url: String?
    var isBrowser: Bool

    var addressReadable: Bool {
        if !isBrowser { return true }
        guard let url else { return false }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var identity: String {
        "\(appName)|\(url ?? "")|\(windowTitle)"
    }

    var stateText: String {
        var lines = ["앱: \(appName)"]
        if let url, !url.isEmpty {
            lines.append("주소: \(url)")
        }
        if !windowTitle.isEmpty {
            lines.append(isBrowser ? "제목: \(windowTitle)" : "창 제목: \(windowTitle)")
        }
        return lines.joined(separator: "\n")
    }
}

enum FrontContextReader {
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "com.sigmaos.sigmaos.macos",
        "com.pushplaylabs.sidekick",
        "company.thebrowser.dia",
        "org.chromium.Chromium",
        "com.naver.Whale"
    ]

    static func capture(promptForTrust: Bool = false) -> FrontContext {
        if promptForTrust {
            promptAccessibilityTrust()
        }
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? ""
        let bundleID = app?.bundleIdentifier ?? ""
        let isBrowser = browserBundleIDs.contains(bundleID) || looksLikeBrowser(appName)
        let title = windowTitle(pid: app?.processIdentifier)
        let url = isBrowser ? browserURL(appName: appName, bundleID: bundleID) : nil
        return FrontContext(appName: appName, windowTitle: title ?? "", url: url, isBrowser: isBrowser)
    }

    static func promptAccessibilityTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func looksLikeBrowser(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let hints = ["safari", "chrome", "firefox", "edge", "brave", "arc", "opera", "whale", "chromium", "vivaldi", "orion", "dia", "browser"]
        return hints.contains { lowered.contains($0) }
    }

    private static func windowTitle(pid: pid_t?) -> String? {
        guard let pid, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    private static func browserURL(appName: String, bundleID: String) -> String? {
        let source: String
        if bundleID == "com.apple.Safari" || appName == "Safari" {
            source = "tell application \"Safari\" to get URL of front document"
        } else if bundleID == "org.mozilla.firefox" || appName == "Firefox" {
            source = "tell application \"Firefox\" to get URL of front window"
        } else {
            let escaped = appName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            source = "tell application \"\(escaped)\" to get URL of active tab of front window"
        }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let value = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, value.contains("://") else { return nil }
        return value
    }
}
