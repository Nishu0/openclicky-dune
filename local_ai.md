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

---

# Session 2026-06-15 — Kokoro voice, multilingual (Hindi), local-only mode, local browser-search

This session moved the local stack from the robotic macOS voice to **Kokoro** (local neural TTS), added **automatic per-sentence language routing** (so Hindi replies use a Hindi voice), enforced **fully-local mode** (no silent cloud/web routing), turned off **launch task summaries**, and built a **fully-local browser-search** (open browser → screenshot → Gemma reads results aloud).

Updated pipeline:

```
Apple STT  →  local Gemma 4 12B (Ollama)  →  Kokoro local neural TTS (:8880)
                                            (auto-switches voice per language)
```

## 8. Kokoro (local neural TTS) — start/stop

- Repo at `~/Kokoro-FastAPI` (has its own `.venv` + `uv`). Full Kokoro v1.0 voice pack present, incl. Hindi voices `hf_alpha`, `hf_beta`, `hm_omega`, `hm_psi`.
- **Start (CPU, recommended):** `cd ~/Kokoro-FastAPI && ./start-cpu-mac.sh` — serves on `http://127.0.0.1:8880`. CPU mode is deliberate: running Kokoro on the Metal GPU contends with Ollama and slows Gemma to a crawl; Kokoro's 82M model is fast enough on CPU.
- **Stop:** `lsof -ti:8880 | xargs kill`
- **Verify both servers:**
  ```sh
  curl -s http://127.0.0.1:11434/api/tags >/dev/null && echo "Ollama OK"
  curl -s http://127.0.0.1:8880/v1/audio/voices >/dev/null && echo "Kokoro OK"
  ```
- App setting: **Settings → Voice → Playback → "Kokoro (Local Neural)"**, voice e.g. `af_heart`. Override server with `KOKORO_BASE_URL`.
- `KokoroTTSClient` (in `ElevenLabsTTSClient.swift`) POSTs `/v1/audio/speech` with `response_format:"pcm"`; Kokoro infers language from the **voice-name prefix** (a/b=English, h=Hindi, e=Spanish, f=French, i=Italian, j=Japanese, p=Portuguese, z=Chinese).

## 9. Automatic multilingual voice routing (Hindi etc.)
File: `cursor-buddy/ElevenLabsTTSClient.swift`
- Added `import NaturalLanguage` and a new on-device `OpenClickyTTSLanguageRouter`.
- Detects each spoken sentence's dominant language with `NLLanguageRecognizer` (min 4 letters, confidence ≥ 0.65) — fully local, no network.
- **Kokoro:** `kokoroVoice(for:configuredVoice:)` maps detected language → a matching voice (Hindi → `hf_alpha`, etc.); English/unknown keeps the user's configured voice. Wired into `KokoroTTSClient.fetchSentenceSamples`.
- **macOS voice:** `appleVoice(for:configuredVoiceLanguage:)` maps language → a system voice code (Hindi → `hi-IN`, the **Lekha** voice). Wired into `SystemSpeechTTSClient.speakOne`.
- Net effect: a Hindi reply is spoken by a Hindi voice automatically, and it switches back to English on the next English sentence. No setting to manage.

### 9a. Force native script (so Hindi actually uses the Hindi voice)
File: `cursor-buddy/CompanionManager.swift` (`companionVoiceResponseSystemPrompt`, both response-style blocks)
- Added a `language:` rule: reply in the user's language and **write non-English replies in that language's native script, never romanized** — Hindi must be **Devanagari** (फूलों की क्यारी), not "phoolon ki kyari". The `all lowercase` rule now applies to Latin scripts only.
- Why: the router detects language by **script**. Gemma was emitting romanized Hindi (Latin letters) → detected as English → spoken by the English voice (sounds robotic/garbled). Devanagari output → detected as Hindi → `hf_alpha`/Lekha. This is why a poem could come out "one verse good, one robotic" before the fix.

## 10. Local-only mode (no web search / cloud agents)
Files: `cursor-buddy/AppBundleConfiguration.swift`, `cursor-buddy/CompanionManager.swift`, `cursor-buddy/OpenClickySettingsWindowManager.swift`
- New `AppBundleConfiguration.localOnlyModeEnabled()` — **default ON** (key `openClickyLocalOnlyMode`; env override `OPENCLICKY_LOCAL_ONLY=0/1`).
- Background: a voice request like "latest news" was being **silently routed to cloud Agent Mode** (Codex), which has web search and authenticates via the local **ChatGPT sign-in** at `~/.codex/auth.json` (symlinked into the Codex home) — so it worked even with `OPENAI_API_KEY` commented out in `secrets.env`. The key was never used; the ChatGPT login was.
- When ON, the five voice→agent routing entry points bail out (stay local): `implicitAgentTaskInstruction`, `smartAgentRouteDecision`, `hybridAgentTaskInstruction`, `startExplicitAgentTaskIfRequested`, `startAgentTaskFromDeferredLiveAgentRouteIfNeeded`.
- Setting: **Settings → AI Providers → Agent tools → "Local-only mode (no web search or cloud agents)"**.
- Note: opening the Agents dashboard manually is still cloud — local-only only gates the silent voice auto-routing. (A harder lock — disabling the dashboard / unlinking `~/.codex/auth.json` / `codex logout` — was discussed but not applied.)

## 11. Turn off "summarize every past task on launch"
Files: `cursor-buddy/AppBundleConfiguration.swift`, `cursor-buddy/CompanionManager.swift`, `cursor-buddy/OpenClickySettingsWindowManager.swift`
- On launch the app restored interrupted Agent Mode tasks and **auto-resumed each one** (firing a "resume/summarize this task" LLM prompt per task). New `autoResumeAgentTasksOnLaunchEnabled()` gates `resumeRestoredAgentTasksIfNeeded` — **default OFF**, so restored tasks stay in the dashboard but no longer summarize on every start.
- Setting: **Settings → AI Providers → Agent tools → "Resume past tasks on launch"** (off).

