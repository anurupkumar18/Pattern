import CoreGraphics
import Foundation

// MARK: - Observation wire models (Python source of truth: schemas.py)

public enum CandidateSource: String, Codable, Equatable, Sendable {
    case accessibility, ocr, vision, dom
}

public struct AppReference: Codable, Equatable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
    }
}

public struct WindowReference: Equatable, Sendable {
    public let title: String
    public let bounds: CGRect

    public init(title: String, bounds: CGRect) {
        self.title = title
        self.bounds = bounds
    }
}

extension WindowReference: Codable {
    enum CodingKeys: String, CodingKey { case title, bounds }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        bounds = try WireGeometry.decodeRect(from: container, key: .bounds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(WireGeometry.array(bounds), forKey: .bounds)
    }
}

public struct UIElementCandidate: Equatable, Sendable {
    public let id: String
    public let role: String?
    public let label: String?
    public let value: String?
    public let bounds: CGRect
    public let source: CandidateSource
    public let confidence: Double
    public let actions: [String]
    public let appBundleID: String
    public let stableAttributes: [String: String]

    public init(
        id: String,
        role: String?,
        label: String?,
        value: String?,
        bounds: CGRect,
        source: CandidateSource,
        confidence: Double,
        actions: [String],
        appBundleID: String,
        stableAttributes: [String: String]
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.bounds = bounds
        self.source = source
        self.confidence = confidence
        self.actions = actions
        self.appBundleID = appBundleID
        self.stableAttributes = stableAttributes
    }
}

extension UIElementCandidate: Codable {
    enum CodingKeys: String, CodingKey {
        case id, role, label, value, bounds, source, confidence, actions
        case appBundleID = "app_bundle_id"
        case stableAttributes = "stable_attributes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        bounds = try WireGeometry.decodeRect(from: container, key: .bounds)
        source = try container.decode(CandidateSource.self, forKey: .source)
        confidence = try container.decode(Double.self, forKey: .confidence)
        actions = try container.decode([String].self, forKey: .actions)
        appBundleID = try container.decode(String.self, forKey: .appBundleID)
        stableAttributes = try container.decode([String: String].self, forKey: .stableAttributes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encode(WireGeometry.array(bounds), forKey: .bounds)
        try container.encode(source, forKey: .source)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(actions, forKey: .actions)
        try container.encode(appBundleID, forKey: .appBundleID)
        try container.encode(stableAttributes, forKey: .stableAttributes)
    }
}

public struct Observation: Equatable, Sendable {
    public let captureID: UUID
    public let timestamp: Date
    public let activeApp: AppReference
    public let window: WindowReference
    public let focusedElementID: String?
    public let pointer: CGPoint?
    public let elements: [UIElementCandidate]
    public let screenshotPath: String?

    public init(
        captureID: UUID,
        timestamp: Date,
        activeApp: AppReference,
        window: WindowReference,
        focusedElementID: String?,
        pointer: CGPoint?,
        elements: [UIElementCandidate],
        screenshotPath: String?
    ) {
        self.captureID = captureID
        self.timestamp = timestamp
        self.activeApp = activeApp
        self.window = window
        self.focusedElementID = focusedElementID
        self.pointer = pointer
        self.elements = elements
        self.screenshotPath = screenshotPath
    }
}

extension Observation: Codable {
    enum CodingKeys: String, CodingKey {
        case timestamp, window, pointer, elements
        case captureID = "capture_id"
        case activeApp = "active_app"
        case focusedElementID = "focused_element_id"
        case screenshotPath = "screenshot_path"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureID = try container.decode(UUID.self, forKey: .captureID)
        let rawTimestamp = try container.decode(String.self, forKey: .timestamp)
        guard let parsed = WireDate.parse(rawTimestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp, in: container,
                debugDescription: "observation timestamp is not ISO-8601: \(rawTimestamp)")
        }
        timestamp = parsed
        activeApp = try container.decode(AppReference.self, forKey: .activeApp)
        window = try container.decode(WindowReference.self, forKey: .window)
        focusedElementID = try container.decodeIfPresent(String.self, forKey: .focusedElementID)
        if let rawPointer = try container.decodeIfPresent([CGFloat].self, forKey: .pointer) {
            guard rawPointer.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .pointer, in: container, debugDescription: "pointer needs two numbers")
            }
            pointer = CGPoint(x: rawPointer[0], y: rawPointer[1])
        } else {
            pointer = nil
        }
        elements = try container.decode([UIElementCandidate].self, forKey: .elements)
        screenshotPath = try container.decodeIfPresent(String.self, forKey: .screenshotPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureID.uuidString.lowercased(), forKey: .captureID)
        try container.encode(WireDate.format(timestamp), forKey: .timestamp)
        try container.encode(activeApp, forKey: .activeApp)
        try container.encode(window, forKey: .window)
        try container.encodeIfPresent(focusedElementID, forKey: .focusedElementID)
        if let pointer {
            try container.encode([pointer.x, pointer.y], forKey: .pointer)
        }
        try container.encode(elements, forKey: .elements)
        try container.encodeIfPresent(screenshotPath, forKey: .screenshotPath)
    }
}

public struct ResolvedReference: Codable, Equatable, Sendable {
    public let phrase: String
    public let candidateID: String
    public let resolvedText: String
    public let confidence: Double
    public let provenance: [String: JSONValue]

    public init(
        phrase: String,
        candidateID: String,
        resolvedText: String,
        confidence: Double,
        provenance: [String: JSONValue]
    ) {
        self.phrase = phrase
        self.candidateID = candidateID
        self.resolvedText = resolvedText
        self.confidence = confidence
        self.provenance = provenance
    }

    enum CodingKeys: String, CodingKey {
        case phrase, confidence, provenance
        case candidateID = "candidate_id"
        case resolvedText = "resolved_text"
    }
}

