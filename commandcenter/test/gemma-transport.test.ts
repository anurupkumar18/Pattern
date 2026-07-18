import { describe, expect, it, vi } from "vitest";

import { OllamaHttpGemmaTransport } from "../src/router/gemma-transport.js";

describe("OllamaHttpGemmaTransport", () => {
  it("posts Ollama generate options and returns the response text", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ response: '{"verb":"status"}' }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );
    const transport = new OllamaHttpGemmaTransport({
      model: "gemma4",
      endpoint: "http://ollama.test/api/generate",
      fetchImpl,
      keepAlive: "10m",
      temperature: 0,
      numPredict: 123,
      think: false,
    });

    await expect(transport.complete("route this")).resolves.toBe(
      '{"verb":"status"}',
    );
    expect(fetchImpl).toHaveBeenCalledOnce();
    const [endpoint, request] = fetchImpl.mock.calls[0]!;
    expect(endpoint).toBe("http://ollama.test/api/generate");
    expect(JSON.parse(String(request?.body))).toEqual({
      model: "gemma4",
      prompt: "route this",
      stream: false,
      think: false,
      keep_alive: "10m",
      options: { temperature: 0, num_predict: 123 },
    });
  });

  it("fails when Ollama omits its response field", async () => {
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockResolvedValue(new Response(JSON.stringify({ done: true })));
    const transport = new OllamaHttpGemmaTransport({
      model: "gemma4",
      fetchImpl,
    });

    await expect(transport.complete("route this")).rejects.toThrow(
      "Ollama HTTP response must contain response",
    );
  });
});
