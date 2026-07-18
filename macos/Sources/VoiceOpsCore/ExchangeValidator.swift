import Foundation

/// Client-side judgment of a Phase 0 mock exchange. The sidecar's claim alone
/// is never enough: a completion that says "succeeded" without unanimous
/// passing verification is rejected here too (CLAUDE.md invariant 2).
public enum ExchangeValidator {
    public struct Exchange: Sendable {
        public let plan: TaskPlan
        public let completion: TaskCompleted
    }

    public enum Outcome: Sendable {
        case success(Exchange)
        case failure(String)
    }

    public static func validate(responses: [Envelope], requestTaskID: UUID) -> Outcome {
        if case .taskFailed(let failure)? = responses.first?.payload {
            return .failure(
                "sidecar rejected the request: \(failure.error.code): \(failure.error.message)")
        }

        guard responses.count == 2,
              case .planReady(let plan) = responses[0].payload,
              case .taskCompleted(let completion) = responses[1].payload
        else {
            let types = responses.map(\.type.rawValue).joined(separator: ", ")
            return .failure("expected plan.ready then task.completed, got: [\(types)]")
        }

        if let mismatch = responses.first(where: { $0.taskID != requestTaskID }) {
            return .failure(
                "task_id mismatch: request \(requestTaskID.uuidString.lowercased()) "
                + "vs response \(mismatch.taskID.uuidString.lowercased())")
        }

        if completion.state == .succeeded,
           completion.verification.isEmpty || !completion.verification.allSatisfy(\.passed) {
            return .failure(
                "completion claims success without unanimous passing verification")
        }

        return .success(Exchange(plan: plan, completion: completion))
    }
}
