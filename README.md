<p align="center"><img src="docs/icon.png" alt="MacCaptions icon" width="128"></p>

# MacCaptions

Live **English captions with Chinese (Simplified) translation** for your Mac — for online meetings, videos and your own voice.
It lives in the menu bar, can also show a floating caption window, and can save the transcript and the audio of every session.

By default everything runs **on your Mac**: speech recognition and translation use Apple's on-device models, and the app sends nothing anywhere.
Optionally, a **local or cloud LLM** can improve or replace Apple's translation, using the surrounding sentences ([LLM translation](#llm-translation-optional)).

## Features

- **Two sources at the same time** – system audio (meeting, video, browser…) and the microphone, each recognised separately and labelled *Them* / *Me*. Each source has its own on/off switch, usable at any moment.
- **Live English captions → Simplified Chinese** using Apple's `SpeechAnalyzer` and Translation framework (free, on-device, no account).
- **Optional context-aware LLM translation** – a small model on your Mac (Ollama, LM Studio, llama.cpp) or a cloud API (OpenRouter, Tinker, OpenAI, DeepSeek, or any OpenAI-compatible server), with your own topic notes and glossary. Three modes: *Apple*, *Apple + LLM* and *LLM*.
- **Translation while someone is speaking** – with Apple, or with a local model; you choose how often it updates.
- **Menu bar display** with three modes – *English*, *中文* and *Mix* – in a fixed-width item, so the text never jumps around. A panel with the full bilingual transcript opens on click.
- **Floating caption window** (like Windows' *LiveCaptions-Translator*): drag it anywhere, drag its edges to resize, and style it – text colour and size per language, text opacity, background colour / transparency or no background at all, English-only / Chinese-only / both, optional click-through.
- **Record button** – saves each source as AAC audio (separate numbered segments, so you can switch recording on and off mid-session) plus the text.
- **Echo handling** – when the meeting plays through your speakers, the microphone also hears it. The app hides mic lines that just repeat the system audio, and can optionally use Apple's voice processing (slightly lowers other audio).
- **Light on resources** – the app itself used about 3 % of one CPU core while captioning, and about 5 % once its panel had been opened (M5 Pro, generated speech; Apple's speech and translation services and any model server not included).

## Requirements

- **macOS 26.4 or later**
- **Apple silicon** (M1 or newer)
- Chinese and English **translation language packs** for the *Apple* and *Apple + LLM* modes (macOS offers to download them; see below)

## Install

1. Download `MacCaptions-<version>-macos-arm64.dmg` from the [Releases](../../releases) page (a `.zip` of the same app is there too).
2. Open the DMG and drag **MacCaptions.app** onto the **Applications** shortcut.
3. The app is **ad-hoc signed, not notarized** (there is no paid Apple developer account behind it), so macOS will warn you the first time. Either:
   - right-click the app → **Open** → **Open**; if there is no Open button, go to *System Settings → Privacy & Security* and click **Open Anyway**, or
   - run once in Terminal: `xattr -dr com.apple.quarantine /Applications/MacCaptions.app`
4. Look for the **MacCaptions** text in your menu bar (the app has no Dock icon). Open it again from Finder to bring up the controls if the menu bar item is hidden.

### First run

- Click the menu bar item → **Start captions**.
- Allow **Microphone** access and, when asked, **System Audio Recording**.
- If asked for translation languages, install **English** and **Chinese (Simplified)**: *System Settings → General → Language & Region → Translation Languages*.
- The first start may download Apple's English speech model.

## Using it

| | |
|---|---|
| **Start / Stop captions** | Begins or ends a session. |
| **Microphone / System audio** | Switch each source on or off at any time. |
| **Record audio** | On by default at every launch; toggle during a session. Text is always saved. |
| **Translation / Set** | *Apple*, *Apple + LLM* or *LLM*; **Set** opens the model settings ([below](#llm-translation-optional)). |
| **Translate live text / Live update** | Translate sentences while they are being spoken, and how often: from **fastest** (each time new words arrive, about once a second) to every 6 s. Finished sentences are never delayed. |
| **Menu bar text** | English, 中文 or Mix; *Mix: English share* moves the divider; *Menu bar width* up to 1000 pt. |
| **Floating window / Window style…** | Show the caption window and edit its look (also in the window's right-click menu). |
| **Hide mic echo** | Hides mic lines that repeat the system audio (headphones avoid the problem entirely). |
| **Transcript (in the panel)** | Follows new lines while you are at the end. Scroll up to read earlier lines and it stays where you are; scroll back to the end to follow again. |

## LLM translation (optional)

Off by default. In the menu bar panel choose a **Translation** mode, and set up the model with the **Set** button next to it.

| Mode | Where the Chinese comes from | If the model fails or is too slow |
|---|---|---|
| **Apple** (default) | Apple's on-device translation | – |
| **Apple + LLM** | Apple's appears first; the model's replaces it for finished sentences | Apple's stays |
| **LLM** | only your model (a local one also while the sentence is being spoken) | the sentence shows “—” and is saved without a translation |

**How it works.** When a sentence is finished it is sent to your model together with a few earlier sentences (translations of finished sentences by the model are marked ✦ in the panel). Because there is nothing to fall back on, **LLM** mode lets more sentences wait for a slow model, and for longer; it does not need Apple's translation language packs.

**Translating while someone speaks.** In **Apple + LLM** mode, Apple does this. In **LLM** mode with a model on your Mac or local network and *Translate live text* on, your model translates the words spoken so far, about once a second, one request at a time. The Chinese grows and may be reworded as the sentence goes on; early versions can be wrong. When the sentence ends, a live translation is reused if the text did not change (apart from a closing full stop); otherwise the sentence is translated again. Expect about three times as many requests, so a busier model. Cloud services are only sent finished sentences.

On one M5 Pro with `qwen3.5:9b` in Ollama (computer-generated speech, short sentences), live translation put the first Chinese on screen about 1.3–1.5 s after a sentence began (about 4 s without it), and the whole sentence's translation about 0.5–0.8 s after it ended (1.2–1.5 s without).

In continuous speech the next sentence usually starts before the model has answered. In **Apple + LLM** mode the menu bar therefore mostly shows Apple's version (the panel, the floating window and the saved transcript get the model's). In **LLM** mode the menu bar shows the translation of a recent sentence until the current one has its own, so the Chinese can briefly (or, without live translation, mostly) be a sentence behind the English.

| Provider | Server address (default) | API key |
|---|---|---|
| Ollama | `http://127.0.0.1:11434/v1` | no |
| LM Studio | `http://127.0.0.1:1234/v1` | no |
| llama.cpp `llama-server` | `http://127.0.0.1:9931/v1` (older versions use 8080; use the port it prints) | no |
| OpenRouter | `https://openrouter.ai/api/v1` | yes |
| Tinker (beta API) | `https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1` | yes |
| OpenAI / DeepSeek | preset | yes |
| Custom | any OpenAI-compatible `/v1` address | if it needs one |

**A local model with Ollama:** install [Ollama](https://ollama.com), run `ollama pull qwen3.5:4b`, press **Set**, choose *Ollama* and press **Test translation**. If your Mac has plenty of memory, `qwen3.5:9b` translates noticeably better. Models whose name contains `Hy-MT` (Tencent's translation models) automatically get the prompt format they were trained on.

**What to expect (tests on an M5 Pro with 48 GB, made-up sentences):** each sentence took about 0.2–0.3 s with models of 1.8–9B. The better ones handled idioms, technical terms and numbers far better than Apple, but still make mistakes, sometimes fluent ones that say the opposite ("drop off" translated as "arrive"), and they do not repair speech-recognition errors. A glossary entry fixes a phrase that keeps coming out wrong. The `qwen3.5:9b` tested through Ollama was the 8-bit version (7.6 GB download).

**Memory with Ollama grows during use:** `qwen3.5:9b` started at about 8 GB and reached about 20 GB over 400 requests, where it levelled off; `qwen3.5:4b` went from about 4 GB to 12 GB in a shorter run. Translating while someone speaks sends more requests. By default Ollama unloads an idle model after a few minutes.

> The **Ollama**, **llama.cpp**, **OpenRouter** and **Tinker** presets have been tested with real models (November 2026). LM Studio, OpenAI, DeepSeek and custom servers follow each service's documentation and are tested against a simulated server, but have **not** yet completed a real translation. Use **Test translation** to check your setup.

**Cloud models tried** (68 test sentences each, 3 sentences of context, one run; prices as billed or listed in November 2026 and likely to change):

| Service · model | Typical time per sentence | Cost per 1,000 sentences |
|---|---|---|
| OpenRouter · `qwen/qwen3.7-flash` (default) | 0.6 s | under $0.01 |
| OpenRouter · `google/gemma-4-26b-a4b-it`, `deepseek/deepseek-v4-flash-0731`, `tencent/hy4-flash` | 0.6–0.7 s | about $0.02 |
| OpenRouter · `openai/gpt-6-luna` | 1.0 s | about $0.03 |
| OpenRouter · `google/gemini-3.1-flash-lite` | 0.8 s | about $0.06 |
| Tinker · `Qwen/Qwen3.5-9B` | 1.2 s | about $0.07 (estimated) |

A topic note or glossary adds a little to the cost. OpenRouter passes your text to a company that hosts the model, and some models are served by several different hosts; `qwen/qwen3.7-flash` was always served by Alibaba. On Tinker, choose a model whose thinking can be switched off: its Inkling models always reason first, which is too slow for captions.

**Settings that help quality:** a line or two *about this conversation*, and a *glossary* (`agent = 智能体`, one per line; a term is sent only when it occurs). The number of earlier sentences sent as context is adjustable (default 3).

**Privacy.** With a cloud provider, the **text** of each finished sentence (system audio *and* microphone), the context sentences, your topic notes and matching glossary terms are sent to that provider; audio is never sent. The panel shows where text is going. Plain `http` is accepted only for this Mac or your local network, and redirects are not followed. API keys are stored in the macOS Keychain, filed per server, and never written to settings or session files. Because the app is ad-hoc signed, macOS may ask for your login password once after an update before the new version can use a saved key; if it will not let the new version remove an old key, delete it in *Keychain Access* (search for "MacCaptions API key").

**Saved sessions** go to `~/Documents/MacCaptions/<date_time>/`:

```
audio/mic_001.m4a, system_001.m4a, …   one file per source per recording stretch (16 kHz mono AAC)
transcript.md                           readable English + Chinese transcript
transcript.jsonl                        one JSON object per sentence (timing, speaker, English, Chinese, engine, flags)
session.json                            session info and where each audio segment starts and ends
```

In `transcript.jsonl`, `engine` says what produced `zh` (`none` if there is no translation); in **Apple + LLM** mode, `zhApple` keeps Apple's version of a sentence the LLM translated, so you can compare them.

Sessions saved by versions 0.1.0 / 0.1.1 in `~/Documents/LiveCaptions` are moved to `~/Documents/MacCaptions` automatically the first time you start captions (only if that folder holds nothing but MacCaptions sessions and `MacCaptions` does not exist yet).

> Recording a meeting may require the consent of the other participants. Check the rules that apply to you.

## Build from source

Requires Xcode 26.4+ (Swift 6) on Apple silicon.

```bash
git clone https://github.com/chengxuphd/maccaptions.git
cd maccaptions
./make_app.sh            # builds MacCaptions.app (ad-hoc signed) in this folder
open MacCaptions.app

./tools/test.sh          # self-tests
VERSION=1.2.3 ./make_release.sh   # builds the .dmg and .zip (with checksums) in dist/
```

How the code is organised, the developer tools and the release steps are in **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**.

## Known limitations

- On a Mac with a notch or a crowded menu bar, macOS may tuck the captions behind its overflow arrow when the app in front needs the room. A narrower **Menu bar width** makes this less likely; the floating caption window is not affected.
- English speech → Simplified Chinese only (speech recognition is `en-US`).
- Apple's translation is fluent but weak on idioms and technical terms ("circle back", "agents"). An LLM can help; how much depends on the model.
- With a cloud service the LLM translates finished sentences only. A model that cannot keep up leaves some sentences with Apple's translation, or with none in **LLM** mode.
- Saved audio is 16 kHz mono (what the recogniser hears): fine for review, not for music.
- Only tested on one Mac (Apple silicon, macOS 27); other setups, Bluetooth headsets and device changes mid-session have had little real-world testing.
- Not notarized (see *Install*).

## License

Apache-2.0 — see [LICENSE](LICENSE).