## 12. Fully-local browser-search (open browser → screenshot → Gemma reads)
File: `cursor-buddy/CompanionManager.swift`
- New `handleLocalBrowserSearchIfNeeded(from:)` in the voice routing chain (before computer-use). **Gated to Local-only mode** (when off, search falls through to cloud Agent Mode).
- Trigger: `VoiceRouter.containsLocalBrowserSearchRequest` (search/google/look up/browse/browser/web/online) **or** `containsFreshResearchRequest` (latest/news/weather/price/…).
- Flow: extract a clean query (`localBrowserSearchQuery`) → open the **default browser** to a Google results URL (`NSWorkspace.shared.open`) → speak "opening that in your browser…" → wait ~5s → `captureAllScreensForVoiceResponseIfAvailable()` → `analyzeLocalVoiceResponse` (Gemma reads the screenshot) → stream to Kokoro. All on-device; only the browser itself uses the internet.
- Helpers: `localBrowserSearchQuery(from:)`, `googleSearchURL(for:)`, `localBrowserSearchReaderSystemPrompt` (read-only-what's-visible, 1–2 sentences, no invented numbers).
- Rationale: opening a browser + typing is pure local automation; Gemma is multimodal so it can read the results page locally — no API needed. (Autonomous click-through navigation is still unsupported; local pointing remains `.unsupported`.)

## 13. Testing status (Session 2)
### Verified (via local servers / logs)
- [x] Kokoro speaks Hindi: `hf_alpha` on Devanagari → audio; `af_heart` (English) on Devanagari → garbled. Confirms the voice must match the script.
- [x] Gemma replies in Hindi when asked (fast: ~27 tok/s, 100% GPU).
- [x] Hindi turn played end-to-end (`audioPlaybackState: finished`, 254 chars / 11s) — earlier "silence" was the response being **interrupted by re-pressing push-to-talk**, plus over-long replies.
- [x] All four changed files pass `swiftc -parse`.

### Remaining to test (after Xcode rebuild)
- [ ] **Hindi end-to-end with Devanagari fix** — ask for a Hindi poem; confirm the whole thing uses the Hindi voice (no robotic verse) and don't re-press the key mid-answer.
- [ ] **Local-only mode** — "latest news" no longer opens an Agents card; it stays local.
- [ ] **Local browser-search** — "search for X" / "find cheapest flight … in my browser" opens the default browser and Gemma reads the results aloud.
- [ ] **No launch summaries** — relaunch the app; prior tasks are not auto-summarized.
- [ ] (Tuning) The browser-search page-load wait is a fixed ~5s — may need lengthening for slow pages.

### Caveats
- Browser-search screenshots whatever is frontmost ~5s after opening; the browser must come forward (it does on open).
- Local-only mode default ON means voice never reaches cloud Agent Mode — web research only works with it turned off.

## 14. Local vision-driven browser navigation (experimental, fully on-device)
File: `cursor-buddy/CompanionManager.swift`
- New `handleLocalBrowserNavigationIfNeeded` + `runLocalBrowserNavigation` — a perception→action loop that actually drives the browser: open a site → loop **screenshot → local Gemma picks ONE next action → execute on the real screen → screenshot again**, up to 9 steps, until the goal is met. Routed **before** the simpler browser-search; gated to Local-only mode.
- **Trigger:** `VoiceRouter.containsBrowserNavigationRequest` (navigate / go to / open <site> / skyscanner / click / scroll / log in / cancel signup / fill / select / find the cheapest / book …). Plain "search X" / "latest news" still use the quick read path.
- **Start URL:** `navigationStartURL` maps named sites (skyscanner, google flights, makemytrip, youtube, amazon, flipkart, wikipedia, gmail, maps) to their root; otherwise opens a Google search of the cleaned query.
- **Action protocol:** Gemma is prompted (`browserNavigationSystemPrompt`) to emit exactly one minified JSON action per screenshot: `click{x,y,target}` / `type{text}` / `key{key,modifiers}` / `scroll{direction}` / `open_url{url}` / `say{text}` / `done{summary}`. Parsed by `parseNavigationAction` (first balanced `{...}`).
- **Execution:** reuses the native computer-use primitives — `nativeComputerUseController.click(at:)` / `.typeText` / `.pressKey` (scroll = Page Up/Down keys). Coordinates: `actionScreenPoint` maps screenshot **pixels → global AppKit points** using `CompanionScreenCapture.displayFrame` + `displayWidth/HeightInPoints` (top-left→bottom-left flip). Needs **Accessibility permission** (checked via `OpenClickyComputerUsePermissionProbe`); narrates progress and the final answer via Kokoro.
- **Honest limitation:** Gemma 4 12B is a general model, **not** a GUI-grounding model, so its click coordinates on dense pages are approximate — it can miss buttons / calendar dates. This is the same reason local pointing was left `.unsupported`. The deterministic deep-link path is more reliable for flights; this loop is the general "do any custom navigation" option the user asked for, with realistic accuracy caveats. Each step takes a few seconds (Gemma vision + settle delay), so a full task is ~30–80s.
- **To test (after rebuild):** "open skyscanner and find the cheapest one-way flight Bangalore to Pune on June 18" → it opens Skyscanner, and the loop attempts to dismiss the signup, set one-way/date, and read the cheapest. Expect to babysit/retry while grounding is rough.
