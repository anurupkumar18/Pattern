import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import VoiceOpsCore
import os

private let screenLog = Logger(subsystem: "com.voiceops.VoiceOps", category: "screen-context")

/// Task-scoped ScreenCaptureKit + Accessibility collector (ARD §4.2).
/// The screenshot lives under a per-capture temporary directory and is removed
/// as soon as the task reaches a terminal state.
actor NativeScreenContextCollector: ScreenContextCollecting {
    private let fileManager = FileManager.default
    private let captureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("VoiceOps", isDirectory: true)

    func collect() async throws -> CollectedScreenContext {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenContextError.screenRecordingDenied
        }

        // Literal value of kAXTrustedCheckOptionPrompt. The SDK exposes that
        // constant as mutable global state, which Swift 6 rejects from actors.
        let accessibilityOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(accessibilityOptions) else {
            throw ScreenContextError.accessibilityDenied
        }

        let application = try await activeApplication()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
        } catch {
            throw mapCaptureError(error)
        }

        let accessibilityReader = AccessibilityTreeReader()
        let focusedWindow = accessibilityReader.focusedWindowIdentity(
            processID: application.processIdentifier)
        guard let window = chooseWindow(
            in: content.windows,
            processID: application.processIdentifier,
            focusedWindow: focusedWindow)
        else {
            throw ScreenContextError.activeWindowUnavailable
        }

        let captureID = UUID()
        let screenshotURL = captureRoot
            .appendingPathComponent(captureID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("active-window.png")

        do {
            try fileManager.createDirectory(
                at: screenshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let image = try await capture(window: window)
            try writePNG(image, to: screenshotURL)
        } catch let error as ScreenContextError {
            try? fileManager.removeItem(at: screenshotURL.deletingLastPathComponent())
            throw error
        } catch {
            try? fileManager.removeItem(at: screenshotURL.deletingLastPathComponent())
            throw mapCaptureError(error)
        }

        let appBundleID = application.bundleIdentifier ?? "unknown.bundle"
        let tree = accessibilityReader.read(
            processID: application.processIdentifier,
            fallbackWindowBounds: window.frame)
        let candidates = tree.snapshot.map {
            AccessibilityCandidateBuilder.build(
                from: $0, appBundleID: appBundleID, visibleBounds: window.frame)
        } ?? []
        // CGEvent uses the same global Quartz coordinate space as AX bounds;
        // NSEvent.mouseLocation uses AppKit's flipped vertical axis.
        let pointer = CGEvent(source: nil)?.location
        let observation = Observation(
            captureID: captureID,
            timestamp: .now,
            activeApp: AppReference(
                bundleID: appBundleID,
                name: application.localizedName ?? window.owningApplication?.applicationName ?? "Unknown"),
            window: WindowReference(
                title: nonempty(window.title) ?? tree.windowTitle ?? "Untitled",
                bounds: window.frame),
            focusedElementID: tree.focusedIdentifier,
            pointer: pointer,
            elements: candidates,
            screenshotPath: screenshotURL.absoluteString)

        screenLog.info(
            "captured active window for \(appBundleID, privacy: .public) with \(candidates.count) visible AX candidates")
        return CollectedScreenContext(
            observation: observation, screenshotFileURL: screenshotURL)
    }

    func cleanup(captureID: UUID) {
        let directory = captureRoot.appendingPathComponent(
            captureID.uuidString.lowercased(), isDirectory: true)
        do {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        } catch {
            screenLog.error("could not remove ephemeral capture: \(error.localizedDescription)")
        }
    }

    private func activeApplication() async throws -> NSRunningApplication {
        guard let application = await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication
        }) else {
            throw ScreenContextError.activeApplicationUnavailable
        }
        return application
    }

    private func chooseWindow(
        in windows: [SCWindow],
        processID: pid_t,
        focusedWindow: FocusedWindowIdentity?
    ) -> SCWindow? {
        let candidates = windows
            .filter {
                $0.owningApplication?.processID == processID
                    && $0.isOnScreen
                    && $0.windowLayer == 0
                    && $0.frame.width > 1
                    && $0.frame.height > 1
            }
        if let windowID = focusedWindow?.windowID,
           let exact = candidates.first(where: { $0.windowID == windowID }) {
            return exact
        }
        if let title = focusedWindow?.title,
           let titleMatch = candidates.first(where: { nonempty($0.title) == title }) {
            return titleMatch
        }
        // ScreenCaptureKit exposes windows in front-to-back order. Falling
        // back to the first active-app window is safer than choosing the
        // largest background window.
        return candidates.first
    }

    private func capture(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let windowFrame = window.frame
        let scale = await MainActor.run {
            NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) })?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(windowFrame.width * scale))
        configuration.height = max(1, Int(windowFrame.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ScreenContextError.captureFailed("the captured image could not be encoded")
        }
        try data.write(to: url, options: .atomic)
    }

    private func mapCaptureError(_ error: Error) -> ScreenContextError {
        if !CGPreflightScreenCaptureAccess() {
            return .screenRecordingDenied
        }
        return .captureFailed(error.localizedDescription)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct FocusedWindowIdentity {
    let windowID: CGWindowID?
    let title: String?
}

private struct AccessibilityTreeRead {
    let snapshot: AccessibilityNodeSnapshot?
    let focusedIdentifier: String?
    let windowTitle: String?
}

/// Converts AXUIElement's untyped graph into the pure snapshot model. Candidate
/// pruning is intentionally separate and unit tested in VoiceOpsCore.
private final class AccessibilityTreeReader {
    private let maxDepth = 12
    private let maxNodes = 600

    func focusedWindowIdentity(processID: pid_t) -> FocusedWindowIdentity? {
        let application = AXUIElementCreateApplication(processID)
        guard let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute) else {
            return nil
        }
        let number: NSNumber? = attribute(window, "AXWindowNumber")
        return FocusedWindowIdentity(
            windowID: number.map { CGWindowID($0.uint32Value) },
            title: stringAttribute(window, kAXTitleAttribute))
    }

    func read(processID: pid_t, fallbackWindowBounds: CGRect) -> AccessibilityTreeRead {
        let application = AXUIElementCreateApplication(processID)
        guard let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute) else {
            return AccessibilityTreeRead(
                snapshot: nil, focusedIdentifier: nil, windowTitle: nil)
        }

        let focused: AXUIElement? = attribute(application, kAXFocusedUIElementAttribute)
        let focusedIdentifier = focused.flatMap {
            stringAttribute($0, kAXIdentifierAttribute)
        }
        let title = stringAttribute(window, kAXTitleAttribute)
        var visited = 0
        return AccessibilityTreeRead(
            snapshot: snapshot(
                window, depth: 0, visited: &visited,
                fallbackBounds: fallbackWindowBounds),
            focusedIdentifier: focusedIdentifier,
            windowTitle: title)
    }

    private func snapshot(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        fallbackBounds: CGRect?
    ) -> AccessibilityNodeSnapshot? {
        guard depth <= maxDepth, visited < maxNodes else { return nil }
        visited += 1

        let role = stringAttribute(element, kAXRoleAttribute)
        let title = stringAttribute(element, kAXTitleAttribute)
        let description = stringAttribute(element, kAXDescriptionAttribute)
        let value = displayValue(element)
        let label = firstNonempty(title, description)
        let bounds = elementBounds(element) ?? (depth == 0 ? fallbackBounds : nil)
        let hidden: Bool = attribute(element, kAXHiddenAttribute) ?? false

        var stable: [String: String] = [:]
        if let identifier = stringAttribute(element, kAXIdentifierAttribute) {
            stable["AXIdentifier"] = identifier
        }
        if let subrole = stringAttribute(element, kAXSubroleAttribute) {
            stable["AXSubrole"] = subrole
        }
        if let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute) {
            stable["AXRoleDescription"] = roleDescription
        }

        var rawActions: CFArray?
        let actionError = AXUIElementCopyActionNames(element, &rawActions)
        let actions = actionError == .success ? (rawActions as? [String] ?? []) : []
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []

        return AccessibilityNodeSnapshot(
            role: role,
            label: label,
            value: value,
            bounds: bounds,
            actions: actions,
            stableAttributes: stable,
            isHidden: hidden,
            children: children.compactMap {
                snapshot($0, depth: depth + 1, visited: &visited, fallbackBounds: nil)
            })
    }

    private func elementBounds(_ element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func displayValue(_ element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &raw) == .success,
              let raw
        else { return nil }
        if let value = raw as? String { return nonempty(value) }
        if let value = raw as? NSNumber { return value.stringValue }
        return nil
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        nonempty(attribute(element, name) as String?)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            return nil
        }
        return raw as? T
    }

    private func firstNonempty(_ values: String?...) -> String? {
        values.compactMap(nonempty).first
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
