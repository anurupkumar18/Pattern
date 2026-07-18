import type {
  FleetCommand,
  FleetSnapshot,
  VerificationResult,
} from "../contracts.js";
import type {
  ControlReceipt,
  FleetControl,
} from "../control/fleet-control.js";

export interface VerificationReport {
  results: VerificationResult[];
  snapshot: FleetSnapshot;
}

export class Verifier {
  constructor(private readonly control: FleetControl) {}

  async verify(
    command: FleetCommand,
    before: FleetSnapshot,
    executor: ControlReceipt,
  ): Promise<VerificationReport> {
    const after = await this.control.snapshot();
    const results = this.predicates(command, before, after, executor);
    return { results, snapshot: after };
  }

  private predicates(
    command: FleetCommand,
    before: FleetSnapshot,
    after: FleetSnapshot,
    executor: ControlReceipt,
  ): VerificationResult[] {
    switch (command.verb) {
      case "status":
        return [
          result(
            "fresh fleet snapshot is readable",
            Array.isArray(after.agents),
            `${after.agents.length} agents observed at ${after.capturedAt}`,
            { agentCount: after.agents.length },
          ),
        ];
      case "focus":
        return [
          result(
            `focused agent is ${command.payload.agentId}`,
            after.focusedAgentId === command.payload.agentId,
            `focusedAgentId=${after.focusedAgentId ?? "null"}`,
            { focusedAgentId: after.focusedAgentId },
          ),
        ];
      case "send":
      case "dictate": {
        const target = after.agents.find(
          (agent) => agent.id === command.payload.agentId,
        );
        const expectedText = command.payload.text.toLowerCase();
        return [
          result(
            `target activity contains delivered text`,
            target?.lastActivity.summary.toLowerCase().includes(expectedText) ??
              false,
            target
              ? `lastActivity=${target.lastActivity.summary}`
              : "target agent absent",
            target?.lastActivity,
          ),
        ];
      }
      case "spawn": {
        const target = after.agents.find(
          (agent) =>
            agent.id === executor.agentId ||
            (agent.harness === command.payload.harness &&
              agent.cwd === command.payload.cwd &&
              (!command.payload.name ||
                agent.name === command.payload.name)),
        );
        return [
          result(
            "spawned agent exists with requested specification",
            Boolean(target),
            target
              ? `found ${target.id} (${target.harness}) in ${target.cwd}`
              : "matching agent absent",
            target,
          ),
        ];
      }
      case "interrupt": {
        const previous = before.agents.find(
          (agent) => agent.id === command.payload.agentId,
        );
        const target = after.agents.find(
          (agent) => agent.id === command.payload.agentId,
        );
        const transitioned =
          Boolean(previous && target) &&
          previous?.status !== target?.status &&
          (target?.status === "idle" || target?.status === "done");
        return [
          result(
            "agent status transitioned after interrupt",
            transitioned,
            `${previous?.status ?? "missing"} -> ${target?.status ?? "missing"}`,
            { before: previous?.status, after: target?.status },
          ),
        ];
      }
      case "listen_ctl": {
        const expected = command.payload.action === "start";
        return [
          result(
            `listening state is ${expected}`,
            after.listening === expected,
            `listening=${after.listening}`,
            { listening: after.listening },
          ),
        ];
      }
      case "noise":
        return [
          result(
            "noise caused no fleet mutation",
            equivalentState(before, after),
            "fleet state unchanged",
          ),
        ];
    }
  }
}

function result(
  predicate: string,
  passed: boolean,
  evidence: string,
  observed?: unknown,
): VerificationResult {
  return {
    predicate,
    passed,
    evidence,
    ...(observed === undefined ? {} : { observed }),
  };
}

function equivalentState(
  before: FleetSnapshot,
  after: FleetSnapshot,
): boolean {
  return (
    JSON.stringify(before.agents) === JSON.stringify(after.agents) &&
    before.focusedAgentId === after.focusedAgentId &&
    before.listening === after.listening
  );
}
