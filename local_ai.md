# OpenClicky — Local AI Setup

Goal: run OpenClicky fully offline / private, with **no OpenAI or Anthropic API keys**.

Target pipeline:

```
Apple on-device Speech (STT)  →  local Gemma 4 12B via Ollama (LLM)  →  macOS AVSpeechSynthesizer (TTS)
```

Every layer is keyless and on-device. Hardware: M4 Pro, 24 GB unified RAM (the binding constraint). The 12B QAT model ≈ 8 GB resident, ~24 tok/s, 100% GPU.

---

## 1. Environment setup (done)

- **Ollama** installed via the official app cask:
  - `brew install --cask ollama` (the Homebrew *formula* `ollama` is broken — it ships without `llama-server` — so the **app cask** is required).
  - The app auto-starts the server at login on `http://127.0.0.1:11434`.
- **Model pulled:** `hf.co/unsloth/gemma-4-12b-it-GGUF:UD-Q4_K_XL` (7.4 GB download, the QAT quant). Multimodal; `mmproj-F16.gguf` is in the same HF repo if we ever wire local vision.
  - Re-pull command if needed: `ollama pull hf.co/unsloth/gemma-4-12b-it-GGUF:UD-Q4_K_XL`
  - Chat manually: `ollama run hf.co/unsloth/gemma-4-12b-it-GGUF:UD-Q4_K_XL`
- **Verified standalone:** clean output with `think:false`, ~24 tok/s, streaming NDJSON shape confirmed.

## 2. macOS system settings (done)

