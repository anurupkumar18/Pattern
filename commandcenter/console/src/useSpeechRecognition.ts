import { useCallback, useEffect, useRef, useState } from "react";

interface SpeechRecognitionAlternativeLike {
  transcript: string;
}

interface SpeechRecognitionResultLike {
  isFinal: boolean;
  length: number;
  [index: number]: SpeechRecognitionAlternativeLike;
}

interface SpeechRecognitionEventLike {
  resultIndex: number;
  results: {
    length: number;
    [index: number]: SpeechRecognitionResultLike;
  };
}

interface SpeechRecognitionErrorLike {
  error: string;
}

interface SpeechRecognitionLike {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onresult: ((event: SpeechRecognitionEventLike) => void) | null;
  onerror: ((event: SpeechRecognitionErrorLike) => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
}

type RecognitionConstructor = new () => SpeechRecognitionLike;

declare global {
  interface Window {
    SpeechRecognition?: RecognitionConstructor;
    webkitSpeechRecognition?: RecognitionConstructor;
  }
}

export function useSpeechRecognition(onFinal: (text: string) => void) {
  const recognition = useRef<SpeechRecognitionLike | null>(null);
  const shouldListen = useRef(false);
  const onFinalRef = useRef(onFinal);
  const [listening, setListening] = useState(false);
  const [interim, setInterim] = useState("");
  const [error, setError] = useState<string | null>(null);

  onFinalRef.current = onFinal;

  const Recognition =
    typeof window !== "undefined"
      ? window.SpeechRecognition ?? window.webkitSpeechRecognition
      : undefined;
  const supported = Boolean(Recognition);

  useEffect(() => {
    if (!Recognition) return;
    const instance = new Recognition();
    instance.continuous = true;
    instance.interimResults = true;
    instance.lang = "en-US";
    instance.onresult = (event) => {
      let partial = "";
      for (
        let index = event.resultIndex;
        index < event.results.length;
        index += 1
      ) {
        const result = event.results[index];
        const text = result?.[0]?.transcript.trim() ?? "";
        if (!text) continue;
        if (result.isFinal) {
          onFinalRef.current(text);
          setInterim("");
        } else {
          partial += `${text} `;
        }
      }
      setInterim(partial.trim());
    };
    instance.onerror = (event) => {
      if (event.error !== "no-speech") setError(event.error);
    };
    instance.onend = () => {
      if (shouldListen.current) {
        try {
          instance.start();
        } catch {
          shouldListen.current = false;
          setListening(false);
        }
      } else {
        setListening(false);
      }
    };
    recognition.current = instance;
    return () => {
      shouldListen.current = false;
      instance.stop();
      recognition.current = null;
    };
  }, [Recognition]);

  const start = useCallback(() => {
    if (!recognition.current) return;
    setError(null);
    shouldListen.current = true;
    try {
      recognition.current.start();
      setListening(true);
    } catch {
      setError("Microphone is already starting.");
    }
  }, []);

  const stop = useCallback(() => {
    shouldListen.current = false;
    recognition.current?.stop();
    setListening(false);
    setInterim("");
  }, []);

  return { supported, listening, interim, error, start, stop };
}
