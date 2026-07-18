import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { CommandOutcome } from "../../src/contracts.js";
import { ChatSwitcher } from "./components/ChatSwitcher.js";
import { CommandBar, type StagedCommand } from "./components/CommandBar.js";
import { MainPane } from "./components/MainPane.js";
import { Sidebar } from "./components/Sidebar.js";
import { ToastViewport, type Toast } from "./components/Toasts.js";
import { SourceGlyph } from "./components/icons.js";
import {
  messageTextForTarget,
  previewParse,
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
import { useLocalSTT } from "./stt/useLocalSTT.js";
import { useProtocol, type RoutedEvent } from "./useProtocol.js";

interface StagedState extends StagedCommand {
  targetRowId: string | null;
}

const CHAT_REFRESH_MS = 2_500;

export function App() {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [seen, setSeen] = useState<Record<string, number>>(loadSeen);
  const sessionOpenedAt = useRef(Date.now());
  const [observedAt] = useState(() => loadObservedAt(sessionOpenedAt.current));
  const [staged, setStaged] = useState<StagedState | null>(null);
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

  const glowRow = useCallback((id: string) => {
    setRowGlow({ id, key: Date.now() });
  }, []);

  const onRouted = useCallback(
    (event: RoutedEvent) => {
      if (event.command.resolvedTargetId) {
        glowRow(event.command.resolvedTargetId);
      }
    },
    [glowRow],
  );

  const onOutcome = useCallback(
    (outcome: CommandOutcome) => {
      if (outcome.state === "FAILED") {
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
    [],
  );

  const protocol = useProtocol({ onRouted, onOutcome });
  const {
    connection,
    snapshot,
    chats,
    outcomes,
    pending,
    transcript,
    chatSend,
    submitUtterance,
    sendChat,
    confirm,
    selectChatMessages,
    refreshChatMessages,
    clearChatMessages,
    dismissPending,
  } = protocol;
  const speech = useLocalSTT();

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
  const selected =
    rows.find((row) => row.id === selectedId) ??
    rows.find((row) => row.focused) ??
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
    const target = rowsRef.current.find(
      (row) => row.id === current.targetRowId,
    );
    if (
      target?.kind === "chat" &&
      (target.source === "claude" || target.source === "codex")
    ) {
      const text = messageTextForTarget(current.utterance, target);
      if (text) {
        sendChat(target.source, target.id, text);
        return;
      }
    }
    submitUtterance(current.utterance);
  }, [sendChat, submitUtterance]);

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
      setStaged({
        utterance,
        preview: parse.preview,
        targetName: parse.targetName,
        targetRowId: parse.targetRowId,
        holdMs: parse.holdMs,
        key: Date.now(),
      });
      dispatchTimer.current = window.setTimeout(() => {
        dispatchStaged();
      }, parse.holdMs);
    },
    [dispatchStaged, glowRow, submitUtterance],
  );

  const startNewChat = useCallback(
    () => stageUtterance("start a claude chat"),
    [stageUtterance],
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
      } else if (
        target?.kind === "chat" &&
        (target.source === "claude" || target.source === "codex")
      ) {
        sendChat(target.source, target.id, text);
      } else {
        submitUtterance(text);
      }
    },
    [selectedId, sendChat, stageUtterance, submitUtterance],
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
        setSwitcherOpen((value) => !value);
        return;
      }
      if (event.metaKey && event.key === "Enter") {
        event.preventDefault();
        if (stagedRef.current) {
          dispatchStaged();
        } else {
          composerRef.current?.form?.requestSubmit();
        }
        return;
      }
      if (event.metaKey && event.key.toLowerCase() === "n") {
        event.preventDefault();
        startNewChat();
        return;
      }
      if (event.metaKey && event.key === ".") {
        event.preventDefault();
        const target =
          rowsRef.current.find((row) => row.id === selectedId) ??
          rowsRef.current.find((row) => row.focused) ??
          null;
        if (target?.kind === "agent") {
          submitUtterance(`interrupt ${target.spokenName}`);
        }
        return;
      }
      if (inField || event.metaKey || event.altKey || event.ctrlKey) return;
      if (event.key.toLowerCase() === "n") {
        event.preventDefault();
        const first = attentionItems(rowsRef.current)[0];
        if (first) selectRow(first.row);
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
    cancelStaged,
    dismissPending,
    dispatchStaged,
    pending,
    selectRow,
    selectedId,
    startNewChat,
    submitUtterance,
    switcherOpen,
  ]);

  useEffect(() => () => window.clearTimeout(dispatchTimer.current), []);

  return (
    <div className="app-shell">
      <Sidebar
        sections={sections}
        selectedId={selected?.id ?? null}
        glowRowId={rowGlow?.id ?? null}
        glowKey={rowGlow?.key ?? 0}
        query={query}
        onQueryChange={setQuery}
        onSelect={selectRow}
        onNewChat={startNewChat}
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
        </header>

        <MainPane
          selected={selected}
          connection={connection}
          outcomes={outcomes}
          snapshot={snapshot}
          transcript={transcript}
          pending={pending}
          chatSend={chatSend}
          voice={{
            supported: speech.supported,
            status: speech.status,
            interim: speech.interim,
            finals: speech.finals,
            start: speech.start,
            stop: speech.stop,
          }}
          onConfirm={confirm}
          onCancelPending={dismissPending}
          onComposerSubmit={composerSubmit}
          onInterrupt={(row) => {
            if (row.kind === "agent") {
              submitUtterance(`interrupt ${row.spokenName}`);
            }
          }}
          composerRef={composerRef}
        />

        <CommandBar
          staged={staged}
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
    </div>
  );
}
