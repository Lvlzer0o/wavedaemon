# WaveDaemon

![Version](https://img.shields.io/badge/version-v0.1.0-blue)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

System-wide audio DSP daemon for macOS.

WaveDaemon is a production-focused CoreAudio stack built around CamillaDSP, BlackHole, and a live WebSocket control UI.

## Architecture

![WaveDaemon Architecture](docs/architecture.svg)

Signal path:

```text
macOS
↓
<multi-output-device>
↓
BlackHole 2ch
↓
WaveDaemon (CamillaDSP engine)
↓
<aggregate-output-device>
↓
Built-in speakers / output device
```

Control plane:

```text
Browser UI
↓
WebSocket (ws://127.0.0.1:1234)
↓
CamillaDSP
↓
Live DSP updates (volume, mute, profiles, 10-band EQ)
```

## Repository Layout

```text
wavedaemon/
├── dsp/
│   ├── config.yml
│   └── profiles/
├── scripts/
│   ├── start-audio-dsp.sh
│   ├── stop-audio-dsp.sh
│   ├── start-audio-dsp-failsafe.sh
│   ├── stop-audio-dsp-failsafe.sh
│   ├── install-deps.sh
│   ├── start-audio-control-ui.sh
│   ├── stop-audio-control-ui.sh
│   └── audio-stream-keepalive.sh
├── ui/
│   └── control.html
├── tools/
│   └── latency-test.sh
├── docs/
│   ├── architecture.svg
│   └── routing.md
├── README.md
├── LICENSE
└── .gitignore
```

## Prerequisites

- macOS
- Homebrew
- `blackhole-2ch`
- `camilladsp` binary available via `PATH` or `CAMILLADSP_BIN`
- `switchaudio-osx`
- `websocat`
- `jq`

## Install

```bash
./scripts/install-deps.sh
```

Manual fallback:

```bash
brew install camilladsp switchaudio-osx websocat jq
brew install --cask blackhole-2ch
```

## Quick Start

1. Configure routing in Audio MIDI Setup (see [`docs/routing.md`](docs/routing.md)).
2. Start DSP from repo root:

```bash
CAMILLADSP_AUTO_KEEPALIVE=1 ./scripts/start-audio-dsp-failsafe.sh
```

3. Start UI:

```bash
./scripts/start-audio-control-ui.sh
```

4. Open:

`http://127.0.0.1:9137/ui/control.html?ws=ws://127.0.0.1:1234`

Suggested CoreAudio device names used in examples:

- `<multi-output-device>`: `System DSP Output`
- `<aggregate-output-device>`: `DSP Aggregate`

Optional overrides:

- `CAMILLADSP_MULTI_OUTPUT_NAME`
- `CAMILLADSP_MULTI_OUTPUT_FALLBACK`
- `CAMILLADSP_STOP_OUTPUT_DEVICE`

## Validate

```bash
lsof -nP -iTCP:1234 -sTCP:LISTEN
printf '"GetVersion"\n' | websocat -n1 ws://127.0.0.1:1234
printf '"GetState"\n' | websocat -n1 ws://127.0.0.1:1234
```

## Latency

Use the estimator:

```bash
./tools/latency-test.sh
./tools/latency-test.sh ./dsp/config.yml
```

Recommended low-latency tuning target:

- `chunksize: 256`
- `target_level: 128`

## Safety Notes

- Keep main gain at `0 dB` unless you intentionally need boost.
- Prefer limiter last in the chain.
- Use fail-safe routing so audio continues even if DSP exits.
