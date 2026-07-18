import XCTest
@testable import VoiceOpsCore

final class OrderRescueDemoTests: XCTestCase {
    func testCanonicalScriptContainsTheVersionChangingDecisions() {
        XCTAssertTrue(OrderRescueDemo.initialRequest.contains("expedited replacement"))
        XCTAssertTrue(OrderRescueDemo.initialRequest.contains("remind me tomorrow"))
        XCTAssertTrue(OrderRescueDemo.correction.contains("don't create the replacement yet"))
        XCTAssertTrue(OrderRescueDemo.correction.contains("full refund"))
        XCTAssertTrue(OrderRescueDemo.correction.contains("twenty-dollar store credit"))
        XCTAssertTrue(OrderRescueDemo.correction.contains("Sarah in Slack"))
    }
}
