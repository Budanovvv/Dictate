# Dictate

**Hold a key. Speak. Release — your words appear right where your cursor is, in any app.**

One key. Zero subscriptions. Zero dollars.

### [⬇︎ Download the latest release](https://github.com/Budanovvv/Dictate/releases/latest)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green) ![Apple Silicon](https://img.shields.io/badge/chip-Apple%20Silicon-lightgrey) [![Latest release](https://img.shields.io/github/v/release/Budanovvv/Dictate?label=release)](https://github.com/Budanovvv/Dictate/releases/latest)

Dictate is push-to-talk dictation for macOS. Everything runs on your Mac: Whisper **large-v3** — the best open speech model there is — on your Neural Engine, via Core ML. No cloud, no account, no API keys. Don't take our word for it: **turn Wi-Fi off — Dictate keeps working.**

## Features

- **Works in any app** — Slack, Mail, your editor, your terminal: text is typed wherever your cursor is.
- **Push-to-talk** — hold a key you never use (right ⌥ by default), speak, release. Or tap-to-toggle if you prefer.
- **Full Whisper large-v3, on-device** — 112 languages, great with accents. Not a cut-down "free tier" model — the real thing.
- **Speak your language, send English** — hold a second key and your speech is typed as English. Translated on your Mac, like everything else.
- **Private by architecture** — the microphone listens only during a dictation you started; recognition never touches the network. The one-time model download (~950 MB) is the only time Dictate needs the internet.
- **Speaks your language** — the interface is available in English, Español, Português, Français, Deutsch, 中文, 日本語, 한국어, Tiếng Việt, Filipino, Українська, and Русский.
- **Honest utility** — no settings maze, no account, no subscription. Auto-updates via Sparkle, cryptographically signed.

## Why it's free

Local dictation on a Mac is a solved problem now: Whisper runs on the Neural Engine, the model is free, and Apple hands you Core ML for nothing. Building the one I wanted took days, not a company — so charging $5–15/month for something your own Mac already does felt wrong. The technology got cheap; the price tags didn't. Dictate just removes the price tag.

It's free and open source under GPL-3.0: a local app has no servers to pay for, and I'd rather you read the code than take my word on privacy. No accounts, no "Pro" tier, no cloud path — ever.

There are other good free, open dictation apps too — [Handy](https://github.com/cjpais/Handy), [VoiceInk](https://github.com/Beingpax/VoiceInk), [FluidVoice](https://github.com/altic-dev/FluidVoice) — and I'm glad they exist; we're all making the same point. Dictate's own angle is being fully native Swift *and* translating your speech to English on a second key.

## Install

1. Download the latest `Dictate-x.y.dmg` from [Releases](https://github.com/Budanovvv/Dictate/releases).
2. Open it and drag **Dictate** into **Applications**.
3. Launch. Dictate walks you through the rest: a one-time model download, picking your key, and two macOS permissions.

**Requirements:** macOS 14+, **Apple Silicon** (Intel Macs run it too — it's a universal binary — but recognition is much slower without a Neural Engine), ~1 GB of free disk space for the speech model.

### About the two permissions

- **Microphone** — records your voice only while a dictation you started is running. Never in the background.
- **Accessibility** — used for exactly two things: hearing your dictation key and typing the recognized text for you. Nothing else. Dictate doesn't read your screen and doesn't log your typing — and since the code is open, you don't have to take that on faith.

*(Why not the Mac App Store? Sandboxing forbids the system-wide key listening and text insertion Dictate is built on — the same reason apps like Raycast and Rectangle ship directly.)*

## Build from source

```bash
brew install xcodegen
git clone https://github.com/Budanovvv/Dictate.git && cd Dictate
xcodegen generate
./build.sh            # Release build (pick your signing Team in Xcode once)
./test.sh             # unit tests + bundle checks
```

Stack: Swift / SwiftUI / AppKit, [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML), [Sparkle](https://sparkle-project.org) for updates. The Xcode project is generated from `project.yml`.

## License

[GPL-3.0](LICENSE) — free forever; forks stay open.

Made by [Valentyn Budanov](https://github.com/Budanovvv).
