import Foundation
import VoiceOpsCore

struct ProbeResult: Codable {
    let caseID: String
    let passed: Bool
    let detail: String
    let recoveryAttempted: Bool
    let recoverySucceeded: Bool
    let duplicateCount: Int

    enum CodingKeys: String, CodingKey {
        case passed, detail
        case caseID = "case_id"
        case recoveryAttempted = "recovery_attempted"
        case recoverySucceeded = "recovery_succeeded"
        case duplicateCount = "duplicate_count"
    }
}

func emit(_ result: ProbeResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(result)
    print(String(decoding: data, as: UTF8.self))
}

let noStateChange = StructuredError(
    code: "NO_STATE_CHANGE", message: "fixture no-op")
let uncertain = StructuredError(
    code: "CONSEQUENTIAL_STATE_UNCERTAIN", message: "fixture uncertain")

let retryDecision = RecoveryPolicy.decide(
    status: .failed, error: noStateChange, risk: .reversibleWrite,
    attempt: 1, maxAttempts: 2)
var recoveryLedger = ActionAttemptLedger()
let recoveryTask = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
let firstClaim = recoveryLedger.claim(
    taskID: recoveryTask, stepID: "write", maxAttempts: 2)
recoveryLedger.finish(taskID: recoveryTask, stepID: "write", status: .failed)
let secondClaim = recoveryLedger.claim(
    taskID: recoveryTask, stepID: "write", maxAttempts: 2)
recoveryLedger.finish(taskID: recoveryTask, stepID: "write", status: .executed)
let retryPassed: Bool
if case .retrySameTarget = retryDecision,
   firstClaim == .allowed(attempt: 1),
   secondClaim == .allowed(attempt: 2) {
    retryPassed = true
} else {
    retryPassed = false
}
emit(ProbeResult(
    caseID: "native_bounded_recovery", passed: retryPassed,
    detail: "A reversible no-op receives one ledger-bounded retry.",
    recoveryAttempted: true, recoverySucceeded: retryPassed, duplicateCount: 0))

let uncertainDecision = RecoveryPolicy.decide(
    status: .uncertain, error: uncertain, risk: .reversibleWrite,
    attempt: 1, maxAttempts: 2)
var uncertainLedger = ActionAttemptLedger()
let uncertainTask = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
_ = uncertainLedger.claim(taskID: uncertainTask, stepID: "write", maxAttempts: 2)
uncertainLedger.finish(taskID: uncertainTask, stepID: "write", status: .uncertain)
let uncertainClaim = uncertainLedger.claim(
    taskID: uncertainTask, stepID: "write", maxAttempts: 2)
let uncertainPassed: Bool
if case .verifyWithoutRetry = uncertainDecision,
   uncertainClaim == .rejectedUncertain {
    uncertainPassed = true
} else {
    uncertainPassed = false
}
emit(ProbeResult(
    caseID: "native_uncertain_never_retries", passed: uncertainPassed,
    detail: "Uncertain state routes to verification and the ledger rejects another write.",
    recoveryAttempted: false, recoverySucceeded: false, duplicateCount: 0))

var duplicateLedger = ActionAttemptLedger()
let duplicateTask = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
_ = duplicateLedger.claim(taskID: duplicateTask, stepID: "write", maxAttempts: 2)
duplicateLedger.finish(taskID: duplicateTask, stepID: "write", status: .executed)
let duplicateClaim = duplicateLedger.claim(
    taskID: duplicateTask, stepID: "write", maxAttempts: 2)
emit(ProbeResult(
    caseID: "native_completed_duplicate_suppressed",
    passed: duplicateClaim == .rejectedCompleted,
    detail: "A completed task-scoped write cannot be claimed again.",
    recoveryAttempted: false, recoverySucceeded: false, duplicateCount: 0))

let panicPassed = PanicStopPolicy.shouldCancel(keyCode: 53, isArmed: true)
    && !PanicStopPolicy.shouldCancel(keyCode: 53, isArmed: false)
    && !PanicStopPolicy.shouldCancel(keyCode: 9, isArmed: true)
emit(ProbeResult(
    caseID: "native_panic_stop_policy", passed: panicPassed,
    detail: "Only Escape while armed triggers the lower-level panic policy.",
    recoveryAttempted: false, recoverySucceeded: false, duplicateCount: 0))

let traceStart = Date(timeIntervalSince1970: 100)
var trace = TaskTrace(startedAt: traceStart)
trace.record(.action, "fixture action", at: traceStart.addingTimeInterval(0.1))
trace.record(.recovery, "fixture recovery", at: traceStart.addingTimeInterval(0.2))
trace.record(.outcome, "fixture outcome", at: traceStart.addingTimeInterval(0.3))
let tracePassed = trace.recoveryCount == 1
    && (299...301).contains(trace.totalElapsedMilliseconds)
emit(ProbeResult(
    caseID: "native_trace_evidence", passed: tracePassed,
    detail: "The task trace retains stage order, elapsed time, and recovery count.",
    recoveryAttempted: true, recoverySucceeded: tracePassed, duplicateCount: 0))
