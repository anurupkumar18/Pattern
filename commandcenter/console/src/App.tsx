import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { CommandOutcome } from "../../src/contracts.js";
import { ChatSwitcher } from "./components/ChatSwitcher.js";
import { CommandBar, type StagedCommand } from "./components/CommandBar.js";
import { MainPane } from "./components/MainPane.js";
import { Sidebar } from "./components/Sidebar.js";
import { ToastViewport, type Toast } from "./components/Toasts.js";
import { VerbChips, type ChipFx } from "./components/VerbChips.js";
import { SourceGlyph } from "./components/icons.js";
import {
  chipForVerb,
  isCancelWord,
  isSendWord,
  previewParse,
  type ChipId,
} from "./grammar.js";
import {
  attentionItems,
  buildRows,
  groupRows,
  loadObservedAt,
  loadSeen,
  persistObservedAt,
  persistSeen,
  type HistoryRow,
} from "./model.js";
import { useProtocol, type RoutedEvent } from "./useProtocol.js";
import { useSpeechRecognition } from "./useSpeechRecognition.js";

interface StagedState extends StagedCommand {
  chip: ChipId | null;
  targetRowId: string | null;
}

const CHAT_REFRESH_MS = 2_500;

export function App() {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [seen, setSeen] = useState<Record<string, number>>(loadSeen);
  const sessionOpenedAt = useRef(Date.now());
  const [observedAt] = useState(() => loadObservedAt(sessionOpenedAt.current));
  const [chipFx, setChipFx] = useState<ChipFx>({ pulseAt: {}, shakeAt: {} });
  const [armedChip, setArmedChip] = useState<ChipId | null>(null);
  const [staged, setStaged] = useState<StagedState | null>(null);
  const [captureTarget, setCaptureTarget] = useState<string | null>(null);
  const [rowGlow, setRowGlow] = useState<{ id: string; key: number } | null>(
    null,
  );
  const [switcherOpen, setSwitcherOpen] = useState(false);
  const [toasts, setToasts] = useState<Toast[]>([]);

  const searchRef = useRef<HTMLInputElement>(null);
  const composerRef = useRef<HTMLTextAreaElement>(null);
  const stagedRef = useRef<StagedState | null>(null);
  const dispatchTimer = useRef<number | undefined>(undefined);
  const rowsRef = useRef<HistoryRow[]>([]);
  stagedRef.current = staged;

  const pulseChip = useCallback((chip: ChipId) => {
    setChipFx((current) => ({
      ...current,
      pulseAt: { ...current.pulseAt, [chip]: Date.now() },
    }));
  }, []);

  const shakeChip = useCallback((chip: ChipId) => {
    setChipFx((current) => ({
      ...current,
      shakeAt: { ...current.shakeAt, [chip]: Date.now() },
    }));
  }, []);

  const glowRow = useCallback((id: string) => {
    setRowGlow({ id, key: Date.now() });
  }, []);

  const onRouted = useCallback(
    (event: RoutedEvent) => {
      const chip = chipForVerb(event.command.verb);
      if (chip) {
        pulseChip(chip);
        if (event.command.resolvedTargetId) {
          glowRow(event.command.resolvedTargetId);
        } else if (
          event.command.verb === "focus" ||
          event.command.verb === "send" ||
          event.command.verb === "dictate" ||
          event.command.verb === "interrupt"
        ) {
          // Verb matched but the router could not resolve a target.
          shakeChip(chip);
        }
      } else {
        // Router returned noise. If we were verb-armed (or our own preview
        // matched a verb), that is a "heard you, couldn't do it" signal.
        const guess =
          armedChip ??
          previewParse(event.command.rawUtterance, rowsRef.current).chip;
        if (guess) shakeChip(guess);
      }
      setArmedChip(null);
    },
    [armedChip, glowRow, pulseChip, shakeChip],
  );

  const onOutcome = useCallback(
    (outcome: CommandOutcome) => {
      if (outcome.state === "FAILED") {
        const chip = chipForVerb(outcome.command.verb);
        if (chip) shakeChip(chip);
        pushToast({
          id: `fail-${outcome.id}`,
          source: null,
          title: "Command failed",
          body: outcome.executor?.error ?? outcome.command.rawUtterance,
          kind: "failed",
        });
      }
      if (
        outcome.state === "SUCCEEDED" &&
        outcome.command.verb === "focus" &&
        outcome.command.resolvedTargetId
      ) {
        setSelectedId(outcome.command.resolvedTargetId);
      }
    },
    [shakeChip],
  );

  const protocol = useProtocol({ onRouted, onOutcome });
  const {
    connection,
    snapshot,
    chats,
    outcomes,
    pending,
    transcript,
    serverError,
    submitUtterance,
    confirm,
    selectChatMessages,
    refreshChatMessages,
    clearChatMessages,
    dismissPending,
  } = protocol;

  const rows = useMemo(
    () => buildRows(snapshot, chats, seen, Date.now(), observedAt),
    [snapshot, chats, seen, observedAt],
  );
  rowsRef.current = rows;

  useEffect(() => {
    if (chats.length > 0) persistObservedAt(sessionOpenedAt.current);
  }, [chats.length]);

  const filteredRows = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return rows;
    return rows.filter((row) => row.title.toLowerCase().includes(needle));
  }, [rows, query]);

  const sections = useMemo(() => groupRows(filteredRows), [filteredRows]);
  const attention = useMemo(() => attentionItems(rows), [rows]);
  const selected =
    rows.find((row) => row.id === selectedId) ??
    rows.find((row) => row.focused) ??
    null;
  const focusedAgent =
    snapshot?.agents.find((agent) => agent.id === snapshot.focusedAgentId) ??
    null;

  useEffect(() => {
    if (
      selected?.kind !== "chat" ||
      (selected.source !== "cursor" &&
        selected.source !== "claude" &&
        selected.source !== "codex")
    ) {
      clearChatMessages();
      return;
    }
    selectChatMessages(selected.source, selected.id);
    const timer = window.setInterval(refreshChatMessages, CHAT_REFRESH_MS);
    return () => window.clearInterval(timer);
  }, [
    clearChatMessages,
    refreshChatMessages,
    selectChatMessages,
    selected?.id,
    selected?.kind,
    selected?.source,
  ]);

  function pushToast(toast: Toast) {
    setToasts((current) => [toast, ...current].slice(0, 2));
  }

  const dismissToast = useCallback((id: string) => {
    setToasts((current) => current.filter((toast) => toast.id !== id));
  }, []);

  // Toast when an agent newly needs input (delayed per spec; suppressed when
  // that row is already selected).
  const priorNeedsInput = useRef<Set<string>>(new Set());
  useEffect(() => {
    const now = new Set(
      rows.filter((row) => row.needsInput).map((row) => row.id),
    );
    for (const id of now) {
      if (!priorNeedsInput.current.has(id) && id !== selectedId) {
        const row = rows.find((candidate) => candidate.id === id);
        if (row) {
          const timer = window.setTimeout(() => {
            pushToast({
              id: `attn-${id}-${Date.now()}`,
              source: row.source,
              title: row.title,
              body: row.subtitle ?? "Waiting on you",
              kind: "needs-input",
              onOpen: () => selectRow(row),
            });
          }, 900);
          window.setTimeout(() => window.clearTimeout(timer), 950);
        }
      }
    }
    priorNeedsInput.current = now;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, selectedId]);

  const selectRow = useCallback(
    (row: HistoryRow) => {
      setSelectedId(row.id);
      setSwitcherOpen(false);
      if (row.doneUnseen) {
        setSeen((current) => {
          const next = { ...current, [row.id]: Date.now() };
          persistSeen(next);
          return next;
        });
      }
      if (row.kind === "agent") {
        submitUtterance(`focus ${row.spokenName}`);
      }
    },
    [submitUtterance],
  );

  const cancelStaged = useCallback(() => {
    window.clearTimeout(dispatchTimer.current);
    setStaged(null);
  }, []);

  const dispatchStaged = useCallback(() => {
    const current = stagedRef.current;
    if (!current) return;
    window.clearTimeout(dispatchTimer.current);
    setStaged(null);
    submitUtterance(current.utterance);
  }, [submitUtterance]);

  /** Parse-before-act: preview the parse, hold, then dispatch. */
  const stageUtterance = useCallback(
    (utterance: string) => {
      const parse = previewParse(utterance, rowsRef.current);
      if (!parse.chip || parse.holdMs === 0) {
        submitUtterance(utterance);
        return;
      }
      window.clearTimeout(dispatchTimer.current);
      if (parse.targetRowId) glowRow(parse.targetRowId);
      setArmedChip(null);
      setStaged({
        utterance,
        preview: parse.preview,
        targetName: parse.targetName,
        targetRowId: parse.targetRowId,
        holdMs: parse.holdMs,
        chip: parse.chip,
        key: Date.now(),
      });
      dispatchTimer.current = window.setTimeout(() => {
        dispatchStaged();
      }, parse.holdMs);
    },
    [dispatchStaged, glowRow, submitUtterance],
  );

  const onFinalSpeech = useCallback(
    (text: string) => {
      if (stagedRef.current) {
        if (isCancelWord(text)) {
          cancelStaged();
          return;
        }
        if (isSendWord(text)) {
          dispatchStaged();
          return;
        }
      }
      if (isCancelWord(text)) return;
      stageUtterance(text);
    },
    [cancelStaged, dispatchStaged, stageUtterance],
  );

  const speech = useSpeechRecognition(onFinalSpeech);

  // Lock the message target when voice capture begins. Moving the visual
  // selection while listening cannot silently redirect the transcript.
  useEffect(() => {
    if (speech.listening) {
      setCaptureTarget(
        (current) => current ?? selected?.title ?? focusedAgent?.name ?? null,
      );
    } else {
      setCaptureTarget(null);
    }
  }, [
    focusedAgent?.name,
    selected?.id,
    selected?.title,
    speech.listening,
  ]);

  // Interim speech drives the verb-armed (listening-for-target) chip state.
  useEffect(() => {
    if (!speech.interim) {
      if (!stagedRef.current) setArmedChip(null);
      return;
    }
    const parse = previewParse(speech.interim, rowsRef.current);
    setArmedChip(parse.chip && !parse.targetRowId ? parse.chip : null);
  }, [speech.interim]);

  const activateChip = useCallback(
    (chip: ChipId) => {
      pulseChip(chip);
      switch (chip) {
        case "move":
          setSwitcherOpen(true);
          break;
        case "send":
          if (stagedRef.current) dispatchStaged();
          else composerRef.current?.focus();
          break;
        case "attention": {
          const first = attentionItems(rowsRef.current)[0];
          if (first) selectRow(first.row);
          break;
        }
        case "interrupt": {
          const target =
            rowsRef.current.find((row) => row.id === selectedId) ??
            rowsRef.current.find((row) => row.focused) ??
            null;
          if (target?.kind === "agent") {
            submitUtterance(`interrupt ${target.spokenName}`);
          }
          break;
        }
        case "new":
          stageUtterance("start a claude chat");
          break;
        case "voice":
          if (speech.listening) speech.stop();
          else speech.start();
          break;
      }
    },
    [
      dispatchStaged,
      pulseChip,
      selectRow,
      selectedId,
      speech,
      stageUtterance,
      submitUtterance,
    ],
  );

  const composerSubmit = useCallback(
    (text: string) => {
      const parse = previewParse(text, rowsRef.current);
      if (parse.chip) {
        stageUtterance(text);
        return;
      }
      const target = rowsRef.current.find((row) => row.id === selectedId);
      if (target?.kind === "agent") {
        stageUtterance(`send ${target.spokenName} ${text}`);
      } else {
        submitUtterance(text);
      }
    },
    [selectedId, stageUtterance, submitUtterance],
  );

  // Keyboard layer: one grammar, two input methods.
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      const inField =
        event.target instanceof HTMLInputElement ||
        event.target instanceof HTMLTextAreaElement;
      if (event.key === "Escape") {
        if (stagedRef.current) {
          event.preventDefault();
          cancelStaged();
        } else if (switcherOpen) {
          setSwitcherOpen(false);
        } else if (pending) {
          dismissPending();
        }
        return;
      }
      if (event.metaKey && event.key.toLowerCase() === "k") {
        event.preventDefault();
        pulseChip("move");
        setSwitcherOpen((value) => !value);
        return;
      }
      if (event.altKey && event.code === "Space") {
        event.preventDefault();
        activateChip("voice");
        return;
      }
      if (event.metaKey && event.key === "Enter") {
        event.preventDefault();
        pulseChip("send");
        if (stagedRef.current) {
          dispatchStaged();
        } else {
          composerRef.current?.form?.requestSubmit();
        }
        return;
      }
      if (event.metaKey && event.key.toLowerCase() === "n") {
        event.preventDefault();
        activateChip("new");
        return;
      }
      if (event.metaKey && event.key === ".") {
        event.preventDefault();
        activateChip("interrupt");
        return;
      }
      if (inField || event.metaKey || event.altKey || event.ctrlKey) return;
      if (event.key.toLowerCase() === "n") {
        event.preventDefault();
        activateChip("attention");
      } else if (event.key === "j" || event.key === "ArrowDown") {
        event.preventDefault();
        moveSelection(1);
      } else if (event.key === "k" || event.key === "ArrowUp") {
        event.preventDefault();
        moveSelection(-1);
      } else if (event.key === "/") {
        event.preventDefault();
        searchRef.current?.focus();
      }
    }
    function moveSelection(delta: number) {
      const flat = rowsRef.current;
      if (flat.length === 0) return;
      const currentIndex = flat.findIndex((row) => row.id === selectedId);
      const nextIndex = Math.min(
        Math.max(currentIndex + delta, 0),
        flat.length - 1,
      );
      const next = flat[nextIndex];
      if (next) selectRow(next);
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [
    activateChip,
    cancelStaged,
    dismissPending,
    dispatchStaged,
    pending,
    pulseChip,
    selectRow,
    selectedId,
    switcherOpen,
  ]);

  useEffect(() => () => window.clearTimeout(dispatchTimer.current), []);

  const stagedChip =
    staged?.chip && staged.preview
      ? { chip: staged.chip, preview: staged.preview }
      : null;

  return (
    <div className="app-shell">
      <Sidebar
        sections={sections}
        attention={attention}
        selectedId={selected?.id ?? null}
        glowRowId={rowGlow?.id ?? null}
        glowKey={rowGlow?.key ?? 0}
        query={query}
        onQueryChange={setQuery}
        onSelect={selectRow}
        onNewChat={() => activateChip("new")}
        onAttention={() => activateChip("attention")}
        voice={{
          supported: speech.supported,
          listening: speech.listening,
          error: speech.error,
          toggle: () =>
            speech.listening ? speech.stop() : speech.start(),
        }}
        searchRef={searchRef}
      />

      <main className="main-pane">
        <header className="main-topbar">
          <div className="topbar-title">
            {selected ? (
              <>
                <SourceGlyph source={selected.source} />
                <span className="topbar-name">{selected.title}</span>
                {selected.subtitle && !selected.needsInput && (
                  <span className="topbar-path">{selected.subtitle}</span>
                )}
              </>
            ) : (
              <span className="topbar-name muted">Dictator</span>
            )}
          </div>
          <VerbChips
            fx={chipFx}
            armed={armedChip}
            staged={stagedChip}
            listening={speech.listening}
            onActivate={activateChip}
          />
        </header>

        <MainPane
          selected={selected}
          connection={connection}
          outcomes={outcomes}
          snapshot={snapshot}
          transcript={transcript}
          pending={pending}
          listening={speech.listening}
          onConfirm={confirm}
          onCancelPending={dismissPending}
          onComposerSubmit={composerSubmit}
          onInterrupt={(row) => {
            if (row.kind === "agent") {
              submitUtterance(`interrupt ${row.spokenName}`);
            }
          }}
          onToggleVoice={() =>
            speech.listening ? speech.stop() : speech.start()
          }
          composerRef={composerRef}
        />

        <CommandBar
          interim={speech.interim}
          staged={staged}
          focusedName={
            captureTarget ?? selected?.title ?? focusedAgent?.name ?? null
          }
          onCancel={cancelStaged}
          onSendNow={dispatchStaged}
        />
      </main>

      {switcherOpen && (
        <ChatSwitcher
          rows={filteredRows}
          onPick={(row) => {
            setSwitcherOpen(false);
            if (row.kind === "agent") {
              stageUtterance(`switch to ${row.spokenName}`);
            } else {
              selectRow(row);
            }
          }}
          onClose={() => setSwitcherOpen(false)}
        />
      )}

      <ToastViewport toasts={toasts} onDismiss={dismissToast} />

      {serverError && <div className="server-error">{serverError}</div>}
    </div>
  );
}