public struct GroundingResult: Codable, Equatable, Sendable {
    public let references: [ResolvedReference]

    public init(references: [ResolvedReference]) {
        self.references = references
    }
}

/// Judge-facing compact form of one grounded reference. The candidate source
/// remains visible so the UI never presents a model guess as semantic fact.
public struct GroundingChip: Equatable, Sendable {
    public let phrase: String
    public let resolvedText: String
    public let source: CandidateSource
    public let confidence: Double

    public init(
        phrase: String, resolvedText: String, source: CandidateSource, confidence: Double
    ) {
        self.phrase = phrase
        self.resolvedText = resolvedText
        self.source = source
        self.confidence = confidence
    }

    public init?(reference: ResolvedReference, candidates: [UIElementCandidate]) {
        guard let candidate = candidates.first(where: { $0.id == reference.candidateID }) else {
            return nil
        }
        self.init(
            phrase: reference.phrase,
            resolvedText: reference.resolvedText,
            source: candidate.source,
            confidence: reference.confidence)
    }
}

// MARK: - Pure accessibility pruning

public struct AccessibilityNodeSnapshot: Equatable, Sendable {
    public let role: String?
    public let label: String?
    public let value: String?
    public let bounds: CGRect?
    public let actions: [String]
    public let stableAttributes: [String: String]
    public let isHidden: Bool
    public let children: [AccessibilityNodeSnapshot]

    public init(
        role: String? = nil,
        label: String? = nil,
        value: String? = nil,
        bounds: CGRect? = nil,
        actions: [String] = [],
        stableAttributes: [String: String] = [:],
        isHidden: Bool = false,
        children: [AccessibilityNodeSnapshot] = []
    ) {
        self.role = role
        self.label = label
        self.value = value
        self.bounds = bounds
        self.actions = actions
        self.stableAttributes = stableAttributes
        self.isHidden = isHidden
        self.children = children
    }
}

public enum AccessibilityCandidateBuilder {
    public static func build(
        from root: AccessibilityNodeSnapshot,
        appBundleID: String,
        visibleBounds: CGRect
    ) -> [UIElementCandidate] {
        var candidates: [UIElementCandidate] = []
        visit(
            root, path: [0], appBundleID: appBundleID,
            visibleBounds: visibleBounds, candidates: &candidates)
        return candidates
    }

    private static func visit(
        _ node: AccessibilityNodeSnapshot,
        path: [Int],
        appBundleID: String,
        visibleBounds: CGRect,
        candidates: inout [UIElementCandidate]
    ) {
        guard !node.isHidden else { return }

        if let bounds = node.bounds,
           !bounds.isEmpty,
           bounds.intersects(visibleBounds),
           isMeaningful(node)
        {
            let protected = node.role?.caseInsensitiveCompare("AXSecureTextField") == .orderedSame
            var stableAttributes = node.stableAttributes
            stableAttributes["ax_path"] = path.map(String.init).joined(separator: ".")
            if protected { stableAttributes["protected"] = "true" }
            let stableID = stableAttributes["AXIdentifier"] ?? stableAttributes["identifier"]
            candidates.append(UIElementCandidate(
                id: stableID ?? "ax-" + path.map(String.init).joined(separator: "-"),
                role: node.role,
                label: node.label,
                value: protected ? nil : node.value,
                bounds: bounds,
                source: .accessibility,
                confidence: 1,
                actions: node.actions,
                appBundleID: appBundleID,
                stableAttributes: stableAttributes))
        }

        for (index, child) in node.children.enumerated() {
            visit(
                child, path: path + [index], appBundleID: appBundleID,
                visibleBounds: visibleBounds, candidates: &candidates)
        }
    }

    private static func isMeaningful(_ node: AccessibilityNodeSnapshot) -> Bool {
        node.role != nil || node.label != nil || node.value != nil || !node.actions.isEmpty
    }
}

// MARK: - Native collector boundary and permission recovery

public struct CollectedScreenContext: Equatable, Sendable {
    public let observation: Observation
    public let screenshotFileURL: URL

    public init(observation: Observation, screenshotFileURL: URL) {
        self.observation = observation
        self.screenshotFileURL = screenshotFileURL
    }
}

public protocol ScreenContextCollecting: Sendable {
    func collect() async throws -> CollectedScreenContext
    func cleanup(captureID: UUID) async
}

public enum ScreenContextError: Error, Equatable, LocalizedError, Sendable {
    case screenRecordingDenied
    case accessibilityDenied
    case activeApplicationUnavailable
    case activeWindowUnavailable
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            "Screen Recording permission is required to ground visible references. Open System Settings → Privacy & Security → Screen & System Audio Recording, enable VoiceOps, then try again."
        case .accessibilityDenied:
            "Accessibility permission is required to read visible controls. Open System Settings → Privacy & Security → Accessibility, enable VoiceOps, then try again."
        case .activeApplicationUnavailable:
            "VoiceOps could not identify the active application. Bring the source window forward and try again."
        case .activeWindowUnavailable:
            "VoiceOps could not find an on-screen window to capture. Bring the source window forward and try again."
        case .captureFailed(let message):
            "Screen capture failed: \(message)"
        }
    }

    public var settingsURL: URL? {
        switch self {
        case .screenRecordingDenied:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibilityDenied:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        default:
            nil
        }
    }
}

private enum WireGeometry {
    static func array(_ rect: CGRect) -> [CGFloat] {
        [rect.origin.x, rect.origin.y, rect.width, rect.height]
    }

    static func decodeRect<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, key: K
    ) throws -> CGRect {
        let values = try container.decode([CGFloat].self, forKey: key)
        guard values.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "bounds need four numbers")
        }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
