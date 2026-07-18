import type {
  FleetAgent,
  FleetSnapshot,
  HarnessSchema,
  SpawnSpec,
} from "../contracts.js";
import type { z } from "zod";
import type {
  ControlReceipt,
  FleetControl,
  FleetSnapshotHandler,
} from "./fleet-control.js";
import type { HerdrTransport } from "./herdr-transport.js";

type Harness = z.infer<typeof HarnessSchema>;

interface RawAgent {
  agent?: string | null;
  agent_status?: string;
  cwd?: string | null;
  display_agent?: string | null;
  focused?: boolean;
  foreground_cwd?: string | null;
  name?: string | null;
  pane_id?: string;
  state_labels?: Record<string, string>;
  terminal_title_stripped?: string | null;
}

interface RawPane {
  pane_id?: string;
  workspace_id?: string;
}

interface RawSnapshot {
  agents?: RawAgent[];
  focused_pane_id?: string | null;
  panes?: RawPane[];
}

export interface HerdrAdapterOptions {
  transport: HerdrTransport;
  listening?: boolean;
  now?: () => Date;
}

export class HerdrAdapter implements FleetControl {
  private readonly transport: HerdrTransport;
  private readonly now: () => Date;
  private listening: boolean;

  constructor(options: HerdrAdapterOptions) {
    this.transport = options.transport;
    this.listening = options.listening ?? true;
    this.now = options.now ?? (() => new Date());
  }

  async snapshot(): Promise<FleetSnapshot> {
    const raw = await this.readRawSnapshot();
    const capturedAt = this.now().toISOString();
    return {
      capturedAt,
      agents: (raw.agents ?? []).flatMap((agent) => {
        const mapped = this.mapAgent(agent, capturedAt);
        return mapped ? [mapped] : [];
      }),
      focusedAgentId: raw.focused_pane_id ?? null,
      listening: this.listening,
    };
  }

  async focus(agentId: string): Promise<ControlReceipt> {
    await this.transport.request("agent.focus", { target: agentId });
    return { ok: true, evidence: `Herdr focused ${agentId}`, agentId };
  }

  async send(agentId: string, text: string): Promise<ControlReceipt> {
    await this.transport.request("agent.send", { target: agentId, text });
    return { ok: true, evidence: `Herdr sent text to ${agentId}`, agentId };
  }

  async spawn(spec: SpawnSpec): Promise<ControlReceipt> {
    const workspaceResult = asRecord(
      await this.transport.request("workspace.create", {
        cwd: spec.cwd,
        label: spec.name ?? `${spec.harness} agent`,
        focus: true,
      }),
    );
    const workspace = asRecord(workspaceResult.workspace);
    const workspaceId = requiredString(
      workspace.workspace_id,
      "workspace.create result.workspace.workspace_id",
    );

    const rawSnapshot = await this.readRawSnapshot();
    const pane = (rawSnapshot.panes ?? []).find(
      (candidate) => candidate.workspace_id === workspaceId,
    );
    const paneId = requiredString(
      pane?.pane_id,
      `pane in workspace ${workspaceId}`,
    );

    const startResult = asRecord(
      await this.transport.request("agent.start", {
        name: spec.name ?? `${spec.harness} agent`,
        kind: spec.harness,
        pane_id: paneId,
        args: [],
        timeout_ms: 30_000,
      }),
    );
    const startedAgent = asRecord(startResult.agent);
    const agentId =
      typeof startedAgent.pane_id === "string"
        ? startedAgent.pane_id
        : paneId;

    if (spec.initialMessage) {
      await this.transport.request("agent.send", {
        target: agentId,
        text: spec.initialMessage,
      });
    }

    return {
      ok: true,
      evidence: `Herdr started ${spec.harness} in ${workspaceId}`,
      agentId,
    };
  }

  async interrupt(agentId: string): Promise<ControlReceipt> {
    await this.transport.request("pane.send_keys", {
      pane_id: agentId,
      keys: ["ctrl+c"],
    });
    return { ok: true, evidence: `Herdr sent ctrl+c to ${agentId}`, agentId };
  }

  subscribe(handler: FleetSnapshotHandler): () => void {
    let active = true;
    const unsubscribe = this.transport.subscribe(
      [
        { type: "pane.created" },
        { type: "pane.closed" },
        { type: "pane.focused" },
        { type: "pane.updated" },
        { type: "pane.agent_status_changed" },
      ],
      () => {
        void this.snapshot().then((snapshot) => {
          if (active) handler(snapshot);
        });
      },
    );
    void this.snapshot().then((snapshot) => {
      if (active) handler(snapshot);
    });
    return () => {
      active = false;
      unsubscribe();
    };
  }

  setListening(listening: boolean): void {
    this.listening = listening;
  }

  private async readRawSnapshot(): Promise<RawSnapshot> {
    const result = asRecord(
      await this.transport.request("session.snapshot", {}),
    );
    return asRecord(result.snapshot) as RawSnapshot;
  }

  private mapAgent(agent: RawAgent, capturedAt: string): FleetAgent | null {
    if (!agent.pane_id) return null;
    const rawStatus = agent.agent_status ?? "unknown";
    const status =
      rawStatus === "working" ||
      rawStatus === "blocked" ||
      rawStatus === "done" ||
      rawStatus === "idle"
        ? rawStatus
        : "idle";
    const summary =
      agent.terminal_title_stripped ??
      agent.state_labels?.[rawStatus] ??
      `${agent.agent ?? "agent"} is ${rawStatus}`;

    return {
      id: agent.pane_id,
      name:
        agent.name ??
        agent.display_agent ??
        agent.agent ??
        `Agent ${agent.pane_id}`,
      harness: mapHarness(agent.agent),
      status,
      cwd: agent.foreground_cwd ?? agent.cwd ?? ".",
      lastActivity: { summary, at: capturedAt },
    };
  }
}

function mapHarness(agent: string | null | undefined): Harness {
  if (agent === "claude" || agent === "codex" || agent === "gemini") {
    return agent;
  }
  if (!agent) return "other";
  return agent === "shell" ? "shell" : "other";
}

function asRecord(value: unknown): Record<string, any> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Herdr returned an unexpected response shape");
  }
  return value as Record<string, any>;
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Herdr response missing ${field}`);
  }
  return value;
}
