import CoreGraphics
import XCTest
@testable import VoiceOpsCore

final class ScreenContextTests: XCTestCase {
    private let windowBounds = CGRect(x: 100, y: 100, width: 900, height: 700)

    func testCandidateBuilderPrunesHiddenAndOffscreenNodes() {
        let root = AccessibilityNodeSnapshot(
            role: "AXWindow", label: "Hackathon details", bounds: windowBounds,
            children: [
                AccessibilityNodeSnapshot(
                    role: "AXStaticText", label: "July 31, 2026",
                    bounds: CGRect(x: 160, y: 220, width: 120, height: 20)),
                AccessibilityNodeSnapshot(
                    role: "AXStaticText", label: "Hidden instruction",
                    bounds: CGRect(x: 160, y: 250, width: 120, height: 20), isHidden: true),
                AccessibilityNodeSnapshot(
                    role: "AXButton", label: "Background button",
                    bounds: CGRect(x: 1200, y: 250, width: 120, height: 20)),
            ])

        let candidates = AccessibilityCandidateBuilder.build(
            from: root, appBundleID: "com.apple.mail", visibleBounds: windowBounds)

        XCTAssertEqual(candidates.map(\.label), ["Hackathon details", "July 31, 2026"])
        XCTAssertTrue(candidates.allSatisfy { $0.source == .accessibility })
        XCTAssertTrue(candidates.allSatisfy { $0.bounds.intersects(windowBounds) })
    }

    func testCandidateBuilderRedactsSecureTextValues() throws {
        let root = AccessibilityNodeSnapshot(
            role: "AXSecureTextField", label: "Password", value: "do-not-leak",
            bounds: CGRect(x: 140, y: 180, width: 200, height: 24),
            stableAttributes: ["AXIdentifier": "password-field"])

        let candidate = try XCTUnwrap(AccessibilityCandidateBuilder.build(
            from: root, appBundleID: "com.example", visibleBounds: windowBounds).first)

        XCTAssertNil(candidate.value)
        XCTAssertEqual(candidate.stableAttributes["protected"], "true")
    }

    func testPermissionErrorsContainActionableSettingsDestinations() throws {
        for error in [ScreenContextError.screenRecordingDenied, .accessibilityDenied] {
            XCTAssertTrue(error.localizedDescription.contains("System Settings"))
            XCTAssertNotNil(error.settingsURL)
        }
        XCTAssertTrue(
            try XCTUnwrap(ScreenContextError.screenRecordingDenied.settingsURL?.absoluteString)
                .contains("Privacy_ScreenCapture"))
        XCTAssertTrue(
            try XCTUnwrap(ScreenContextError.accessibilityDenied.settingsURL?.absoluteString)
                .contains("Privacy_Accessibility"))
    }

    func testGroundingChipCarriesVisibleTextAndProvenanceSource() {
        let candidate = UIElementCandidate(
            id: "deadline", role: "AXStaticText", label: "Deadline",
            value: "July 31, 2026", bounds: CGRect(x: 1, y: 2, width: 3, height: 4),
            source: .accessibility, confidence: 1, actions: [],
            appBundleID: "com.apple.mail", stableAttributes: [:])
        let reference = ResolvedReference(
            phrase: "that deadline", candidateID: "deadline",
            resolvedText: "July 31, 2026", confidence: 0.99,
            provenance: ["source": .string("accessibility")])

        XCTAssertEqual(GroundingChip(reference: reference, candidates: [candidate]), GroundingChip(
            phrase: "that deadline", resolvedText: "July 31, 2026",
            source: .accessibility, confidence: 0.99))
    }
}
