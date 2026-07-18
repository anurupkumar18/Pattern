import type { FleetCommand, FleetSnapshot } from "../contracts.js";

export interface Router {
  route(
    utterance: string,
    snapshot: FleetSnapshot,
  ): Promise<FleetCommand>;
}
