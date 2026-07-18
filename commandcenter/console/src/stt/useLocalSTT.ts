import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import pcmWorkletUrl from "./pcm-worklet.ts?worker&url";
import {
  LocalSTTSession,
  type LocalSTTStatus,
} from "./local-stt-session.js";

export interface LocalSTTHook {
  status: LocalSTTStatus;
  interim: string;
  finals: string[];
  amplitude: number;
  start: () => Promise<void>;
  stop: () => void;
  setHints: (words: string[]) => void;
  /** Compatibility aliases make replacing useSpeechRecognition a three-line hookup. */
  supported: boolean;
  listening: boolean;
  error: string | null;
}

interface PcmWorkletMessage {
  type: "pcm";
  pcm: ArrayBuffer;
  amplitude: number;
}

export function useLocalSTT(
  onFinal?: (text: string) => void,
  url = "ws://127.0.0.1:4191",
): LocalSTTHook {
  const [status, setStatus] = useState<LocalSTTStatus>("idle");
  const [interim, setInterim] = useState("");
  const [finals, setFinals] = useState<string[]>([]);
  const [amplitude, setAmplitude] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const onFinalRef = useRef(onFinal);
  const streamRef = useRef<MediaStream | null>(null);
  const contextRef = useRef<AudioContext | null>(null);
  const sourceRef = useRef<MediaStreamAudioSourceNode | null>(null);
  const workletRef = useRef<AudioWorkletNode | null>(null);
  const activeRef = useRef(false);
  const generationRef = useRef(0);
  const sessionRef = useRef<LocalSTTSession | null>(null);
  onFinalRef.current = onFinal;

  if (!sessionRef.current) {
    sessionRef.current = new LocalSTTSession({
      url,
      onStatus: setStatus,
      onInterim: (event) => setInterim(event.text),
      onFinal: (event) => {
        setInterim("");
        if (event.text) {
          setFinals((current) => [...current, event.text]);
          onFinalRef.current?.(event.text);
        }
      },
      onError: (nextError) => {
        setError(nextError.message);
        setStatus("error");
      },
    });
  }

  const cleanupAudio = useCallback(async () => {
    workletRef.current?.disconnect();
    sourceRef.current?.disconnect();
    workletRef.current = null;
    sourceRef.current = null;

    for (const track of streamRef.current?.getTracks() ?? []) track.stop();
    streamRef.current = null;

    const context = contextRef.current;
    contextRef.current = null;
    if (context && context.state !== "closed") {
      await context.close();
    }
  }, []);

  const start = useCallback(async () => {
    if (activeRef.current) return;
    activeRef.current = true;
    const generation = generationRef.current + 1;
    generationRef.current = generation;
    setStatus("connecting");
    setError(null);
    setInterim("");
    setAmplitude(0);

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: { ideal: 1 },
          sampleRate: { ideal: 16_000 },
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });
      if (!activeRef.current || generationRef.current !== generation) {
        for (const track of stream.getTracks()) track.stop();
        return;
      }

      const context = new AudioContext({ latencyHint: "interactive" });
      streamRef.current = stream;
      contextRef.current = context;
      await context.audioWorklet.addModule(pcmWorkletUrl);

      const source = context.createMediaStreamSource(stream);
      const worklet = new AudioWorkletNode(context, "local-stt-pcm", {
        numberOfInputs: 1,
        numberOfOutputs: 0,
        channelCount: 1,
        channelCountMode: "explicit",
      });
      sourceRef.current = source;
      workletRef.current = worklet;
      worklet.port.onmessage = (
        message: MessageEvent<PcmWorkletMessage>,
      ) => {
        if (message.data.type !== "pcm" || !activeRef.current) return;
        const nextAmplitude = Math.max(
          0,
          Math.min(1, message.data.amplitude),
        );
        setAmplitude((current) =>
          Math.max(nextAmplitude, current * 0.78),
        );
        sessionRef.current?.pushPcm(message.data.pcm);
      };
      source.connect(worklet);
      await context.resume();

      if (!activeRef.current || generationRef.current !== generation) {
        await cleanupAudio();
        return;
      }
      await sessionRef.current?.start();
    } catch {
      activeRef.current = false;
      sessionRef.current?.destroy();
      await cleanupAudio();
      setError("Local microphone or STT bridge unavailable.");
      setStatus("error");
    }
  }, [cleanupAudio]);

  const stop = useCallback(() => {
    if (!activeRef.current && status === "idle") return;
    activeRef.current = false;
    generationRef.current += 1;
    sessionRef.current?.stop();
    setInterim("");
    setAmplitude(0);
    void cleanupAudio();
  }, [cleanupAudio, status]);

  const setHints = useCallback((words: string[]) => {
    sessionRef.current?.setHints(words);
  }, []);

  useEffect(
    () => () => {
      activeRef.current = false;
      sessionRef.current?.destroy();
      void cleanupAudio();
    },
    [cleanupAudio],
  );

  return useMemo(
    () => ({
      status,
      interim,
      finals,
      amplitude,
      start,
      stop,
      setHints,
      supported:
        typeof navigator !== "undefined" &&
        Boolean(navigator.mediaDevices) &&
        typeof AudioWorkletNode !== "undefined",
      listening: status === "listening",
      error,
    }),
    [amplitude, error, finals, interim, setHints, start, status, stop],
  );
}
