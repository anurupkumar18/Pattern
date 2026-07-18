import { useEffect, useMemo, useRef, useState } from "react";

import type { HistoryRow } from "../model.js";
import { SourceGlyph } from "./icons.js";

interface ChatSwitcherProps {
  rows: HistoryRow[];
  onPick: (row: HistoryRow) => void;
  onClose: () => void;
}

/** ⌘K overlay: typeahead over the unified history list. */
export function ChatSwitcher({ rows, onPick, onClose }: ChatSwitcherProps) {
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => inputRef.current?.focus(), []);

  const matches = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const pool = needle
      ? rows.filter((row) => row.title.toLowerCase().includes(needle))
      : rows;
    return pool.slice(0, 9);
  }, [rows, query]);

  useEffect(() => {
    setIndex((current) => Math.min(current, Math.max(0, matches.length - 1)));
  }, [matches.length]);

  return (
    <div className="switcher-backdrop" onClick={onClose}>
      <div
        className="switcher"
        role="dialog"
        aria-label="Move to chat"
        onClick={(event) => event.stopPropagation()}
      >
        <input
          ref={inputRef}
          value={query}
          placeholder="Move to…"
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Escape") onClose();
            else if (event.key === "ArrowDown") {
              event.preventDefault();
              setIndex((value) => Math.min(value + 1, matches.length - 1));
            } else if (event.key === "ArrowUp") {
              event.preventDefault();
              setIndex((value) => Math.max(value - 1, 0));
            } else if (event.key === "Enter") {
              event.preventDefault();
              const picked = matches[index];
              if (picked) onPick(picked);
            }
          }}
          spellCheck={false}
        />
        <div className="switcher-list">
          {matches.map((row, rowIndex) => (
            <button
              key={row.id}
              type="button"
              className={
                rowIndex === index ? "switcher-row active" : "switcher-row"
              }
              onMouseEnter={() => setIndex(rowIndex)}
              onClick={() => onPick(row)}
            >
              <SourceGlyph source={row.source} />
              <span className="switcher-title">{row.title}</span>
              <kbd>{rowIndex + 1}</kbd>
            </button>
          ))}
          {matches.length === 0 && (
            <p className="switcher-empty">No matching chats.</p>
          )}
        </div>
      </div>
    </div>
  );
}
