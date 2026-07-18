// Visual verification driver: launches headless Chrome over CDP, exercises
// the Dictator console (chip pulse, staged beat, shake, hover states), and
// writes screenshots to docs/design/screenshots/.
// Usage: node scripts/shoot-ui.mjs
import { execFile, spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";

import { WebSocket } from "ws";

const CHROME =
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const APP_URL = "http://127.0.0.1:4180/";
const WS_URL = "ws://127.0.0.1:4180/ws";
const OUT_DIR = "/tmp";
const DEBUG_PORT = 9333;

const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    `--remote-debugging-port=${DEBUG_PORT}`,
    "--window-size=1440,900",
    "--no-first-run",
    "--no-default-browser-check",
    `--user-data-dir=/tmp/dictator-shoot-profile-${process.pid}`,
    "about:blank",
  ],
  { stdio: "ignore" },
);
process.on("exit", () => chrome.kill());

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

async function httpJson(path, method = "GET") {
  const response = await fetch(`http://127.0.0.1:${DEBUG_PORT}${path}`, {
    method,
  });
  return response.json();
}

async function waitForChrome() {
  for (let attempt = 0; attempt < 160; attempt += 1) {
    try {
      return await httpJson("/json/version");
    } catch {
      await sleep(250);
    }
  }
  throw new Error("Chrome debugger never came up");
}

let messageId = 0;
const pendingReplies = new Map();
let cdp;

function send(method, params = {}, sessionId) {
  messageId += 1;
  const id = messageId;
  cdp.send(JSON.stringify({ id, method, params, sessionId }));
  return new Promise((resolveReply, rejectReply) => {
    pendingReplies.set(id, { resolveReply, rejectReply });
  });
}

async function main() {
  await waitForChrome();
  const target = await httpJson(
    `/json/new?${encodeURIComponent(APP_URL)}`,
    "PUT",
  );
  cdp = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((done) => cdp.on("open", done));
  cdp.on("message", (raw) => {
    const message = JSON.parse(raw.toString());
    if (message.id && pendingReplies.has(message.id)) {
      const { resolveReply, rejectReply } = pendingReplies.get(message.id);
      pendingReplies.delete(message.id);
      if (message.error) rejectReply(new Error(message.error.message));
      else resolveReply(message.result);
    }
  });
  await send("Page.enable");
  await send("Runtime.enable");
  await send("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 900,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await send("Page.reload", { ignoreCache: true });
  await sleep(250);

  async function shot(name) {
    const { data } = await send("Page.captureScreenshot", { format: "png" });
    writeFileSync(resolve(OUT_DIR, name), Buffer.from(data, "base64"));
    console.log("saved", name);
  }

  async function evalJs(expression) {
    const { result } = await send("Runtime.evaluate", {
      expression,
      returnByValue: true,
    });
    return result.value;
  }

  for (let attempt = 0; attempt < 80; attempt += 1) {
    if (await evalJs("Boolean(document.querySelector('.app-shell'))")) break;
    await sleep(250);
  }
  await sleep(1_000); // First snapshot and chat history.

  async function rectOf(selector) {
    return evalJs(`(() => {
      const el = document.querySelector(${JSON.stringify(selector)});
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
    })()`);
  }

  async function hover(selector) {
    const point = await rectOf(selector);
    if (!point) throw new Error(`no element for ${selector}`);
    await send("Input.dispatchMouseEvent", {
      type: "mouseMoved",
      x: point.x,
      y: point.y,
    });
  }

  // 1. Base state.
  await shot("dictator-final.png");

  // Companion socket: server broadcasts loop events to every client, so
  // utterances sent here animate the browser's chips.
  const companion = new WebSocket(WS_URL);
  await new Promise((done) => companion.on("open", done));
  const say = (text) =>
    companion.send(JSON.stringify({ type: "utterance", text, sttMs: 0 }));

  // 2. Verb pulse + row glow: focus resolves to the smoke-shell agent.
  say("switch to smoke shell");
  await sleep(350); // Mid-pulse (600ms) and mid-glow (900ms).
  await shot("dictator-pulse-move.png");
  await sleep(1200);

  // 3. Unresolved-target shake on the Send chip.
  say("tell the mars rover to reboot");
  await sleep(200); // Mid-shake (400ms).
  await shot("dictator-shake-send.png");
  await sleep(900);

  // 4. Staged parse-before-act beat via the composer (client-local).
  await evalJs(`(() => {
    const textarea = document.querySelector(".composer textarea");
    const setter = Object.getOwnPropertyDescriptor(
      HTMLTextAreaElement.prototype, "value").set;
    setter.call(textarea, "send smoke shell rerun the eval suite");
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  })()`);
  await sleep(150);
  await evalJs(
    `document.querySelector(".composer form, form.composer").requestSubmit()`,
  );
  await sleep(400); // Inside the 1.2s send hold.
  await shot("dictator-staged-send.png");
  await evalJs(`window.dispatchEvent(
    new KeyboardEvent("keydown", { key: "Escape", bubbles: true }))`);
  await sleep(600);

  // 5. Hover the cluster: progressive disclosure + expanded chip hint.
  await evalJs(`(() => {
    const hud = document.querySelector(".chip-hud");
    const chip = document.querySelector(".chip-hud .chip");
    hud?.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    chip?.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
  })()`);
  await sleep(450);
  await shot("dictator-hud.png");

  // 6. Voice help popover.
  await evalJs(`document.querySelector(
    ".voice-wrap .icon-button[aria-label='Voice help']").click()`);
  await sleep(350);
  await shot("dictator-voice-help.png");
  await evalJs(`document.activeElement?.blur?.()`);

  // 7. Selected chat detail (click first sidebar row).
  await evalJs(`document.querySelector(".chat-row")?.click()`);
  await sleep(600);
  await shot("dictator-selected.png");

  companion.close();
  cdp.close();
  chrome.kill();
  console.log("done ->", OUT_DIR);
  process.exit(0);
}

main().catch((error) => {
  console.error(error);
  chrome.kill();
  process.exit(1);
});
