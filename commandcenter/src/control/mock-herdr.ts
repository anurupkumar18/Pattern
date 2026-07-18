import type { FleetAgent, FleetSnapshot, SpawnSpec } from "../contracts.js";
import type {
  ControlReceipt,
  FleetControl,
  FleetSnapshotHandler,
} from "./fleet-control.js";

export interface MockHerdrOptions {
  agents?: FleetAgent[];
  focusedAgentId?: string | null;
  listening?: boolean;
  latencyMs?: number;
  now?: () => Date;
}

export class MockHerdr implements FleetControl {
  private agents: FleetAgent[];
  private focusedAgentId: string | null;
  private listening: boolean;
  private readonly latencyMs: number;
  private readonly now: () => Date;
  private readonly subscribers = new Set<FleetSnapshotHandler>();
  private nextAgentNumber = 1;

  constructor(options: MockHerdrOptions = {}) {
    this.agents = structuredClone(options.agents ?? []);
    this.focusedAgentId = options.focusedAgentId ?? null;
    this.listening = options.listening ?? true;
    this.latencyMs = options.latencyMs ?? 2;
    this.now = options.now ?? (() => new Date());
  }

  async snapshot(): Promise<FleetSnapshot> {
    await this.delay();
    return this.currentSnapshot();
  }

  async focus(agentId: string): Promise<ControlReceipt> {
    await this.delay();
    this.requireAgent(agentId);
    this.focusedAgentId = agentId;
    this.emit();
    return { ok: true, evidence: `focused ${agentId}`, agentId };
  }

  async send(agentId: string, text: string): Promise<ControlReceipt> {
    await this.delay();
    const agent = this.requireAgent(agentId);
    agent.status = "working";
    agent.lastActivity = {
      summary: `Message: ${text}`,
      at: this.now().toISOString(),
    };
    this.emit();
    return { ok: true, evidence: `sent text to ${agentId}`, agentId };
  }

  async spawn(spec: SpawnSpec): Promise<ControlReceipt> {
    await this.delay();
    const id = `mock-${this.nextAgentNumber++}`;
    const agent: FleetAgent = {
      id,
      name: spec.name ?? `${spec.harness} ${this.nextAgentNumber - 1}`,
      harness: spec.harness,
      status: "working",
      cwd: spec.cwd,
      lastActivity: {
        summary: spec.initialMessage
          ? `Message: ${spec.initialMessage}`
          : `Started ${spec.harness}`,
        at: this.now().toISOString(),
      },
    };
    this.agents.push(agent);
    this.focusedAgentId = id;
    this.emit();
    return { ok: true, evidence: `spawned ${id}`, agentId: id };
  }

  async interrupt(agentId: string): Promise<ControlReceipt> {
    await this.delay();
    const agent = this.requireAgent(agentId);
    agent.status = "idle";
    agent.lastActivity = {
      summary: "Interrupted",
      at: this.now().toISOString(),
    };
    this.emit();
    return { ok: true, evidence: `interrupted ${agentId}`, agentId };
  }

  subscribe(handler: FleetSnapshotHandler): () => void {
    this.subscribers.add(handler);
    queueMicrotask(() => handler(this.currentSnapshot()));
    return () => this.subscribers.delete(handler);
  }

  setListening(listening: boolean): void {
    this.listening = listening;
    this.emit();
  }

  private requireAgent(agentId: string): FleetAgent {
    const agent = this.agents.find((candidate) => candidate.id === agentId);
    if (!agent) {
      throw new Error(`agent not found: ${agentId}`);
    }
    return agent;
  }

  private currentSnapshot(): FleetSnapshot {
    return {
      capturedAt: this.now().toISOString(),
      agents: structuredClone(this.agents),
      focusedAgentId: this.focusedAgentId,
      listening: this.listening,
    };
  }

  private emit(): void {
    const snapshot = this.currentSnapshot();
    for (const subscriber of this.subscribers) {
      subscriber(structuredClone(snapshot));
    }
  }

  private async delay(): Promise<void> {
    if (this.latencyMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, this.latencyMs));
    }
  }
}
