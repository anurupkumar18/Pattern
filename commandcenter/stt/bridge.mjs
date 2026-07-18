#!/usr/bin/env node

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { WebSocket, WebSocketServer } from "ws";

const HERE = dirname(fileURLToPath(import.meta.url));
const HOST = process.env.STT_HOST ?? "127.0.0.1";
const PORT = numberFromEnv("STT_PORT", 4191);
const BACKEND_HOST = "127.0.0.1";
const BACKEND_PORT = numberFromEnv("STT_BACKEND_PORT", 4192);
const SAMPLE_RATE = 16_000;
const CHANNELS = 1;
const BYTES_PER_SAMPLE = 2;
const SILENCE_MS = numberFromEnv("STT_SILENCE_MS", 1_000);
const MIN_SPEECH_MS = numberFromEnv("STT_MIN_SPEECH_MS", 220);
const INTERIM_FIRST_MS = numberFromEnv("STT_INTERIM_FIRST_MS", 480);
const INTERIM_EVERY_MS = numberFromEnv("STT_INTERIM_EVERY_MS", 1_600);
const VAD_RMS = numberFromEnv("STT_VAD_RMS", 0.012);
const PRE_ROLL_MS = numberFromEnv("STT_PRE_ROLL_MS", 240);
const MODEL = resolve(
  process.env.WHISPER_MODEL ?? resolve(HERE, "models/ggml-base.en.bin"),
);
const WHISPER_SERVER = resolve(
  process.env.WHISPER_SERVER_BIN ??
    resolve(HERE, "vendor/whisper.cpp/build/bin/whisper-server"),
);
const BACKEND_URL =
  process.env.STT_BACKEND_URL ??
  `http://${BACKEND_HOST}:${BACKEND_PORT}`;

let backend;
let shuttingDown = false;

