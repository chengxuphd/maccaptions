# Developing MacCaptions

A Swift package with one target and no dependencies. It needs Apple silicon, macOS 26.4+ and Xcode 26.4+.

## How a sentence flows

```
system audio ─┐
              ├─► speech recognition ─► TranscriptStore ─► menu bar · panel · floating window
microphone  ──┘   (one per source)        │      ▲
                                          │      └── Apple translation (in-progress and finished sentences; not in "LLM" mode)
                                          │      └── LLM (finished sentences, improving on Apple or in "LLM" mode replacing it;
                                          │               in "LLM" mode with a local model, unfinished ones too)
                                          ▼
                                     CommitQueue ─► SessionRecorder ─► ~/Documents/MacCaptions/
```

`App/CaptionEngine.swift` connects all of these. Start reading there.

## Where the code is (`Sources/MacCaptions/`)

| Folder | What it does | Main files |
|---|---|---|
| `App/` | Startup, start/stop, settings | `CaptionEngine`, `Settings`, `main` |
| `Audio/` | Capturing sound and recognising speech | `SystemAudioTap`, `MicCapture`, `CaptionPipeline` |
| `Transcript/` | The live transcript and saving it | `TranscriptStore`, `EchoFilter`, `CommitQueue`, `SessionRecorder` |
| `Translation/` | Apple's on-device translation; the pace of live updates | `TranslationCoordinator`, `LivePace` |
| `Translation/LLM/` | The optional LLM, see below | |
| `UI/` | Menu bar item, panel, caption window, settings windows | `MenuBarController`, `PanelView`, `TranscriptView`, `FloatingCaptionView`, `LLMSettingsView` |
| `DevTools/` | Tests and tools; **not** in the shipped app | |

### The LLM part (`Translation/LLM/`)

In the order a request passes through:

| File | Role |
|---|---|
| `LLMTranslator` | Queue: how many at once, deadlines, skipping when behind, pausing after failures; live translation of unfinished sentences and reusing it |
| `TranslationEngine` | One translation: send, check the reply, retry once without context |
| `LLMPrompt` | The prompt, context sentences and glossary |
| `LLMClient` | HTTP: time limit, no redirects, adapting to refused fields |
| `LLMWire` | Request and reply format, error messages |
| `LLMOutput` | Cleaning a reply and deciding whether to trust it |
| `LLMConfig` | Providers and their differences (**add a provider here**) |
| `LLMEndpoint` | Parsing server addresses; what counts as local |
| `LLMService`, `KeychainStore` | Shared client and API keys |

## Rules to keep

- **Three modes** (`TranslationMode` in `App/Settings.swift`): Apple, Apple + LLM, LLM. In "Apple" mode no LLM request is made. In "Apple + LLM", if the LLM fails in any way, Apple's text stays. In "LLM", no Apple text is ever shown; a failed sentence is marked and saved untranslated.
- **No finished sentence is lost**, and the transcript is saved in the order it was spoken.
- **Nothing may stall captions, Stop or Quit.** Every LLM job answers exactly once, within a time limit.
- **An API key goes only to the server it was saved for** (scheme, host and port), and never to a file or log.
- **Live results are reused only for the same text** (capitals and a closing full stop aside). The recognizer sets punctuation when it finishes, and it can change the meaning.
- **Cost:** never turn a refused "thinking off" setting straight into thinking on if another form exists, and don't repeat requests that cannot succeed.

## Build

```bash
./make_app.sh                      # MacCaptions.app, ad-hoc signed, in this folder
VERSION=0.1.2 ./make_release.sh    # also the .dmg and .zip with checksums, in dist/
./tools/make_icon.sh               # only after changing the icon
```

`make_app.sh` deletes and recreates `MacCaptions.app`, so **quit the app first**. Each build has a new ad-hoc signature, so macOS may ask for audio permissions again, and for your password before the app can use a saved API key.

## Test

```bash
./tools/test.sh                    # self-tests (MACCAPTIONS_SELFTEST=1); no audio devices, network, keys or model servers
```

The self-tests need a logged-in desktop session: the transcript's scrolling is tested on the real panel, built off screen (`MACCAPTIONS_SCROLL_TRACE=1` prints the positions). Real trackpad and mouse-wheel gestures can't be simulated; try those by hand.

Developer code is compiled only with `-Xswiftc -DDEVTOOLS`. It is switched on with environment variables:

