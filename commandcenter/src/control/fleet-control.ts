import type { ExecutorResult, FleetSnapshot, SpawnSpec } from "../contracts.js";

export interface ControlReceipt extends ExecutorResult {
  agentId?: string;
}

export type FleetSnapshotHandler = (snapshot: FleetSnapshot) => void;

export interface FleetControl {
  snapshot(): Promise<FleetSnapshot>;
  focus(agentId: string): Promise<ControlReceipt>;
  send(agentId: string, text: string): Promise<ControlReceipt>;
  spawn(spec: SpawnSpec): Promise<ControlReceipt>;
  interrupt(agentId: string): Promise<ControlReceipt>;
  subscribe(handler: FleetSnapshotHandler): () => void;
}
