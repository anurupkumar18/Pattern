import { useEffect, useRef, useState } from "react";

import { CHIPS, type ChipId } from "../grammar.js";

export interface ChipFx {
  /** Timestamp keys; a new value replays the pulse/shake animation. */
  pulseAt: Partial<Record<ChipId, number>>;
  shakeAt: Partial<Record<ChipId, number>>;
}

interface VerbChipsProps {
  fx: ChipFx;
  /** Chip currently pulsing as "listening for target". */
  armed: ChipId | null;
  /** Parse-before-act preview text, shown inside the matching chip. */
  staged: { chip: ChipId; preview: string } | null;
  listening: boolean;
  onActivate: (chip: ChipId) => void;
}

/**
 * The verb-chip HUD: a glanceable top-right cluster that documents the voice
 * grammar and physically reacts to it. Primary chips are always visible;
 * hovering the cluster reveals the rest (progressive disclosure).
 */
export function VerbChips({
  fx,
  armed,
  staged,
  listening,
  onActivate,
}: VerbChipsProps) {
  const [expanded, setExpanded] = useState(false);
  const collapseTimer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(collapseTimer.current), []);

  const enter = () => {
    window.clearTimeout(collapseTimer.current);
    setExpanded(true);
  };
  const leave = () => {
    window.clearTimeout(collapseTimer.current);
    collapseTimer.current = window.setTimeout(() => setExpanded(false), 300);
  };

  return (
    <div
      className={expanded ? "chip-hud expanded" : "chip-hud"}
      onMouseEnter={enter}
      onMouseLeave={leave}
      role="toolbar"
      aria-label="Voice commands"
    >
      {CHIPS.map((chip) => {
        const isStaged = staged?.chip === chip.id;
        const isArmed = armed === chip.id;
        const pulseKey = fx.pulseAt[chip.id];
        const shakeKey = fx.shakeAt[chip.id];
        const hidden = !chip.primary && !expanded && !isStaged && !isArmed;
        const classes = [
          "chip",
          hidden ? "chip-hidden" : "",
          isArmed ? "chip-armed" : "",
          isStaged ? "chip-staged" : "",
        ]
          .filter(Boolean)
          .join(" ");
        const label =
          chip.id === "voice" && listening ? "Voice off" : chip.label;
        return (
          <button
            key={`${chip.id}:${pulseKey ?? 0}:${shakeKey ?? 0}`}
            type="button"
            className={classes}
            data-pulse={pulseKey ? "" : undefined}
            data-shake={shakeKey ? "" : undefined}
            onClick={() => onActivate(chip.id)}
            aria-label={`${label}. ${chip.hint}. Shortcut ${chip.shortcut}`}
          >
            <span className="chip-main">
              <span className="chip-label">
                {isStaged ? staged.preview : label}
              </span>
              {!isStaged && <span className="chip-key">{chip.shortcut}</span>}
            </span>
            <span className="chip-hint">{chip.hint}</span>
          </button>
        );
      })}
    </div>
  );
}
