#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { WebSocket } from "ws";

const SAMPLE_RATE = 16_000;
const CHUNK_MS = Number(process.env.STT_TEST_CHUNK_MS ?? 20);
const TIMEOUT_MS = Number(process.env.STT_TEST_TIMEOUT_MS ?? 30_000);
const URL = process.env.STT_WS_URL ?? "ws://127.0.0.1:4191";
const VOCABULARY = (process.env.STT_TEST_VOCABULARY ?? "evals,Noah,design agent")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const wavPath = process.argv[2];

if (!wavPath) {
  console.error("usage: node test-wav.mjs <16k-mono-pcm16.wav>");
  process.exit(2);
}

function parseWav(buffer) {
  if (
    buffer.toString("ascii", 0, 4) !== "RIFF" ||
    buffer.toString("ascii", 8, 12) !== "WAVE"
  ) {
    throw new Error("input is not a RIFF/WAVE file");
  }

  let offset = 12;
  let format;
  let pcm;
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString("ascii", offset, offset + 4);
    const size = buffer.readUInt32LE(offset + 4);
    const start = offset + 8;
    if (id === "fmt ") {
      format = {
        audioFormat: buffer.readUInt16LE(start),
        channels: buffer.readUInt16LE(start + 2),
        sampleRate: buffer.readUInt32LE(start + 4),
        bitsPerSample: buffer.readUInt16LE(start + 14),
      };
    } else if (id === "data") {
      pcm = buffer.subarray(start, start + size);
    }
    offset = start + size + (size % 2);
  }

  if (!format || !pcm) throw new Error("WAV is missing fmt or data chunk");
  if (
    format.audioFormat !== 1 ||
    format.channels !== 1 ||
    format.sampleRate !== SAMPLE_RATE ||
    format.bitsPerSample !== 16
  ) {
    throw new Error(
      `expected PCM16 mono ${SAMPLE_RATE}Hz, got ${JSON.stringify(format)}`,
    );
  }
  return pcm;
}

async function sleep(ms) {
  await new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

const pcm = parseWav(await readFile(resolve(wavPath)));
const bytesPerChunk = Math.round((SAMPLE_RATE * 2 * CHUNK_MS) / 1_000);
const events = [];
const socket = new WebSocket(URL);
const closed = new Promise((resolvePromise) =>
  socket.once("close", resolvePromise),
);

const timeout = setTimeout(() => {
  console.error(`timed out waiting for final event from ${URL}`);
  socket.close();
  process.exitCode = 1;
}, TIMEOUT_MS);

await new Promise((resolvePromise, reject) => {
  socket.once("open", resolvePromise);
  socket.once("error", reject);
});

socket.on("message", (data) => {
  const event = JSON.parse(data.toString());
  if (event.type !== "interim" && event.type !== "final") return;
  events.push(event);
  console.log(JSON.stringify(event));
  if (event.type === "final") {
    clearTimeout(timeout);
    socket.close();
  }
});

socket.send(
  JSON.stringify({
    type: "start",
    sampleRate: SAMPLE_RATE,
    vocabulary: VOCABULARY,
  }),
);
for (let offset = 0; offset < pcm.length; offset += bytesPerChunk) {
  socket.send(pcm.subarray(offset, Math.min(offset + bytesPerChunk, pcm.length)));
  await sleep(CHUNK_MS);
}
socket.send(JSON.stringify({ type: "stop" }));

await closed;

const interim = events.find((event) => event.type === "interim");
const final = events.findLast((event) => event.type === "final");
if (!interim || !final || !final.text) {
  console.error(
    `${basename(wavPath)} did not produce a non-empty interim and final event`,
  );
  process.exitCode = 1;
}
