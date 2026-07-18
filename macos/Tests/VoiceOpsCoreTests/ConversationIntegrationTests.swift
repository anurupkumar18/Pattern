import XCTest
@testable import VoiceOpsCore

final class ConversationIntegrationTests: XCTestCase {
    func testConversationModeRequiresBothPreferenceAndCredential() {
        XCTAssertTrue(ConversationModePolicy.shouldOpen(
            preferenceEnabled: true, credentialAvailable: true))
        XCTAssertFalse(ConversationModePolicy.shouldOpen(
            preferenceEnabled: false, credentialAvailable: true))
        XCTAssertFalse(ConversationModePolicy.shouldOpen(
            preferenceEnabled: true, credentialAvailable: false))
    }

    func testFallbackPresentationIsExplicitAndTaskPreserving() {
        let fallback = ConversationFallbackPresentation(reason: "network lost")
        XCTAssertEqual(fallback.provider, "Apple Speech")
        XCTAssertEqual(fallback.status, "FALLBACK")
        XCTAssertTrue(fallback.taskStatePreserved)
        XCTAssertTrue(fallback.detail.contains("network lost"))
    }

    func testApprovalCardExtractsTheBoundHashAndActions() throws {
        let request = ApprovalRequest(
            stepID: "conversation-approval",
            description: "I will send the message. Nothing else. Confirm?",
            risk: .consequential,
            dataPreview: [
                "binding_hash": .string(String(repeating: "a", count: 64)),
                "action_ids": .array([.string("send-message"), .string("notify-ops")]),
            ])

        let card = try ConversationApprovalCard(request: request)
        XCTAssertEqual(card.bindingHash, String(repeating: "a", count: 64))
        XCTAssertEqual(card.readBack, request.description)
        XCTAssertEqual(card.actionIDs, ["send-message", "notify-ops"])
        XCTAssertEqual(card.confirmationArguments["utterance"], .string("yes"))
    }

    func testApprovalCardRejectsMissingOrMalformedBinding() {
        let request = ApprovalRequest(
            stepID: "conversation-approval", description: "Confirm?",
            risk: .consequential, dataPreview: ["binding_hash": .string("short")])
        XCTAssertThrowsError(try ConversationApprovalCard(request: request))
    }

    func testPCM16EncodingClampsAndUsesLittleEndian() {
        XCTAssertEqual(
            PCM16Codec.encode(samples: [-2, -1, 0, 0.5, 1, 2]),
            Data([0x00, 0x80, 0x00, 0x80, 0x00, 0x00, 0x00, 0x40, 0xff, 0x7f, 0xff, 0x7f]))
    }

    func testPanicStopOrderingTearsDownRealtimeBeforeSidecar() {
        XCTAssertEqual(
            ConversationTeardownPlan.panicStop,
            [.cancelRealtimeSocket, .stopAudioEngine, .flushPlayback, .cancelSidecar])
    }

    func testConversationFailureFallsBackWithoutDiscardingTaskVersion() {
        let withTask = SessionState.conversing(
            agentSpeaking: true, planVersion: 2, transcript: "change it")
        XCTAssertEqual(
            SessionStateMachine.reduce(
                withTask, .conversationFallback(objective: "Rescue order 1842")),
            .readyForCorrection(
                objective: "Rescue order 1842", version: 2, groundingChips: []))

        let beforeCompile = SessionState.conversing(
            agentSpeaking: false, planVersion: nil, transcript: "take care of this")
        XCTAssertEqual(
            SessionStateMachine.reduce(
                beforeCompile, .conversationFallback(objective: nil)),
            .listening(transcript: "take care of this"))
    }
}
