import { randomUUID } from "node:crypto";

import {
  CommandOutcomeSchema,
  type CommandOutcome,
  type ExecutorResult,
  type FleetCommand,
  type FleetSnapshot,
} from "../contracts.js";
import type {
  ControlReceipt,
  FleetControl,
} from "../control/fleet-control.js";
import type { Router } from "../router/router.js";
import { Verifier } from "./verifier.js";

export type CommandLoopEvent =
  | {
      type: "command.routed";
      command: FleetCommand;
      latencyMs: number;
    }
  | { type: "command.outcome"; outcome: CommandOutcome }
  | { type: "fleet.snapshot"; snapshot: FleetSnapshot };

export interface HandleUtteranceOptions {
  sttMs?: number;
}

export interface CommandLoopOptions {
  router: Router;
  control: FleetControl;
  verifier?: Verifier;
  confirmationThreshold?: number;
  now?: () => Date;
  clock?: () => number;
}

interface PendingCommand {
  command: FleetCommand;
  routeMs: number;
  sttMs: number;
}

export class CommandLoop {
  private readonly router: Router;
  private readonly control: FleetControl;
  private readonly verifier: Verifier;
  private readonly confirmationThreshold: number;
  private readonly now: () => Date;
  private readonly clock: () => number;
  private readonly pending = new Map<string, PendingCommand>();
  private readonly subscribers = new Set<(event: CommandLoopEvent) => void>();

  constructor(options: CommandLoopOptions) {
    this.router = options.router;
    this.control = options.control;
    this.verifier = options.verifier ?? new Verifier(options.control);
    this.confirmationThreshold = options.confirmationThreshold ?? 0.7;
    this.now = options.now ?? (() => new Date());
    this.clock = options.clock ?? (() => performance.now());
  }

  async handleUtterance(
    utterance: string,
    options: HandleUtteranceOptions = {},
  ): Promise<CommandOutcome> {
    const snapshot = await this.control.snapshot();
    this.emit({ type: "fleet.snapshot", snapshot });
    const routeStarted = this.clock();
    const command = await this.router.route(utterance, snapshot);
    const routeMs = this.clock() - routeStarted;
    this.emit({ type: "command.routed", command, latencyMs: routeMs });
    const id = randomUUID();
    const sttMs = options.sttMs ?? 0;

    if (this.requiresConfirmation(command)) {
      this.pending.set(id, { command, routeMs, sttMs });
      const outcome = this.outcome({
        id,
        command,
        state: "AWAITING_CONFIRMATION",
        executor: null,
        verification: [],
        latencyMs: { stt: sttMs, route: routeMs, act: 0, verify: 0 },
      });
      this.emit({ type: "command.outcome", outcome });
      return outcome;
    }

    return this.execute(id, command, routeMs, sttMs, snapshot);
  }

  async confirm(outcomeId: string): Promise<CommandOutcome> {
    const pending = this.pending.get(outcomeId);
    if (!pending) {
      throw new Error(`no pending confirmation: ${outcomeId}`);
    }
    this.pending.delete(outcomeId);
    const before = await this.control.snapshot();
    return this.execute(
      outcomeId,
      pending.command,
      pending.routeMs,
      pending.sttMs,
      before,
    );
  }

  cancelConfirmation(outcomeId: string): boolean {
    return this.pending.delete(outcomeId);
  }

  subscribe(handler: (event: CommandLoopEvent) => void): () => void {
    this.subscribers.add(handler);
    return () => this.subscribers.delete(handler);
  }

  private async execute(
    id: string,
    command: FleetCommand,
    routeMs: number,
    sttMs: number,
    before: FleetSnapshot,
  ): Promise<CommandOutcome> {
    const actStarted = this.clock();
    let executor: ControlReceipt;
    try {
      executor = await this.executeCommand(command);
    } catch (error) {
      const failed = this.outcome({
        id,
        command,
        state: "FAILED",
        executor: {
          ok: false,
          evidence: "executor threw before verification",
          error: error instanceof Error ? error.message : String(error),
        },
        verification: [],
        latencyMs: {
          stt: sttMs,
          route: routeMs,
          act: this.clock() - actStarted,
          verify: 0,
        },
      });
      this.emit({ type: "command.outcome", outcome: failed });
      return failed;
    }
    const actMs = this.clock() - actStarted;

    if (!executor.ok) {
      const failed = this.outcome({
        id,
        command,
        state: "FAILED",
        executor,
        verification: [],
        latencyMs: {
          stt: sttMs,
          route: routeMs,
          act: actMs,
          verify: 0,
        },
      });
      this.emit({ type: "command.outcome", outcome: failed });
      return failed;
    }

    const executed = this.outcome({
      id,
      command,
      state: "EXECUTED",
      executor,
      verification: [],
      latencyMs: {
        stt: sttMs,
        route: routeMs,
        act: actMs,
        verify: 0,
      },
    });
    this.emit({ type: "command.outcome", outcome: executed });

    const verifyStarted = this.clock();
    const report = await this.verifier.verify(command, before, executor);
    const verifyMs = this.clock() - verifyStarted;
    const passed =
      report.results.length > 0 &&
      report.results.every((verification) => verification.passed);
    const outcome = this.outcome({
      id,
      command,
      state: passed ? "SUCCEEDED" : "UNVERIFIED",
      executor,
      verification: report.results,
      latencyMs: {
        stt: sttMs,
        route: routeMs,
        act: actMs,
        verify: verifyMs,
      },
    });
    this.emit({ type: "fleet.snapshot", snapshot: report.snapshot });
    this.emit({ type: "command.outcome", outcome });
    return outcome;
  }

  private executeCommand(command: FleetCommand): Promise<ControlReceipt> {
    switch (command.verb) {
      case "status":
        return Promise.resolve({
          ok: true,
          evidence: "status requires no mutation",
        });
      case "focus":
        return this.control.focus(command.payload.agentId);
      case "send":
      case "dictate":
        return this.control.send(
          command.payload.agentId,
          command.payload.text,
        );
      case "spawn":
        return this.control.spawn(command.payload);
      case "interrupt":
        return this.control.interrupt(command.payload.agentId);
      case "listen_ctl":
        return Promise.resolve(
          this.control.setListening(command.payload.action === "start"),
        ).then(() => ({
          ok: true,
          evidence: `listening ${command.payload.action}`,
        }));
      case "noise":
        return Promise.resolve({
          ok: true,
          evidence: "noise intentionally caused no action",
        });
    }
  }

  private requiresConfirmation(command: FleetCommand): boolean {
    return (
      command.verb === "interrupt" ||
      command.confidence < this.confirmationThreshold
    );
  }

  private outcome(
    value: Omit<CommandOutcome, "createdAt"> & {
      executor: ExecutorResult | null;
    },
  ): CommandOutcome {
    return CommandOutcomeSchema.parse({
      ...value,
      createdAt: this.now().toISOString(),
    });
  }

  private emit(event: CommandLoopEvent): void {
    for (const subscriber of this.subscribers) subscriber(event);
  }
}
