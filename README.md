<p align="center">
  <img src="assets/logo.svg" width="96" alt="Dictate — three voice bars on a typed line ending in a text cursor">
</p>

<h1 align="center">Dictate</h1>

<p align="center"><b>Hold a key, speak, let go. Everything happens on this Mac.</b></p>

<p align="center">Dictation and translation that work offline. Meetings that structure themselves.<br>An agent that knows them all. Zero dollars.</p>

### [⬇︎ Download the latest release](https://github.com/Budanovvv/Dictate/releases/latest)

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue) ![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green) ![Apple Silicon](https://img.shields.io/badge/chip-Apple%20Silicon-lightgrey) [![Latest release](https://img.shields.io/github/v/release/Budanovvv/Dictate?label=release)](https://github.com/Budanovvv/Dictate/releases/latest)

Dictate does four things, and does them all on your Mac. No cloud, no account, no subscription. Don't take our word for it: **turn Wi-Fi off — Dictate keeps working.**

## The four things

**1 · Dictation that works offline.** Hold a key you never use (right ⌥ by default), speak, let go — your words are typed where your cursor is, in any app: Slack, Mail, your editor, your terminal. Whisper **large-v3-turbo** runs on your Neural Engine via Core ML: 112 languages, great with accents, fast enough to show live text while you're still speaking.

**2 · Translation that works offline.** Hold the second key and speak your own language — it comes out in English, or another language you pick. Translated on this Mac, like everything else.

**3 · Meetings, recorded and structured.** Record any call — Zoom, Google Meet in a browser, anything — and get more than a transcript. Who spoke, told apart by voice. A title and a one-line summary, written by a local model. A clickable outline of the moments that mattered. Tags, stars, the platform the call ran on — and search across every spoken word, title, summary and outline line. Every file is plain Markdown in `~/Documents/Dictate Meetings`, and none of it leaves this Mac.

**4 · An agent that knows your meetings.** *(optional)* Connect Claude or ChatGPT with your own API key and ask questions across everything you've recorded — the agent searches and reads your archive, and every answer quotes the passages it came from, one click from the moment it was said. Off by default: this is the only feature that ever talks to a server, it uses your key, and the recordings themselves never leave your Mac.

## The details

- **Private by architecture** — the microphone listens only during a dictation or a recording you started; recognition never touches the network. The one-time model download (~630 MB) is the only time Dictate needs the internet.
- **Speaks your language** — the interface is available in English, Español, Português, Français, Deutsch, 中文, 日本語, 한국어, Tiếng Việt, Filipino, Українська, and Русский.
- **Honest utility** — no settings maze, no account, no subscription. Auto-updates via Sparkle, cryptographically signed.

## Why it's free

Local dictation on a Mac is a solved problem now: Whisper runs on the Neural Engine, the model is free, and Apple hands you Core ML for nothing. Building the one I wanted took days, not a company — so charging $5–15/month for something your own Mac already does felt wrong. The technology got cheap; the price tags didn't. Dictate just removes the price tag.

It's free and open source under GPL-3.0: a local app has no servers to pay for, and I'd rather you read the code than take my word on privacy. No accounts, no "Pro" tier. Dictation and transcription have no cloud path — ever; the one optional feature that asks a model about your archive uses your own API key and is off until you turn it on.

There are other good free, open dictation apps too — [Handy](https://github.com/cjpais/Handy), [VoiceInk](https://github.com/Beingpax/VoiceInk), [FluidVoice](https://github.com/altic-dev/FluidVoice) — and I'm glad they exist; we're all making the same point. Dictate's own angle is being fully native Swift, translating your speech on a second key, and turning your calls into a structured, searchable archive an agent can actually answer from.

## Install

1. Download the latest `Dictate-x.y.dmg` from [Releases](https://github.com/Budanovvv/Dictate/releases).
2. Open it and drag **Dictate** into **Applications**.
3. Launch. Dictate walks you through the rest: a one-time model download, picking your key, and two macOS permissions.

**Requirements:** macOS 15+, **Apple Silicon** (Intel Macs run it too — it's a universal binary — but recognition is much slower without a Neural Engine), ~1 GB of free disk space for the speech model.

### About the two permissions

- **Microphone** — records your voice only while a dictation you started is running. Never in the background.
- **Accessibility** — used for exactly two things: hearing your dictation key and typing the recognized text for you. Nothing else. Dictate doesn't read your screen and doesn't log your typing — and since the code is open, you don't have to take that on faith.

*(Why not the Mac App Store? Sandboxing forbids the system-wide key listening and text insertion Dictate is built on — the same reason apps like Raycast and Rectangle ship directly.)*

## Build from source

```bash
brew install xcodegen cmake
git clone https://github.com/Budanovvv/Dictate.git && cd Dictate
./tools/build-llama-server.sh   # once: builds the text helper (~5 min)
xcodegen generate
./build.sh            # Release build (pick your signing Team in Xcode once)
./test.sh             # unit tests + bundle checks
```

The text helper is a universal [llama.cpp](https://github.com/ggml-org/llama.cpp) server binary, built from a pinned commit rather than committed here — 34 MB per copy would live in git history forever. `build.sh` refuses to build without it and prints the command above.

Stack: Swift / SwiftUI / AppKit, [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML) for speech, [FluidAudio](https://github.com/FluidInference/FluidAudio) for voice activity and speaker separation, llama.cpp for on-device text generation, [Sparkle](https://sparkle-project.org) for updates. The Xcode project is generated from `project.yml`.

## License

[GPL-3.0](LICENSE) — free forever; forks stay open.

Made by [Valentyn Budanov](https://github.com/Budanovvv).
