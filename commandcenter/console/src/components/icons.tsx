import type { RowSource } from "../model.js";

/** 14x14 monochrome source silhouettes. Distinct shapes, no colored dots. */
export function SourceGlyph({ source }: { source: RowSource }) {
  const common = {
    width: 14,
    height: 14,
    viewBox: "0 0 14 14",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.2,
    "aria-hidden": true,
  } as const;
  switch (source) {
    case "cursor":
      // Cursor: angular pointer prism.
      return (
        <svg {...common}>
          <path d="M3 1.5 L11.5 6.4 L7.4 7.8 L6 12.5 Z" strokeLinejoin="round" />
        </svg>
      );
    case "claude":
      // Claude: radiating asterisk burst.
      return (
        <svg {...common} strokeLinecap="round">
          <path d="M7 2.2v9.6M2.8 4.6l8.4 4.8M11.2 4.6L2.8 9.4" />
        </svg>
      );
    case "codex":
      // Codex: hexagonal node.
      return (
        <svg {...common}>
          <path
            d="M7 1.8 L11.6 4.4 L11.6 9.6 L7 12.2 L2.4 9.6 L2.4 4.4 Z"
            strokeLinejoin="round"
          />
          <circle cx="7" cy="7" r="1.4" />
        </svg>
      );
    case "gemini":
      return (
        <svg {...common}>
          <path d="M7 1.8C7.4 4.8 9.2 6.6 12.2 7 9.2 7.4 7.4 9.2 7 12.2 6.6 9.2 4.8 7.4 1.8 7 4.8 6.6 6.6 4.8 7 1.8Z" />
        </svg>
      );
    case "shell":
      return (
        <svg {...common} strokeLinecap="round">
          <path d="M3 4l3 3-3 3M7.5 10.5H11" />
        </svg>
      );
    default:
      return (
        <svg {...common}>
          <circle cx="7" cy="7" r="4.6" />
        </svg>
      );
  }
}

export function MicIcon({ size = 15 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 15 15"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.2"
      strokeLinecap="round"
      aria-hidden
    >
      <rect x="5.4" y="1.6" width="4.2" height="7.2" rx="2.1" />
      <path d="M3.2 7.2a4.3 4.3 0 0 0 8.6 0M7.5 11.6v2" />
    </svg>
  );
}

export function PlusIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.3"
      strokeLinecap="round"
      aria-hidden
    >
      <path d="M7 2.5v9M2.5 7h9" />
    </svg>
  );
}

export function SearchIcon() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 13 13"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.2"
      strokeLinecap="round"
      aria-hidden
    >
      <circle cx="5.6" cy="5.6" r="3.6" />
      <path d="M8.4 8.4l2.8 2.8" />
    </svg>
  );
}

export function SparkleIcon() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 13 13"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.1"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M6.5 1.6C6.9 4 8.4 5.5 10.9 6 8.4 6.5 6.9 8 6.5 10.4 6.1 8 4.6 6.5 2.1 6 4.6 5.5 6.1 4 6.5 1.6Z" />
    </svg>
  );
}

export function GearIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.1"
      aria-hidden
    >
      <circle cx="7" cy="7" r="2" />
      <path d="M7 1.6v1.7M7 10.7v1.7M1.6 7h1.7M10.7 7h1.7M3.2 3.2l1.2 1.2M9.6 9.6l1.2 1.2M10.8 3.2 9.6 4.4M4.4 9.6l-1.2 1.2" />
    </svg>
  );
}

export function StopIcon() {
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden>
      <rect x="1" y="1" width="8" height="8" rx="1.5" fill="currentColor" />
    </svg>
  );
}

export function ArrowUpIcon() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 13 13"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M6.5 10.5v-8M3 6l3.5-3.5L10 6" />
    </svg>
  );
}

/** The 12px working ring from spec §5. */
export function WorkingSpinner({ label = "Working" }: { label?: string }) {
  return (
    <span className="spinner" role="img" aria-label={label}>
      <span className="visually-hidden">{label}</span>
    </span>
  );
}

export function Waveform() {
  return (
    <span className="waveform" aria-hidden>
      <span />
      <span />
      <span />
    </span>
  );
}
