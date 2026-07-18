# Local streaming STT

This replaces browser Web Speech with a fully local path:

```text
browser AudioWorklet
  -> PCM16 mono 16 kHz over ws://127.0.0.1:4191
  -> RMS VAD and utterance windows in bridge.mjs
  -> warm whisper.cpp HTTP backend on 127.0.0.1:4192
  -> interim/final JSON events
```

Audio stays on the Mac. Both listeners bind to loopback, and runtime inference
makes no external request. The bridge keeps the whisper.cpp model warm and
re-transcribes the growing utterance window for interim text. It is streaming
at the audio/protocol layer, not a stateful incremental Whisper decoder.

## Build

Requirements: Apple Silicon macOS, Node 20+, Xcode Command Line Tools, CMake,
and `curl`. CMake can be installed with `brew install cmake`.

```bash
cd commandcenter/stt
./build.sh
./download-models.sh
```

`build.sh` pins whisper.cpp `v1.7.6` at
`a8d002cfd879315632a579e73f0148d06959de36` and configures
`-DGGML_METAL=ON`. It builds `whisper-server` and `whisper-cli`.
`download-models.sh` downloads `ggml-base.en.bin` and
`ggml-small.en.bin`. The vendor checkout, build output, model binaries,
generated WAVs, logs, and temporary benchmark output are gitignored.

Metal proof on the benchmark machine:

```text
whisper_backend_init_gpu: using Metal backend
ggml_metal_init: found device: Apple M4
whisper_model_load: Metal total size = 487.00 MB
```

## Start

Recommended accuracy-first command for the Dictator demo:

```bash
cd commandcenter/stt
STT_THREADS=8 STT_SILENCE_MS=700 ./start.sh small.en
```

Lower-latency alternative:

```bash
./start.sh base.en
```

The bridge starts and owns a warm whisper.cpp backend on port 4192, then
listens at `ws://127.0.0.1:4191`. The process should be started from an
ordinary local terminal. A restricted agent sandbox can deny Metal buffer
allocation even when the same binary runs correctly as a normal local
process.

Useful settings:

| Environment variable | Default | Meaning |
|---|---:|---|
| `STT_PORT` | `4191` | Public WebSocket port |
| `STT_BACKEND_PORT` | `4192` | Private whisper.cpp HTTP port |
| `STT_THREADS` | `4` | whisper.cpp CPU helper threads |
| `STT_SILENCE_MS` | `1000` | Silence required for a final |
| `STT_VAD_RMS` | `0.012` | Normalized RMS speech threshold |
| `STT_INTERIM_FIRST_MS` | `480` | Earliest interim snapshot |
| `STT_INTERIM_EVERY_MS` | `1600` | Later interim snapshot spacing |
| `WHISPER_MODEL` | `models/ggml-base.en.bin` | Explicit model path |

## Console integration

The browser client is implemented in
`commandcenter/console/src/stt/useLocalSTT.ts`. It exposes
`{ status, interim, finals, amplitude, start, stop, setHints }`, reconnects
with bounded exponential backoff, and uses the AudioWorklet in
`pcm-worklet.ts` to resample microphone input into 20 ms PCM16/16 kHz frames.

After the integrator's current `App.tsx` work lands, the final hookup is
exactly these three line replacements/additions:

```ts
import { useLocalSTT } from "./stt/useLocalSTT.js"; // replace useSpeechRecognition import
const speech = useLocalSTT(onFinalSpeech); // replace the old hook call
useEffect(() => speech.setHints(rows.map((row) => row.spokenName)), [rows, speech.setHints]); // after rows
```

Compatibility aliases (`supported`, `listening`, and `error`) preserve the
existing `speech.*` call sites, so no CommandBar, MainPane, Sidebar, or
protocol prop needs to change. `speech.amplitude` is ready for a later mic
visual hookup but is not required for functional integration.

Standalone verification:

```bash
cd commandcenter
npx vite --config console/vite.config.ts --host 127.0.0.1 --port 4181
open http://127.0.0.1:4181/stt-test.html
```

The harness includes start/stop, live interim text, final history, an
amplitude bar, editable hints, and a WAV picker that exercises the same
`LocalSTTSession` transport used by the hook.

### Wire protocol

The console should use an `AudioWorklet`, not `MediaRecorder`. It must
resample the microphone to 16 kHz and send raw signed 16-bit little-endian
mono PCM. Twenty-millisecond frames are recommended: 320 samples or 640
bytes per binary WebSocket message.