- **Dictation ON** — System Settings → Keyboard → Dictation (required; Apple's on-device `SFSpeechRecognizer` refuses to run otherwise → `kLSRErrorDomain Code=201 "Siri and Dictation are disabled"`). Language English (India).
- **Permissions granted:** Accessibility, Microphone, Screen Recording. (Accessibility is required for the global push-to-talk key tap.)
- For a better-sounding voice (optional): System Settings → Accessibility → Spoken Content → System Voice → Manage Voices → download an enhanced/Siri voice (still on-device).

## 3. App settings to select (in OpenClicky)

- **Settings → Voice → Response voice model → "Gemma 4 12B (Local)"**
- **Settings → Voice → Listening/transcription → Apple** (on-device STT)
- **Settings → Voice → Playback → Playback engine → "macOS Voice (Local)"**

---

## 4. Code changes

### A. Push-to-talk → toggle on a real key (for the Dune macropad)
File: `cursor-buddy/BuddyDictationManager.swift`
- Added shortcut option **`controlOptionK`** → `Control + Option + K` (real-key combo, keycode 40); `pushToTalkKeyCode` now derives from the active option.
- Set `currentShortcutOption = .controlOptionK`.
- Added `usesToggleActivation = true` (tap to start, tap to stop — suits a macropad single keypress).
- Renamed internal `spaceShortcutModifierFlags` → `keyShortcutModifierFlags`.

File: `cursor-buddy/CompanionManager.swift` (`handleShortcutTransition`)
- Toggle behavior: first tap starts dictation, second tap stops; real key-ups ignored in toggle mode.
- Added `isShortcutDictationActive` and extracted `handleShortcutReleased()`.

Dune mapping: macropad **button 2 → Control + Option + K** (single tap).

### B. Local LLM provider (Gemma via Ollama)
New file: `cursor-buddy/LocalLLMAPI.swift`
- Streams from Ollama's native `/api/chat` with `think:false` (clean output, no thinking-channel leak), `keep_alive:10m`, `num_ctx:8192`. Image support included for a future vision scope. Server override via `OLLAMA_BASE_URL` env var.

File: `cursor-buddy/OpenClickyModelCatalog.swift`
- Added provider `.local` (displayName "Local").
- Added model option **"Gemma 4 12B (Local)"** — its id is the Ollama ref, passed straight through.

File: `cursor-buddy/CompanionManager.swift`
- Added `localLLMAPI` client + `analyzeLocalVoiceResponse`.
- Handled `.local` in every exhaustive `OpenClickyModelProvider` switch (routing, warm-ups, model settings, telemetry, two pointing paths). Local screen-pointing left `.unsupported` (deferred to vision scope).

### C. Local TTS provider (macOS system voice)
File: `cursor-buddy/ElevenLabsTTSClient.swift`
- Added `OpenClickyTTSProvider.system` (displayName "macOS Voice (Local)").
- New `SystemSpeechTTSClient` (in this file so it can reach the `fileprivate` `StreamingTTSSession.init`).
- **Final approach: speaks directly via `AVSpeechSynthesizer.speak()`** — NOT offline PCM render. The first attempt rendered text→PCM via `AVSpeechSynthesizer.write` and fed the `AVAudioEngine` pipeline; that conflicted with the running playback engine (HAL overload, multi-second stalls, app hang, only the filler played). The rewrite:
  - `speak()` directly; the synthesizer owns its own audio output (no engine conflict).
  - Sentences serialized via a `speechTail` task chain (in order, no overlap); completion awaited via `AVSpeechSynthesizerDelegate` (`didFinish`/`didCancel`) continuations.
  - `fetchSentenceSamples` returns `[]` (the session's PCM path is unused; speech happens inside the fetch closure). Empty samples also disable pre-baked fillers for this provider.
  - Pre-response filler set to `false` for `.system` in `CompanionManager` (no PCM fillers).

File: `cursor-buddy/CompanionManager.swift`
- Added `systemSpeechTTSClient` client + `.system` in all TTS provider switches.
- Leaving a GPT-Realtime model now defaults playback to the keyless `.system` voice.

File: `cursor-buddy/OpenClickySettingsWindowManager.swift`
- Added the `.system` case to the playback settings detail switch (it auto-appears in the Playback engine row).

### Build notes
- Project uses Xcode 16 **synchronized file groups**, so new files (`LocalLLMAPI.swift`) are auto-included — no `project.pbxproj` edits.
- Signing: personal team `Nisarg Thakkar`, bundle IDs renamed to `com.itsnisargthakkar.openclicky[.widgets]`; App Group removed from the widget (free team can't register it).
- `swiftc -parse` does NOT catch non-exhaustive switches — the Xcode build is the real check. One was missed and fixed: combined-case `case .cartesia, .elevenLabs, .microsoftEdge, .deepgram:` (now includes `.system`).

---

## 5. Testing status

### Verified working
- [x] App builds & runs (personal-team signing).
- [x] Ollama + Gemma 4 12B standalone (~24 tok/s).
- [x] STT: Apple on-device transcribes voice.
- [x] Routing: voice turn hits `LocalLLMAPI` (`modelProvider:local`, `authMode:local_ollama_no_key`), Gemma produced correct answer ("the capital of France is Paris").
- [x] Push-to-talk key trigger fires the dictation session (`source:keyboardShortcut`).
- [x] macOS voice **filler** phrase plays ("give me a second").

### Remaining to test (do when free)
- [ ] **macOS voice speaks the full answer** — rebuild after the `speak()` rewrite; confirm you hear the full spoken answer (there's now no filler — it goes straight to the answer), the turn is fast, no `HALC overload` / `AUCrashHandler` / hang. **Main thing to verify.**
- [ ] **Toggle hotkey end-to-end** — tap Control+Option+K once to start, tap again to stop; confirm it behaves as toggle (not hold).
- [ ] **Dune macropad** — map button 2 → Control+Option+K (single tap) and confirm it starts/stops listening like the keyboard.
- [ ] **Multi-sentence answer** — ask something longer; confirm sentences play in order without overlap.
- [ ] **Several turns in a row** — confirm clean start/stop between turns (stopPlayback cancels speech).
- [ ] (Optional) Download an enhanced macOS voice and confirm it's used.

### History / fallback
- v1 (offline PCM render via `AVSpeechSynthesizer.write` → `AVAudioEngine`): filler played but answer hung ~33 s / froze. Root cause: write-render conflicts with the running playback engine. **Replaced** by the direct-`speak()` approach above.
- If direct `speak()` ever has issues, note: it does not stream PCM, so the on-screen waveform/caption may differ slightly from cloud voices, but audio is the canonical reliable path.

---

## 6. Out of scope (not localized)
- **Agent Mode** (autonomous coding via the bundled Codex runtime) — still needs Codex/OpenAI; not localized.
- **Screen pointing / vision** (`[POINT:x,y]`) — still routes to cloud providers; local pointing left `.unsupported`. Gemma 4 is multimodal and `LocalLLMAPI` already accepts images, so this is a future add.
- **TTS still has ElevenLabs/Cartesia/Deepgram/Edge options** — only "macOS Voice (Local)" is fully offline + keyless.

## 7. Debugging / logs
- **Xcode console** (`Cmd+Shift+C`): look for `🧠 analyzeLocalVoiceResponse` (Gemma chosen).
- **OpenClicky structured log:** `~/Library/Application Support/OpenClicky/Logs/messages-<date>.jsonl`
  - Confirm local end-to-end: `grep -E 'local_ollama_no_key|SystemSpeechTTSClient' ~/Library/Application\ Support/OpenClicky/Logs/messages-*.jsonl`
  - A correct local turn shows `modelProvider:local` and `playbackEngine:system`.
- **Ollama log:** `tail -f ~/.ollama/logs/server.log`