function numberFromEnv(name, fallback) {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a positive number`);
  }
  return value;
}

function rmsPcm16(buffer) {
  const sampleCount = Math.floor(buffer.length / BYTES_PER_SAMPLE);
  if (sampleCount === 0) return 0;

  let sumSquares = 0;
  for (let offset = 0; offset + 1 < buffer.length; offset += 2) {
    const sample = buffer.readInt16LE(offset) / 32_768;
    sumSquares += sample * sample;
  }
  return Math.sqrt(sumSquares / sampleCount);
}

function durationMs(buffer) {
  return (
    (buffer.length / BYTES_PER_SAMPLE / SAMPLE_RATE) *
    1_000
  );
}

function wavFromPcm(pcm) {
  const header = Buffer.alloc(44);
  const byteRate = SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE;
  const blockAlign = CHANNELS * BYTES_PER_SAMPLE;

  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(CHANNELS, 22);
  header.writeUInt32LE(SAMPLE_RATE, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(BYTES_PER_SAMPLE * 8, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

function cleanText(value) {
  return String(value ?? "")
    .replace(/\s+/g, " ")
    .replace(/^\s+|\s+$/g, "");
}

async function transcribe(pcm, prompt) {
  const form = new FormData();
  form.set("file", new Blob([wavFromPcm(pcm)], { type: "audio/wav" }), "audio.wav");
  form.set("temperature", "0.0");
  form.set("temperature_inc", "0.0");
  form.set("response_format", "json");
  form.set("language", "en");
  form.set("no_context", "true");
  form.set("suppress_nst", "true");
  if (prompt) {
    form.set("prompt", prompt);
  }

  const response = await fetch(`${BACKEND_URL}/inference`, {
    method: "POST",
    body: form,
  });
  if (!response.ok) {
    throw new Error(
      `whisper backend returned ${response.status}: ${await response.text()}`,
    );
  }
  const result = await response.json();
  return cleanText(result.text);
}

class StreamSession {
  constructor(socket) {
    this.socket = socket;
    this.startedAt = performance.now();
    this.preRoll = [];
    this.preRollDurationMs = 0;
    this.audio = [];
    this.audioDurationMs = 0;
    this.voicedDurationMs = 0;
    this.silenceDurationMs = 0;
    this.speaking = false;
    this.lastInterimAtAudioMs = 0;
    this.lastInterimText = "";
    this.queue = [];
    this.processing = false;
    this.finalQueued = false;
    this.prompt = cleanText(process.env.STT_PROMPT ?? "");
  }

  resetClock(config = {}) {
    this.startedAt = performance.now();
    if (Array.isArray(config.vocabulary)) {
      const vocabulary = config.vocabulary
        .map(cleanText)
        .filter(Boolean)
        .slice(0, 64);
      this.prompt = vocabulary.length
        ? `Expected command-center names: ${vocabulary.join(", ")}.`
        : cleanText(process.env.STT_PROMPT ?? "");
    }
    this.resetUtterance();
  }

  pushPcm(chunk) {
    if (chunk.length === 0 || chunk.length % 2 !== 0) {
      return;
    }

    const chunkDuration = durationMs(chunk);
    const voiced = rmsPcm16(chunk) >= VAD_RMS;

    if (!this.speaking) {
      this.pushPreRoll(chunk, chunkDuration);
      if (!voiced) return;

      this.speaking = true;
      this.audio = [...this.preRoll];
      this.audioDurationMs = this.preRollDurationMs;
      this.voicedDurationMs = chunkDuration;
      this.silenceDurationMs = 0;
      this.preRoll = [];
      this.preRollDurationMs = 0;
      return;
    }

    this.audio.push(chunk);
    this.audioDurationMs += chunkDuration;
    if (voiced) {
      this.voicedDurationMs += chunkDuration;
      this.silenceDurationMs = 0;
    } else {
      this.silenceDurationMs += chunkDuration;
    }

    const firstInterim =
      this.lastInterimAtAudioMs === 0 &&
      this.audioDurationMs >= INTERIM_FIRST_MS;
    const nextInterim =
      this.lastInterimAtAudioMs > 0 &&
      this.audioDurationMs - this.lastInterimAtAudioMs >= INTERIM_EVERY_MS;
    if ((firstInterim || nextInterim) && !this.finalQueued) {
      this.lastInterimAtAudioMs = this.audioDurationMs;
      this.enqueue("interim", Buffer.concat(this.audio));
    }

    if (this.silenceDurationMs >= SILENCE_MS) {
      this.finish();
    }
  }

  pushPreRoll(chunk, chunkDuration) {
    this.preRoll.push(chunk);
    this.preRollDurationMs += chunkDuration;
    while (
      this.preRoll.length > 1 &&
      this.preRollDurationMs > PRE_ROLL_MS
    ) {
      const removed = this.preRoll.shift();
      this.preRollDurationMs -= durationMs(removed);
    }
  }

  finish() {
    if (!this.speaking) return;

    if (this.voicedDurationMs >= MIN_SPEECH_MS) {
      this.finalQueued = true;
      this.enqueue("final", Buffer.concat(this.audio));
    }
    this.resetUtterance();
  }

  resetUtterance() {
    this.preRoll = [];
    this.preRollDurationMs = 0;
    this.audio = [];
    this.audioDurationMs = 0;
    this.voicedDurationMs = 0;
    this.silenceDurationMs = 0;
    this.speaking = false;
    this.lastInterimAtAudioMs = 0;
    this.finalQueued = false;
  }

  enqueue(type, pcm) {
    if (type === "final") {
      this.queue = this.queue.filter((job) => job.type !== "interim");
    }
    if (
      type === "interim" &&
      this.queue.some((job) => job.type === "interim")
    ) {
      return;
    }
    this.queue.push({ type, pcm, prompt: this.prompt });
    void this.drain();
  }

  async drain() {
    if (this.processing) return;
    this.processing = true;
    try {
      while (this.queue.length > 0) {
        const job = this.queue.shift();
        try {
          const text = await transcribe(job.pcm, job.prompt);
          if (job.type === "interim" && (!text || text === this.lastInterimText)) {
            continue;
          }
          if (job.type === "interim") {
            this.lastInterimText = text;
          } else {
            this.lastInterimText = "";
          }
          this.send({
            type: job.type,
            text,
            tMs: Math.round(performance.now() - this.startedAt),
          });
        } catch (error) {
          console.error(`[stt] transcription failed: ${error.message}`);
        }
      }
    } finally {
      this.processing = false;
    }
  }

  send(event) {
    if (this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(event));
    }
  }
}

async function waitForBackend(timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    if (backend?.exitCode != null) {
      throw new Error(`whisper backend exited with code ${backend.exitCode}`);
    }
    try {
      const response = await fetch(`${BACKEND_URL}/`);
      if (response.ok) return;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  }
  throw new Error(`whisper backend did not start: ${lastError?.message ?? "timeout"}`);
}

async function startBackend() {
  if (process.env.STT_BACKEND_URL) {
    await waitForBackend();
    return;
  }
  if (!existsSync(WHISPER_SERVER)) {
    throw new Error(`whisper-server not found: ${WHISPER_SERVER}`);
  }
  if (!existsSync(MODEL)) {
    throw new Error(`model not found: ${MODEL}`);
  }

  await mkdir(resolve(HERE, "logs"), { recursive: true });
  backend = spawn(
    WHISPER_SERVER,
    [
      "--host",
      BACKEND_HOST,
      "--port",
      String(BACKEND_PORT),
      "--model",
      MODEL,
      "--language",
      "en",
      "--no-timestamps",
      "--no-context",
      "--suppress-nst",
      "--threads",
      String(Math.max(2, Math.min(8, Number(process.env.STT_THREADS ?? 4)))),
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  backend.stderr.setEncoding("utf8");
  backend.stderr.on("data", (data) => {
    for (const line of data.trimEnd().split("\n")) {
      if (line) console.error(`[whisper] ${line}`);
    }
  });
  await waitForBackend();
}

function installSignalHandlers(server) {
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    server.close();
    backend?.kill("SIGTERM");
    setTimeout(() => process.exit(0), 200).unref();
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  backend?.on("exit", (code, signal) => {
    if (!shuttingDown) {
      console.error(`[stt] whisper backend exited (${code ?? signal})`);
      server.close(() => process.exit(1));
    }
  });
}

await startBackend();

const server = new WebSocketServer({ host: HOST, port: PORT });
server.on("connection", (socket) => {
  const session = new StreamSession(socket);
  socket.on("message", (data, isBinary) => {
    if (isBinary) {
      session.pushPcm(Buffer.from(data));
      return;
    }

    try {
      const message = JSON.parse(data.toString());
      if (message.type === "start") {
        session.resetClock(message);
      } else if (message.type === "stop") {
        session.finish();
      }
    } catch {
      socket.close(1003, "expected binary PCM or JSON control message");
    }
  });
});
server.on("listening", () => {
  console.log(
    `[stt] ws://${HOST}:${PORT} model=${MODEL} vad_rms=${VAD_RMS} silence_ms=${SILENCE_MS}`,
  );
});
installSignalHandlers(server);
