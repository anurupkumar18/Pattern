import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import {
  applyUtterance,
  createProjectState,
  exportStateMarkdown
} from "./state";
import type { EntityKind, ProjectState } from "./types";
import { useSpeechRecognition } from "./useSpeechRecognition";
import "./styles.css";

const STORAGE_KEY = "pattern.project-state.v1";

const entityLabels: Record<EntityKind, string> = {
  goal: "Goals",
  task: "Tasks",
  decision: "Decisions",
  question: "Open questions"
};

const demoFragments = [
  "I want to build a voice agent that remembers the whole project",
  "We should use the dark screenshots in the final post",
  "Actually forget that, use the dark screenshots only for the launch image",
  "How do we keep every fragment without polluting the active context?",
  "Draft the project brief using everything we have decided"
];

function loadState(): ProjectState {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) return JSON.parse(saved) as ProjectState;
  } catch {
    localStorage.removeItem(STORAGE_KEY);
  }
  return createProjectState();
}

function time(iso: string): string {
  return new Intl.DateTimeFormat("en", {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit"
  }).format(new Date(iso));
}

export default function App() {
  const [state, setState] = useState<ProjectState>(loadState);
  const [typed, setTyped] = useState("");
  const [copied, setCopied] = useState(false);

  const commitUtterance = useCallback((text: string) => {
    if (!text.trim()) return;
    setState((current) => applyUtterance(current, text));
  }, []);

  const speech = useSpeechRecognition(commitUtterance);

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  }, [state]);

  const activeEntities = useMemo(
    () => state.entities.filter((entity) => entity.status !== "superseded"),
    [state.entities]
  );

  function submitTyped(event: FormEvent) {
    event.preventDefault();
    commitUtterance(typed);
    setTyped("");
  }

  function approve(commandId: string) {
    setState((current) => ({
      ...current,
      updatedAt: new Date().toISOString(),
      commands: current.commands.map((command) =>
        command.id === commandId ? { ...command, status: "approved" } : command
      )
    }));
  }

  function reset() {
    setState(createProjectState());
    setCopied(false);
  }

  async function copyBrief() {
    await navigator.clipboard.writeText(exportStateMarkdown(state));
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1600);
  }

  function downloadState() {
    const blob = new Blob([JSON.stringify(state, null, 2)], {
      type: "application/json"
    });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `pattern-state-${state.sessionId}.json`;
    anchor.click();
    URL.revokeObjectURL(url);
  }

  function loadDemo() {
    setState((current) =>
      demoFragments.reduce(
        (next, fragment, index) =>
          applyUtterance(
            next,
            fragment,
            new Date(Date.now() + index * 1000).toISOString()
          ),
        current
      )
    );
  }

  const lastEvent = state.events.at(-1);

  return (
    <main className="shell">
      <header className="masthead">
        <div className="wordmark">Pattern</div>
        <div className="tagline">Voice becomes durable state</div>
        <div className="session-meta">
          <span>{state.utterances.length} fragments preserved</span>
          <span>{time(state.updatedAt)}</span>
        </div>
      </header>

      <section className="workspace" aria-label="Voice and state workspace">
        <section className="voice-pane">
          <div className="pane-heading">
            <span className="section-number">01</span>
            <div>
              <h1>Say it as it comes.</h1>
              <p>Corrections stay traceable. Nothing disappears.</p>
            </div>
          </div>

          <div className={`listening-stage ${speech.listening ? "is-live" : ""}`}>
            <button
              className="mic-control"
              type="button"
              onClick={speech.listening ? speech.stop : speech.start}
              disabled={!speech.supported}
              aria-pressed={speech.listening}
            >
              <span className="mic-glyph" aria-hidden="true" />
              <span>{speech.listening ? "Listening" : "Hold the floor"}</span>
            </button>
            <div className="live-copy" aria-live="polite">
              {speech.interim ||
                (speech.supported
                  ? "Your words will appear here while you speak."
                  : "Speech recognition needs Chrome. Type below to test the full state loop.")}
              {speech.listening && <span className="caret" aria-hidden="true" />}
            </div>
          </div>

          {speech.error && <p className="error-line">{speech.error}</p>}

          <form className="manual-input" onSubmit={submitTyped}>
            <label htmlFor="utterance">Type a fragment or correction</label>
            <div className="input-row">
              <input
                id="utterance"
                value={typed}
                onChange={(event) => setTyped(event.target.value)}
                placeholder="Actually, keep the installation section..."
              />
              <button type="submit">Commit</button>
            </div>
          </form>

          <div className="transcript-ledger">
            <div className="ledger-heading">
              <span>Complete utterance ledger</span>
              <span>append-only</span>
            </div>
            {state.utterances.length === 0 ? (
              <p className="empty-copy">No fragments yet.</p>
            ) : (
              <ol>
                {[...state.utterances].reverse().map((utterance) => (
                  <li key={utterance.id}>
                    <time>{time(utterance.createdAt)}</time>
                    <span>{utterance.text || "[empty fragment]"}</span>
                  </li>
                ))}
              </ol>
            )}
          </div>
        </section>

        <section className="state-pane">
          <div className="pane-heading state-heading">
            <span className="section-number">02</span>
            <div>
              <h2>What the system understands.</h2>
              <p>Active state stays small. Provenance stays complete.</p>
            </div>
          </div>

          <div className="operation-strip" aria-live="polite">
            <span className="operation-label">Latest operation</span>
            {lastEvent ? (
              <>
                <strong>{lastEvent.operation}</strong>
                <span>{Math.round(lastEvent.confidence * 100)}% confidence</span>
                <span className="operation-reason">{lastEvent.rationale}</span>
              </>
            ) : (
              <span>Waiting for the first fragment</span>
            )}
          </div>

          <div className="state-sections">
            {(Object.keys(entityLabels) as EntityKind[]).map((kind) => {
              const entities = activeEntities.filter((entity) => entity.kind === kind);
              return (
                <section className="state-section" key={kind}>
                  <div className="state-section-heading">
                    <h3>{entityLabels[kind]}</h3>
                    <span>{entities.length.toString().padStart(2, "0")}</span>
                  </div>
                  {entities.length === 0 ? (
                    <p className="empty-copy">Nothing active.</p>
                  ) : (
                    <ul>
                      {entities.map((entity) => (
                        <li key={entity.id} data-status={entity.status}>
                          <div className="entity-copy">{entity.text}</div>
                          <div className="entity-meta">
                            <span>{entity.status}</span>
                            <span>{entity.revisions.length} source event(s)</span>
                            <span title={entity.sourceUtteranceId}>linked to speech</span>
                          </div>
                        </li>
                      ))}
                    </ul>
                  )}
                </section>
              );
            })}
          </div>

          <section className="command-queue">
            <div className="state-section-heading">
              <h3>Action queue</h3>
              <span>{state.commands.length.toString().padStart(2, "0")}</span>
            </div>
            {state.commands.length === 0 ? (
              <p className="empty-copy">Commands appear here before execution.</p>
            ) : (
              <ul>
                {state.commands.map((command) => (
                  <li key={command.id}>
                    <div>
                      <div className="entity-copy">{command.text}</div>
                      <div className="entity-meta">
                        <span>{command.status}</span>
                        <span>{command.suggestedSkill}</span>
                        <span>{command.contextEntityIds.length} context links</span>
                      </div>
                    </div>
                    {command.status === "pending" && (
                      <button type="button" onClick={() => approve(command.id)}>
                        Approve
                      </button>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </section>
        </section>
      </section>

      <footer className="footer-bar">
        <div className="footer-actions">
          <button type="button" onClick={loadDemo}>Load demo fragments</button>
          <button type="button" onClick={copyBrief}>
            {copied ? "Brief copied" : "Copy agent brief"}
          </button>
          <button type="button" onClick={downloadState}>Download JSON</button>
          <button type="button" className="quiet-action" onClick={reset}>
            New session
          </button>
        </div>
        <div className="privacy-note">
          State stays local. Browser speech services may process audio remotely.
        </div>
      </footer>
    </main>
  );
}
