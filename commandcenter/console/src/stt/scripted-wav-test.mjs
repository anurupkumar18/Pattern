#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { WebSocket } from "ws";

import { LocalSTTSession } from "./local-stt-session.ts";

globalThis.WebSocket = WebSocket;

const wavPath = process.argv[2];
const expected = process.argv[3] ?? "";
const hints = (
  process.env.STT_TEST_HINTS ??
  "evals,smoke-shell,move,next,send,stop"
)
  .split(",")
  .map((word) => word.trim())
  .filter(Boolean);

if (!wavPath) {
  console.error(
    "usage: node scripted-wav-test.mjs <pcm16-mono-16k.wav> [expected text]",
  );
  process.exit(2);
}

function pcmFromWav(buffer) {
  const bytes = new Uint8Array(buffer);
  const view = new DataView(buffer);
  const ascii = (offset, length) =>
    String.fromCharCode(...bytes.subarray(offset, offset + length));
  if (ascii(0, 4) !== "RIFF" || ascii(8, 4) !== "WAVE") {
    throw new Error("expected RIFF/WAVE input");
  }

  let validFormat = false;
  let offset = 12;
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
    } else if (id === "data") {
      if (!validFormat) throw new Error("expected PCM16 mono 16 kHz input");
      return bytes.slice(start, start + size);
    }
    offset = start + size + (size % 2);
  }
  throw new Error("WAV data chunk not found");
}

function wait(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

const wav = await readFile(resolve(wavPath));
const pcm = pcmFromWav(
  wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.byteLength),
);
const events = [];
let resolveFinal;
const finalEvent = new Promise((resolvePromise) => {
  resolveFinal = resolvePromise;
});
const session = new LocalSTTSession({
  onInterim: (event) => {
    events.push(event);
    console.log(JSON.stringify(event));
  },
  onFinal: (event) => {
    events.push(event);
    console.log(JSON.stringify(event));
    resolveFinal(event);
  },
});

session.setHints(hints);
await Promise.race([
  session.start(),
  wait(10_000).then(() => {
    throw new Error("timed out connecting to local STT");
  }),
]);

for (let offset = 0; offset < pcm.length; offset += 640) {
  const chunk = pcm.slice(offset, Math.min(offset + 640, pcm.length));
  session.pushPcm(chunk.buffer);
  await wait(20);
}
session.stop();

const final = await Promise.race([
  finalEvent,
  wait(20_000).then(() => {
    throw new Error("timed out waiting for final transcript");
  }),
]);
session.destroy();

if (expected) {
  const normalize = (value) =>
    value.toLowerCase().replace(/[^\p{L}\p{N}-]+/gu, " ").trim();
  if (normalize(final.text) !== normalize(expected)) {
    console.error(
      `expected "${expected}", received "${final.text}"`,
    );
    process.exitCode = 1;
  }
}
