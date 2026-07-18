import { useState } from "react";

import {
  attentionSummary,
  relativeTime,
  type AttentionItem,
  type HistoryRow,
  type HistorySection,
} from "../model.js";
import {
  GearIcon,
  MicIcon,
  PlusIcon,
  SearchIcon,
  SourceGlyph,
  SparkleIcon,
  Waveform,
  WorkingSpinner,
} from "./icons.js";

interface SidebarProps {
  sections: HistorySection[];
  attention: AttentionItem[];
  selectedId: string | null;
  glowRowId: string | null;
  glowKey: number;
  query: string;
  onQueryChange: (value: string) => void;
  onSelect: (row: HistoryRow) => void;
  onNewChat: () => void;
  onAttention: () => void;
  voice: {
    supported: boolean;
    listening: boolean;
    error: string | null;
    toggle: () => void;
  };
  searchRef: React.RefObject<HTMLInputElement | null>;
}

export function Sidebar({
  sections,
  attention,
  selectedId,
  glowRowId,
  glowKey,
  query,
  onQueryChange,
  onSelect,
  onNewChat,
  onAttention,
  voice,
  searchRef,
}: SidebarProps) {
  return (
    <aside className="sidebar">
      <header className="sidebar-header">
        <span className="wordmark">Dictator</span>
      </header>

      <button type="button" className="new-chat" onClick={onNewChat}>
        <PlusIcon />
        <span>New chat</span>
        <kbd>⌘N</kbd>
      </button>

      <label className="chat-search">
        <SearchIcon />
        <input
          ref={searchRef}
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          placeholder="Search chats"
          spellCheck={false}
        />
        <kbd>⌘K</kbd>
      </label>

      <button type="button" className="attention-row" onClick={onAttention}>
        <SparkleIcon />
        <span className="attention-label">What needs me</span>
        <span className="attention-summary">{attentionSummary(attention)}</span>
      </button>

      <nav className="history" aria-label="Chat history">
        {sections.length === 0 && (
          <p className="history-empty">No chats in this window.</p>
        )}
        {sections.map((section) => (
          <HistoryGroup
            key={section.label}
            section={section}
            selectedId={selectedId}
            glowRowId={glowRowId}
            glowKey={glowKey}
            onSelect={onSelect}
          />
        ))}
      </nav>

      <footer className="sidebar-footer">
        <VoiceControl voice={voice} />
        <button type="button" className="icon-button" aria-label="Settings">
          <GearIcon />
        </button>
      </footer>
    </aside>
  );
}

function HistoryGroup({
  section,
  selectedId,
  glowRowId,
  glowKey,
  onSelect,
}: {
  section: HistorySection;
  selectedId: string | null;
  glowRowId: string | null;
  glowKey: number;
  onSelect: (row: HistoryRow) => void;
}) {
  const [collapsed, setCollapsed] = useState(false);
  const collapsible = section.label === "Earlier";
  return (
    <section className="history-section">
      <h2
        className={collapsible ? "section-header collapsible" : "section-header"}
        onClick={collapsible ? () => setCollapsed((value) => !value) : undefined}
      >
        {section.label}
        {collapsible && (
          <span className="section-caret">{collapsed ? "▸" : "▾"}</span>
        )}
      </h2>
      {!collapsed &&
        section.rows.map((row) => (
          <ChatRow
            key={row.id}
            row={row}
            selected={row.id === selectedId}
            glowing={row.id === glowRowId}
            glowKey={glowKey}
            onSelect={onSelect}
          />
        ))}
    </section>
  );
}

function ChatRow({
  row,
  selected,
  glowing,
  glowKey,
  onSelect,
}: {
  row: HistoryRow;
  selected: boolean;
  glowing: boolean;
  glowKey: number;
  onSelect: (row: HistoryRow) => void;
}) {
  const classes = [
    "chat-row",
    selected ? "selected" : "",
    glowing ? "glow" : "",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <button
      type="button"
      key={glowing ? `glow-${glowKey}` : undefined}
      className={classes}
      onClick={() => onSelect(row)}
      aria-current={selected ? "page" : undefined}
      title={row.subtitle ?? row.title}
    >
      <span className="row-glyph">
        <SourceGlyph source={row.source} />
      </span>
      <span className="row-body">
        <span className="row-title">{row.title}</span>
        {row.needsInput && row.subtitle && (
          <span className="row-sub">{row.subtitle}</span>
        )}
      </span>
      <span className="row-state">
        {row.working && <WorkingSpinner />}
        {row.needsInput && (
          <span className="needs-input">
            <span className="dot amber" />
            Needs input
          </span>
        )}
        {row.doneUnseen && <span className="dot blue" aria-label="Unread" />}
        {row.stopped && selected && <span className="stopped">Stopped</span>}
      </span>
      <span className="row-time">{relativeTime(row.timestamp)}</span>
    </button>
  );
}

function VoiceControl({
  voice,
}: {
  voice: SidebarProps["voice"];
}) {
  const [helpOpen, setHelpOpen] = useState(false);
  const label = !voice.supported
    ? "Mic unavailable"
    : voice.listening
      ? "Listening"
      : "Voice off";
  return (
    <div className="voice-wrap">
      <button
        type="button"
        className={voice.listening ? "voice-pill on" : "voice-pill"}
        onClick={voice.toggle}
        disabled={!voice.supported}
        title="Turn voice on  ⌥Space"
      >
        <MicIcon />
        <span>{label}</span>
        {voice.listening && <Waveform />}
      </button>
      <button
        type="button"
        className="icon-button"
        aria-label="Voice help"
        onClick={() => setHelpOpen((value) => !value)}
        onBlur={() => setHelpOpen(false)}
      >
        ?
      </button>
      {helpOpen && (
        <div className="voice-help" role="dialog" aria-label="Voice commands">
          <HelpRow speech="Say a chat name to focus it" keys="⌘K" />
          <HelpRow speech="Say “send” to send" keys="⌘↩" />
          <HelpRow speech="Say “interrupt” to stop the focused chat" keys="⌘." />
          <HelpRow speech="Say “new Claude chat” to start one" keys="⌘N" />
          <HelpRow speech="Ask “what needs me?”" keys="N" />
          <HelpRow speech="Say “voice off” to stop listening" keys="⌥Space" />
        </div>
      )}
      {voice.error && <span className="voice-error">{voice.error}</span>}
    </div>
  );
}

function HelpRow({ speech, keys }: { speech: string; keys: string }) {
  return (
    <div className="help-row">
      <span>{speech}</span>
      <kbd>{keys}</kbd>
    </div>
  );
}
