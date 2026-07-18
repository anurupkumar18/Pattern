#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { WebSocket } from "ws";

const URL = process.env.STT_WS_URL ?? "ws://127.0.0.1:4191";
const MODEL = process.env.STT_BENCH_MODEL ?? "unknown";
const SAMPLE_RATE = 16_000;
const CHUNK_MS = 20;
const VAD_RMS = Number(process.env.STT_VAD_RMS ?? 0.012);
const VOCABULARY = (process.env.STT_BENCH_VOCABULARY ?? "evals,Noah,design agent")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const files = process.argv.slice(2);

if (files.length === 0) {
  console.error("usage: node benchmark.mjs <sample.wav> [sample.wav ...]");
  process.exit(2);
}

function parsePcm16Wav(buffer) {
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
  if (
    !format ||
    !pcm ||
    format.audioFormat !== 1 ||
    format.channels !== 1 ||
    format.sampleRate !== SAMPLE_RATE ||
    format.bitsPerSample !== 16
  ) {
    throw new Error("expected a PCM16 mono 16kHz WAV");
  }
  return pcm;
}

function rms(buffer) {
  const samples = Math.floor(buffer.length / 2);
  let sumSquares = 0;
  for (let offset = 0; offset + 1 < buffer.length; offset += 2) {
    const value = buffer.readInt16LE(offset) / 32_768;
    sumSquares += value * value;
  }
  return samples === 0 ? 0 : Math.sqrt(sumSquares / samples);
}

function speechBounds(pcm, bytesPerChunk) {
  let first;
  let last;
  for (let offset = 0; offset < pcm.length; offset += bytesPerChunk) {
    const chunk = pcm.subarray(offset, Math.min(offset + bytesPerChunk, pcm.length));
    if (rms(chunk) >= VAD_RMS) {
      const chunkNumber = Math.floor(offset / bytesPerChunk);
      first ??= chunkNumber * CHUNK_MS;
      last = (chunkNumber + 1) * CHUNK_MS;
    }
  }
  return { startMs: first ?? 0, endMs: last ?? pcm.length / 32 };
}

async function sleep(ms) {
  await new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

async function runSample(file) {
  const pcm = parsePcm16Wav(await readFile(resolve(file)));
  const bytesPerChunk = Math.round((SAMPLE_RATE * 2 * CHUNK_MS) / 1_000);
  const bounds = speechBounds(pcm, bytesPerChunk);
  const events = [];
  const socket = new WebSocket(URL);

  await new Promise((resolvePromise, reject) => {
    socket.once("open", resolvePromise);
    socket.once("error", reject);
  });
  socket.on("message", (data) => {
    const event = JSON.parse(data.toString());
    if (event.type === "interim" || event.type === "final") {
      events.push(event);
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

  const deadline = Date.now() + 30_000;
  while (!events.some((event) => event.type === "final") && Date.now() < deadline) {
    await sleep(25);
  }
  socket.close();

  const interim = events.find((event) => event.type === "interim");
  const final = events.findLast((event) => event.type === "final");
  if (!final) throw new Error(`${file}: no final event`);
  return {
    model: MODEL,
    sample: basename(file),
    firstInterimMs: interim ? Math.max(0, interim.tMs - bounds.startMs) : null,
    finalLatencyMs: Math.max(0, final.tMs - bounds.endMs),
    transcript: final.text,
  };
}

const results = [];
for (const file of files) {
  const result = await runSample(file);
  results.push(result);
  console.log(JSON.stringify(result));
}

const withInterim = results.filter((result) => result.firstInterimMs != null);
const average = (values) =>
  Math.round(values.reduce((total, value) => total + value, 0) / values.length);
console.log(
  JSON.stringify({
    model: MODEL,
    samples: results.length,
    meanFirstInterimMs: withInterim.length
      ? average(withInterim.map((result) => result.firstInterimMs))
      : null,
    meanFinalLatencyMs: average(results.map((result) => result.finalLatencyMs)),
  }),
);
