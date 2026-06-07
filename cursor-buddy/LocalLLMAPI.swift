//
//  LocalLLMAPI.swift
//  Local LLM client for OpenClicky's fully-offline voice path.
//
//  Talks to a local Ollama server (https://ollama.com) over its native
//  /api/chat endpoint. This is intentionally NOT the OpenAI-compatible
//  /v1/chat/completions endpoint: the native endpoint lets us pass
//  `think: false` so Gemma-style hybrid-thinking models return a clean
//  spoken answer instead of leaking reasoning-channel tokens into TTS.
//
//  Mirrors the streaming shape of `ClaudeAPI`/`OpenAIAPI`
//  (`analyzeImageStreaming` returning the full text + duration, streaming
//  chunks to the caller on the main actor) so it slots into the existing
//  `analyzeVoiceResponse` provider switch without changing the call sites.
//

import Foundation

/// Streaming client for a local Ollama-hosted model. No API key, no network
/// egress — inference happens on the user's machine.
final class LocalLLMAPI {
    var model: String
    var maxOutputTokens: Int

    /// Base URL of the local Ollama server. Override with the
    /// `OLLAMA_BASE_URL` launch environment variable; defaults to the
    /// standard local Ollama port.
    private let baseURL: URL
    private let session: URLSession

    init(model: String, maxOutputTokens: Int = 8_192) {
        self.model = model
        self.maxOutputTokens = maxOutputTokens

        let configuredBaseURL = ProcessInfo.processInfo.environment["OLLAMA_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = URL(string: (configuredBaseURL?.isEmpty == false ? configuredBaseURL! : "http://127.0.0.1:11434"))
            ?? URL(string: "http://127.0.0.1:11434")!

        // Local inference can stream for a while; keep generous timeouts.
        // Local connection only — no TLS warm-up needed.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1_200
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Best-effort preload so the first real turn doesn't pay the
    /// model's cold-load cost (~5s for a 12B). Fire-and-forget.
    func warmUp() {
        Task { [weak self] in
            guard let self else { return }
            var request = URLRequest(url: self.baseURL.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": self.model,
                "messages": [["role": "user", "content": "hi"]],
                "think": false,
                "stream": false,
                "keep_alive": "10m",
                "options": ["num_predict": 1]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await self.session.data(for: request)
        }
    }

    /// Stream a response from the local model. Images, when present, are
    /// attached to the final user turn as base64 (Ollama's multimodal
    /// format) — used by the optional vision/pointing path.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var messages: [[String: Any]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append([
                "role": "assistant",
                "content": assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
        }

        var userMessage: [String: Any] = ["role": "user", "content": userPrompt]
        if !images.isEmpty {
            userMessage["images"] = images.map { $0.data.base64EncodedString() }
        }
        messages.append(userMessage)

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            // Disable the hybrid-thinking channel so spoken replies stay clean.
            "think": false,
            "stream": true,
            // Keep the model resident between voice turns.
            "keep_alive": "10m",
            // Cap context to bound unified-memory use on Apple Silicon.
            "options": ["num_ctx": 8_192]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalLLMAPI.makeError("Local model server returned an unexpected response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LocalLLMAPI.makeError(
                "Local model server error (HTTP \(httpResponse.statusCode)). Is Ollama running and the model pulled?"
            )
        }

        var accumulatedText = ""
        // Ollama streams newline-delimited JSON objects, one per line.
        for try await line in bytes.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            guard
                let lineData = trimmedLine.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let errorMessage = object["error"] as? String {
                throw LocalLLMAPI.makeError(errorMessage)
            }

            if
                let message = object["message"] as? [String: Any],
                let contentChunk = message["content"] as? String,
                !contentChunk.isEmpty
            {
                accumulatedText += contentChunk
                let chunk = contentChunk
                await MainActor.run { onTextChunk(chunk) }
            }

            if let done = object["done"] as? Bool, done { break }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedText, duration: duration)
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(
            domain: "LocalLLMAPI",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
