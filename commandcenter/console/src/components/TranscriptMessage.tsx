import { memo, type ReactNode } from "react";

export type TranscriptExtra =
  | { kind: "thinking"; text: string }
  | { kind: "activity"; label: string };

export interface TranscriptMessageData {
  id: string;
  role: "user" | "assistant";
  text: string;
  extras?: TranscriptExtra[];
}

export const TranscriptMessage = memo(function TranscriptMessage({
  message,
}: {
  message: TranscriptMessageData;
}) {
  return (
    <article
      className={`transcript-turn ${message.role}`}
      aria-label={message.role === "user" ? "You" : "Assistant"}
    >
      <div className="turn-role">
        {message.role === "user" ? "You" : "Assistant"}
      </div>
      {message.extras && message.extras.length > 0 && (
        <div className="turn-extras">
          {message.extras.map((extra, index) =>
            extra.kind === "thinking" ? (
              <ThinkingBlock key={`thinking-${index}`} text={extra.text} />
            ) : (
              <div className="activity-row" key={`activity-${index}`}>
                <span className="activity-mark" aria-hidden="true" />
                <span>{extra.label}</span>
              </div>
            ),
          )}
        </div>
      )}
      {message.text && (
        <div className="turn-text markdown-body">
          <MarkdownContent text={message.text} />
        </div>
      )}
    </article>
  );
});

function ThinkingBlock({ text }: { text: string }) {
  const preview = firstLinePreview(text);
  return (
    <details className="thinking-block">
      <summary>
        <span className="thinking-caret" aria-hidden="true" />
        <span className="thinking-label">Thought for a moment</span>
        {preview && <span className="thinking-preview">{preview}</span>}
      </summary>
      <div className="thinking-content markdown-body">
        <MarkdownContent text={text} />
      </div>
    </details>
  );
}

function MarkdownContent({ text }: { text: string }) {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const blocks: ReactNode[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index] ?? "";
    if (!line.trim()) {
      index += 1;
      continue;
    }

    const fence = line.match(/^ {0,3}```([\w+-]*)\s*$/);
    if (fence) {
      const language = fence[1] ?? "";
      const code: string[] = [];
      index += 1;
      while (index < lines.length && !/^ {0,3}```\s*$/.test(lines[index] ?? "")) {
        code.push(lines[index] ?? "");
        index += 1;
      }
      if (index < lines.length) index += 1;
      blocks.push(
        <pre className="markdown-code-block" key={`code-${blocks.length}`}>
          <code data-language={language || undefined}>{code.join("\n")}</code>
        </pre>,
      );
      continue;
    }

    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      const level = heading[1]?.length ?? 1;
      const content = renderInline(heading[2] ?? "", `h-${blocks.length}`);
      blocks.push(
        level === 1 ? (
          <h1 key={`h-${blocks.length}`}>{content}</h1>
        ) : level === 2 ? (
          <h2 key={`h-${blocks.length}`}>{content}</h2>
        ) : level === 3 ? (
          <h3 key={`h-${blocks.length}`}>{content}</h3>
        ) : level === 4 ? (
          <h4 key={`h-${blocks.length}`}>{content}</h4>
        ) : level === 5 ? (
          <h5 key={`h-${blocks.length}`}>{content}</h5>
        ) : (
          <h6 key={`h-${blocks.length}`}>{content}</h6>
        ),
      );
      index += 1;
      continue;
    }

    const listMatch = line.match(/^ {0,3}([-*+]|\d+\.)\s+(.+)$/);
    if (listMatch) {
      const ordered = /\d+\./.test(listMatch[1] ?? "");
      const items: ReactNode[] = [];
      while (index < lines.length) {
        const item = (lines[index] ?? "").match(
          ordered
            ? /^ {0,3}\d+\.\s+(.+)$/
            : /^ {0,3}[-*+]\s+(.+)$/,
        );
        if (!item) break;
        items.push(
          <li key={`li-${index}`}>
            {renderInline(item[1] ?? "", `li-${index}`)}
          </li>,
        );
        index += 1;
      }
      blocks.push(
        ordered ? (
          <ol key={`list-${blocks.length}`}>{items}</ol>
        ) : (
          <ul key={`list-${blocks.length}`}>{items}</ul>
        ),
      );
      continue;
    }

    const paragraph: string[] = [line.trim()];
    index += 1;
    while (index < lines.length && !isBlockStart(lines[index] ?? "")) {
      paragraph.push((lines[index] ?? "").trim());
      index += 1;
    }
    blocks.push(
      <p key={`p-${blocks.length}`}>
        {renderInline(paragraph.join(" "), `p-${blocks.length}`)}
      </p>,
    );
  }

  return <>{blocks}</>;
}

function isBlockStart(line: string): boolean {
  return (
    !line.trim() ||
    /^ {0,3}```/.test(line) ||
    /^#{1,6}\s+/.test(line) ||
    /^ {0,3}([-*+]|\d+\.)\s+/.test(line)
  );
}

const INLINE_TOKEN =
  /(`[^`\n]+`|\[[^\]\n]+\]\([^\s)]+(?:\s+"[^"]*")?\)|\*\*[^*\n]+\*\*|__[^_\n]+__|\*[^*\n]+\*|_[^_\n]+_)/g;

function renderInline(text: string, keyPrefix: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  let cursor = 0;
  let match: RegExpExecArray | null;
  const tokenPattern = new RegExp(INLINE_TOKEN.source, INLINE_TOKEN.flags);

  while ((match = tokenPattern.exec(text)) !== null) {
    if (match.index > cursor) nodes.push(text.slice(cursor, match.index));
    const token = match[0];
    const key = `${keyPrefix}-${match.index}`;
    if (token.startsWith("`")) {
      nodes.push(<code key={key}>{token.slice(1, -1)}</code>);
    } else if (token.startsWith("[")) {
      const link = token.match(/^\[([^\]]+)\]\(([^\s)]+)(?:\s+"[^"]*")?\)$/);
      const href = link ? safeHref(link[2] ?? "") : null;
      nodes.push(
        href ? (
          <a
            href={href}
            key={key}
            target={/^https?:/i.test(href) ? "_blank" : undefined}
            rel={/^https?:/i.test(href) ? "noreferrer noopener" : undefined}
          >
            {renderInline(link?.[1] ?? "", `${key}-link`)}
          </a>
        ) : (
          token
        ),
      );
    } else if (token.startsWith("**") || token.startsWith("__")) {
      nodes.push(
        <strong key={key}>
          {renderInline(token.slice(2, -2), `${key}-strong`)}
        </strong>,
      );
    } else {
      nodes.push(
        <em key={key}>
          {renderInline(token.slice(1, -1), `${key}-em`)}
        </em>,
      );
    }
    cursor = match.index + token.length;
  }
  if (cursor < text.length) nodes.push(text.slice(cursor));
  return nodes;
}

function safeHref(value: string): string | null {
  const href = value.trim();
  if (/^(https?:|mailto:)/i.test(href) || href.startsWith("/") || href.startsWith("#")) {
    return href;
  }
  return null;
}

function firstLinePreview(text: string): string {
  const firstLine = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean);
  if (!firstLine) return "";
  const plain = firstLine
    .replace(/^#{1,6}\s+/, "")
    .replace(/[*_`]+/g, "")
    .trim();
  return plain.length > 72 ? `${plain.slice(0, 69)}…` : plain;
}