1. Open `ws://127.0.0.1:4191`.
2. Send one UTF-8 JSON control message when capture starts:

   ```json
   {
     "type": "start",
     "sampleRate": 16000,
     "vocabulary": ["evals", "Noah", "design agent"]
   }
   ```

   `vocabulary` is optional but should contain the currently visible chat
   names. It is capped at 64 entries and becomes a local Whisper prompt. This
   materially improved short proper-name commands in the benchmark.
3. Send binary PCM frames continuously, including silence while capture is
   active. Continuous silence lets VAD finalize after about one second.
4. Render incoming events:

   ```json
   {"type":"interim","text":"Move to evals.","tMs":3995}
   {"type":"final","text":"Move to evals.","tMs":5881}
   ```

   `tMs` is the event emission time in milliseconds since the most recent
   `start` message. An interim may revise earlier text. Only `final` should be
   dispatched into command routing.
5. Send `{"type":"stop"}` to flush an active utterance immediately. Closing
   the socket cancels delivery.

There is no separate ready event. A successful WebSocket `open` means the
model backend is loaded and the bridge is ready.

## End-to-end test

The committed generator uses the macOS Samantha voice and ffmpeg to create
three local PCM16/16 kHz command-length WAVs. The WAVs are ignored by git.

```bash
./generate-samples.sh
node test-wav.mjs samples/move-to-evals.wav
```

Observed accuracy-gated event log from `small.en` with the chat vocabulary:

```json
{"type":"interim","text":"Moved","tMs":8034}
{"type":"final","text":"Move to evals.","tMs":9289}
```

The later-than-benchmark event came while other local hackathon model
services were active. It demonstrates the end-to-end contract and also shows
that shared-GPU load can materially affect tail latency.

## Apple M4 benchmark

Machine: Apple M4, macOS 26.5.2. Audio was generated locally with the macOS
Samantha voice at 190 words per minute, converted to PCM16 mono 16 kHz, and
padded with 300 ms leading and 1.4 s trailing silence. The three phrases were:
`move to evals`, `switch to Noah`, and
`tell the design agent to use staging`. Other hackathon services remained
running, so these are loaded-machine numbers rather than isolated peak
throughput.

`first interim` is measured from detected speech start to the first interim
event. `final latency` is measured from detected speech end to the final
event and therefore includes the one-second VAD silence gate.

| Model | Phrase | First interim | Final latency | Final transcript |
|---|---|---:|---:|---|
| base.en | move to evals | 1785 ms | 2939 ms | `Move to Evels.` |
| base.en | switch to Noah | 662 ms | 2232 ms | `Switch to Noah` |
| base.en | tell design agent use staging | 741 ms | 2255 ms | `Tell the design agent to use staging.` |
| base.en | **mean / exact** | **1063 ms** | **2475 ms** | **2/3 exact** |
| small.en, 8 threads | move to evals | 5001 ms | 5631 ms | `Move to evals.` |
| small.en, 8 threads | switch to Noah | 2182 ms | 4085 ms | `Switch to Noah.` |
| small.en, 8 threads | tell design agent use staging | 1738 ms | 4125 ms | `Tell the design agent to use staging.` |
| small.en, 8 threads | **mean / exact** | **2974 ms** | **4614 ms** | **3/3 exact** |

Run the same benchmark with:

```bash
STT_BENCH_MODEL=small.en node benchmark.mjs samples/*.wav
```

### Recommendation

Use `small.en` for the demo command router. It was exact on all three short
commands, including the non-dictionary chat name `evals`; `base.en` was about
twice as fast but changed that target to `Evels`. A wrong chat target is more
damaging than the measured latency increase. Keep `base.en` as the
low-latency fallback if the console adds deterministic alias/fuzzy matching
that safely resolves near-homophones without risking the wrong chat.

Known gap: the bridge repeatedly transcribes in-memory utterance snapshots
rather than preserving decoder state between chunks. This is deliberately
small and reliable for the hackathon, but a native streaming decoder would
be the next latency optimization.

## Follow-up command benchmark

Expanded hints (`evals`, `smoke-shell`, `Noah`, `design agent`, `move`,
`next`, `send`, `stop`) did not repair `base.en`: it still transcribed
`evals` as `Evels`. The loaded-machine mean improved to 910 ms first interim
and 1839 ms final latency, but exactness remained 2/3.

`small.en` with the same hints, eight threads, and a 700 ms VAD window stayed
3/3 exact while improving to 1493 ms mean first interim and 2629 ms mean
final latency. This is the retained demo configuration:

```bash
STT_THREADS=8 STT_SILENCE_MS=700 ./start.sh small.en
```

The 700 ms gate removed roughly two seconds from the earlier loaded-machine
small-model final mean without changing command accuracy. The live bridge on
port 4191 is running with this configuration.
