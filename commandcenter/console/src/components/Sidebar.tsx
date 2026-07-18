import { useState } from "react";

import {
  relativeTime,
  type HistoryRow,
  type HistorySection,
} from "../model.js";
import {
  PlusIcon,
  SearchIcon,
  SourceGlyph,
  WorkingSpinner,
} from "./icons.js";

interface SidebarProps {
  sections: HistorySection[];
  selectedId: string | null;
  glowRowId: string | null;
  glowKey: number;
  query: string;
  onQueryChange: (value: string) => void;
  onSelect: (row: HistoryRow) => void;
  onNewChat: () => void;
  searchRef: React.RefObject<HTMLInputElement | null>;
}

export function Sidebar({
  sections,
  selectedId,
  glowRowId,
  glowKey,
  query,
  onQueryChange,
  onSelect,
  onNewChat,
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
  const [collapsed, setCollapsed] = useState(
    section.label === "Automations",
  );
  const collapsible =
    section.label === "Earlier" || section.label === "Automations";
  const heading =
    section.label === "Automations"
      ? `Automations · ${section.rows.length}`
      : section.label;
  return (
    <section className="history-section">
      <h2
        className={collapsible ? "section-header collapsible" : "section-header"}
        onClick={collapsible ? () => setCollapsed((value) => !value) : undefined}
      >
        {heading}
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
        {(row.working || row.needsInput) && row.subtitle && (
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
