import { useState } from "react";
import { createRoot } from "react-dom/client";

import {
  LocalSTTSession,
  type LocalSTTEvent,
} from "./local-stt-session.js";
import { useLocalSTT } from "./useLocalSTT.js";

const DEFAULT_HINTS = "evals, smoke-shell, move, next, send, stop";

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function pcmFromWav(buffer: ArrayBuffer): Uint8Array {
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);
  const ascii = (offset: number, length: number) =>
    String.fromCharCode(...bytes.subarray(offset, offset + length));
  if (ascii(0, 4) !== "RIFF" || ascii(8, 4) !== "WAVE") {
    throw new Error("Expected a RIFF/WAVE file");
  }

  let offset = 12;
  let validFormat = false;
  while (offset + 8 <= view.byteLength) {
    const id = ascii(offset, 4);
    const size = view.getUint32(offset + 4, true);
    const start = offset + 8;
    if (id === "fmt ") {
      validFormat =
        view.getUint16(start, true) === 1 &&
        view.getUint16(start + 2, true) === 1 &&
        view.getUint32(start + 4, true) === 16_000 &&
        view.getUint16(start + 14, true) === 16;
    }
    if (id === "data") {
      if (!validFormat) {
        throw new Error("Expected PCM16 mono 16 kHz WAV");
      }
      return bytes.slice(start, start + size);
    }
    offset = start + size + (size % 2);
  }
  throw new Error("WAV data chunk not found");
}

function Harness() {
  const stt = useLocalSTT();
  const [hintText, setHintText] = useState(DEFAULT_HINTS);
  const [wavLog, setWavLog] = useState<string[]>([]);
  const [wavStatus, setWavStatus] = useState("idle");

  const hints = () =>
    hintText
      .split(",")
      .map((word) => word.trim())
      .filter(Boolean);

  const startMic = async () => {
    stt.setHints(hints());
    await stt.start();
  };

  const runWav = async (file: File) => {
    stt.stop();
    setWavLog([]);
    setWavStatus("connecting");
    let resolveFinal: ((event: LocalSTTEvent) => void) | undefined;
    const finalEvent = new Promise<LocalSTTEvent>((resolve) => {
      resolveFinal = resolve;
    });
    const session = new LocalSTTSession({
      onStatus: setWavStatus,
      onInterim: (event) =>
        setWavLog((current) => [...current, JSON.stringify(event)]),
      onFinal: (event) => {
        setWavLog((current) => [...current, JSON.stringify(event)]);
        resolveFinal?.(event);
      },
      onError: (error) => setWavLog((current) => [...current, error.message]),
    });

    try {
      const pcm = pcmFromWav(await file.arrayBuffer());
      session.setHints(hints());
      await Promise.race([
        session.start(),
        wait(10_000).then(() => {
          throw new Error("Timed out connecting to local STT");
        }),
      ]);
      for (let offset = 0; offset < pcm.length; offset += 640) {
        const chunk = pcm.slice(offset, Math.min(offset + 640, pcm.length));
        session.pushPcm(chunk.buffer as ArrayBuffer);
        await wait(20);
      }
      session.stop();
      await Promise.race([
        finalEvent,
        wait(20_000).then(() => {
          throw new Error("Timed out waiting for final transcript");
        }),
      ]);
    } catch (error) {
      setWavStatus("error");
      setWavLog((current) => [
        ...current,
        error instanceof Error ? error.message : String(error),
      ]);
      session.destroy();
    }
  };

  return (
    <main style={styles.main}>
      <h1 style={styles.heading}>Local STT harness</h1>
      <p style={styles.muted}>ws://127.0.0.1:4191 · PCM16 mono 16 kHz</p>

      <label style={styles.label}>
        Vocabulary hints
        <input
          style={styles.input}
          value={hintText}
          onChange={(event) => setHintText(event.target.value)}
        />
      </label>

      <section style={styles.panel}>
        <div style={styles.row}>
          <strong>Microphone: {stt.status}</strong>
          <button
            style={styles.button}
            onClick={() => void startMic()}
            disabled={
              stt.status === "connecting" || stt.status === "listening"
            }
          >
            Start
          </button>
          <button style={styles.button} onClick={stt.stop}>
            Stop
          </button>
        </div>
        <div style={styles.meter}>
          <div
            style={{
              ...styles.meterFill,
              width: `${Math.round(stt.amplitude * 100)}%`,
            }}
          />
        </div>
        <p style={styles.interim}>{stt.interim || "Listening text appears here"}</p>
        <ol>
          {stt.finals.map((text, index) => (
            <li key={`${index}-${text}`}>{text}</li>
          ))}
        </ol>
      </section>

      <section style={styles.panel}>
        <div style={styles.row}>
          <strong>Scripted WAV: {wavStatus}</strong>
          <input
            type="file"
            accept=".wav,audio/wav"
            onChange={(event) => {
              const file = event.target.files?.[0];
              if (file) void runWav(file);
            }}
          />
        </div>
        <pre style={styles.log}>
          {wavLog.length ? wavLog.join("\n") : "Choose a PCM16 mono 16 kHz WAV"}
        </pre>
      </section>
    </main>
  );
}

const styles = {
  main: {
    maxWidth: 760,
    margin: "48px auto",
    padding: 24,
    color: "#cdd6f4",
    background: "#11111b",
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
  },
  heading: { margin: 0, fontSize: 28 },
  muted: { color: "#7f849c" },
  label: { display: "grid", gap: 8 },
  input: {
    padding: 10,
    color: "#cdd6f4",
    background: "#181825",
    border: "1px solid #45475a",
  },
  panel: {
    marginTop: 20,
    padding: 16,
    background: "#181825",
    border: "1px solid #313244",
  },
  row: { display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap" },
  button: {
    padding: "8px 14px",
    color: "#cdd6f4",
    background: "#313244",
    border: "1px solid #585b70",
    cursor: "pointer",
  },
  meter: {
    height: 10,
    marginTop: 16,
    overflow: "hidden",
    background: "#313244",
  },
  meterFill: {
    height: "100%",
    background: "#a6e3a1",
    transition: "width 60ms linear",
  },
  interim: { minHeight: 24, color: "#89b4fa" },
  log: {
    minHeight: 80,
    padding: 12,
    whiteSpace: "pre-wrap",
    color: "#a6e3a1",
    background: "#11111b",
  },
} satisfies Record<string, React.CSSProperties>;

createRoot(document.getElementById("root")!).render(<Harness />);