```bash
swift build -Xswiftc -DDEVTOOLS
BIN="$(swift build -Xswiftc -DDEVTOOLS --show-bin-path)/MacCaptions"
```

> Always set `MACCAPTIONS_DEFAULTS_SUITE=<any name>`. Without it, a developer build uses the real app's settings.

**The whole app, silently.** An audio file is fed into speech recognition, so no sound is played and no microphone is opened:

```bash
say -o /tmp/speech.aiff "Can you hear me? Let's circle back on this after the review."
MACCAPTIONS_DEFAULTS_SUITE=mc-test MACCAPTIONS_ROOT=/tmp/mc-sessions \
  MACCAPTIONS_FEED=/tmp/speech.aiff MACCAPTIONS_AUTOSTOP=20 "$BIN"
```

| Variable (prefix `MACCAPTIONS_`) | Effect |
|---|---|
| `ROOT=<dir>` | Save sessions there instead of `~/Documents/MacCaptions` |
| `FEED=<audio file>` | Use this file as system audio (`FEED_INTERLEAVED=1`: in the system tap's stereo layout) |
| `AUTOSTART=1`, `AUTOSTOP=<s>`, `STOP_AT=<s>` | Start at once; quit after; press Stop at |
| `TOGGLE_REC`, `TOGGLE_MIC`, `TOGGLE_SYS` = `"10,20"` | Flip that switch at those seconds |
| `SWITCH_MODEL_AT=<s>` | Change the LLM model during a session |
| `MODE_AT="12:llm,20:apple"` | Switch the translation mode (`apple`, `appleLLM`, `llm`) at those seconds |
| `LLM_STUB=<delay>[,<n>]` | A pretend LLM answers (every n-th request fails); also `LLM_STUB_WARMUP`, `LLM_STUB_LOG` |
| `LLM_TRACE=1` | Print how long each LLM reply took |
| `TIMELINE=1` | Print when audio was fed, text appeared, sentences finished and LLM replies arrived |
| `STATS_FILE=<path>` | Write CPU and memory figures on quit |

(A full-app test uses the mode saved in that settings suite: `defaults write mc-test translationMode appleLLM`, or `llm`.)

**Screens and layout.** `UI_SHOT=<dir>` (panel and LLM settings), `RENDER=<dir>` (caption window styles), `LAYOUT_TEST=<dir>` (menu bar divider), `MEASURE=1` (space reserved for translations), `DEMO=1` / `DEMO_STYLE=1` (sample captions on screen), `SHOWWINDOW=1`.

**Real models.** These compare a model with Apple's translation and time every request. Cloud services **charge** for them.

```bash
MACCAPTIONS_DEFAULTS_SUITE=mc-test MACCAPTIONS_LLM_BENCH=1 \
  MACCAPTIONS_LLM_PROVIDER=ollama MACCAPTIONS_LLM_MODEL=qwen3.5:4b \
  MACCAPTIONS_LLM_SENTENCES=tools/llm-sentences/set-1.txt "$BIN"
```

| Variable (prefix `MACCAPTIONS_LLM_`) | Effect |
|---|---|
| `PING=1` | One request only: the cheapest check of a key, address and model |
| `BENCH=1` | Translate all sentences (14 built in, or a file) |
| `PROVIDER`, `URL`, `MODEL` | What to test (`ollama`, `llamacpp`, `openrouter`, `tinker`, …) |
| `KEY_FILE=<path>` | Read the API key from a file; it is sent only to that provider's own address |
| `CONTEXT=<n>`, `GLOSSARY="a = 甲;b = 乙"`, `EXTRA=<json>` | Context size, glossary, extra request fields |
| `SENTENCES=<file>`, `JSON=<file>` | Input (a blank line starts a new conversation); save results |
| `USAGE=1`, `RAW=1` | Print token use and cost; print raw replies |
| `PROBE=1` | Send one keyless request to each cloud preset |

`tools/llm-sentences/` holds the two sets of made-up meeting sentences used to compare models. Set 2 was not used to tune the prompt; keep it that way.

## Release

1. Update the version and write `docs/releases/v<version>.md`.
2. `./tools/test.sh`, then try the app by hand.
3. Commit and push.
4. `VERSION=<version> ./make_release.sh`
5. `gh release create v<version> dist/MacCaptions-<version>-macos-arm64.*` with the release notes, adding the SHA-256 checksums from `dist/*.sha256`.
