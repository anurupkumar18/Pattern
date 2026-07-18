declare const sampleRate: number;
declare function registerProcessor(
  name: string,
  processorCtor: new () => AudioWorkletProcessor,
): void;
declare abstract class AudioWorkletProcessor {
  readonly port: MessagePort;
  abstract process(inputs: Float32Array[][]): boolean;
}

const OUTPUT_RATE = 16_000;
const FRAME_SAMPLES = 320;

class LocalSTTPcmProcessor extends AudioWorkletProcessor {
  private readonly ratio = sampleRate / OUTPUT_RATE;
  private inputBuffer: number[] = [];
  private nextInputIndex = 0;
  private frame = new Int16Array(FRAME_SAMPLES);
  private frameOffset = 0;
  private frameSumSquares = 0;

  process(inputs: Float32Array[][]): boolean {
    const channel = inputs[0]?.[0];
    if (!channel?.length) return true;

    for (const sample of channel) this.inputBuffer.push(sample);
    this.resampleAvailableInput();
    return true;
  }

  private resampleAvailableInput(): void {
    while (this.nextInputIndex + 1 < this.inputBuffer.length) {
      const leftIndex = Math.floor(this.nextInputIndex);
      const fraction = this.nextInputIndex - leftIndex;
      const left = this.inputBuffer[leftIndex] ?? 0;
      const right = this.inputBuffer[leftIndex + 1] ?? left;
      const sample = left + (right - left) * fraction;
      this.pushSample(sample);
      this.nextInputIndex += this.ratio;
    }

    const consumed = Math.floor(this.nextInputIndex);
    if (consumed > 0) {
      this.inputBuffer = this.inputBuffer.slice(consumed);
      this.nextInputIndex -= consumed;
    }
  }

  private pushSample(value: number): void {
    const clipped = Math.max(-1, Math.min(1, value));
    this.frame[this.frameOffset] =
      clipped < 0 ? Math.round(clipped * 32_768) : Math.round(clipped * 32_767);
    this.frameOffset += 1;
    this.frameSumSquares += clipped * clipped;

    if (this.frameOffset !== FRAME_SAMPLES) return;

    const pcm = this.frame.buffer as ArrayBuffer;
    this.port.postMessage(
      {
        type: "pcm",
        pcm,
        amplitude: Math.min(
          1,
          Math.sqrt(this.frameSumSquares / FRAME_SAMPLES),
        ),
      },
      [pcm],
    );
    this.frame = new Int16Array(FRAME_SAMPLES);
    this.frameOffset = 0;
    this.frameSumSquares = 0;
  }
}

registerProcessor("local-stt-pcm", LocalSTTPcmProcessor);
