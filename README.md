# WaveDaemon

[![Release](https://img.shields.io/github/v/release/Lvlzer0o/wavedaemon)](https://github.com/Lvlzer0o/wavedaemon/releases)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

WaveDaemon is a **system-wide audio DSP pipeline for macOS** built on CamillaDSP and BlackHole, with a local browser UI for live control.

## What It Does

- Processes system audio in real time.
- Exposes live controls for volume, mute, profile switching, and EQ.
- Supports fail-safe routing patterns to reduce audio interruptions.

## Signal Flow

```text
System Audio -> Multi-Output Device -> BlackHole 2ch -> CamillaDSP -> Aggregate Output -> Speakers/Headphones
```

## Requirements

- macOS
- Homebrew
- `camilladsp`
- `blackhole-2ch`
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

1. Configure audio routing in [docs/routing.md](docs/routing.md).
2. Start DSP:

```bash
CAMILLADSP_AUTO_KEEPALIVE=1 ./scripts/start-audio-dsp-failsafe.sh
```

3. Start UI:

```bash
./scripts/start-audio-control-ui.sh
```

4. Open:

```text
http://127.0.0.1:9137/ui/control.html?ws=ws://127.0.0.1:1234
```

## Common Commands

Run diagnostics:

```bash
./scripts/wavedaemon-doctor.sh
```

Validate websocket:

```bash
lsof -nP -iTCP:1234 -sTCP:LISTEN
printf '"GetVersion"\n' | websocat -n1 ws://127.0.0.1:1234
printf '"GetState"\n' | websocat -n1 ws://127.0.0.1:1234
```

Estimate latency:

```bash
./tools/latency-test.sh
./tools/latency-test.sh ./dsp/config.yml
```

## Environment Overrides

- `CAMILLADSP_BIN`
- `CAMILLADSP_BIND_ADDRESS`
- `CAMILLADSP_BIND_PORT`
- `CAMILLADSP_CLIENT_WS_URL`
- `CAMILLADSP_MULTI_OUTPUT_NAME`
- `CAMILLADSP_MULTI_OUTPUT_FALLBACK`
- `CAMILLADSP_SAFE_OUTPUT_FALLBACK`
- `CAMILLADSP_ALLOW_RAW_OUTPUT_FALLBACK`
- `CAMILLADSP_RAW_OUTPUT_FALLBACK`
- `CAMILLADSP_STOP_OUTPUT_DEVICE`

## Project Structure

```text
wavedaemon/
├── dsp/
├── docs/
├── scripts/
├── tools/
├── ui/
├── README.md
└── LICENSE
```

## Safety Notes

- Keep output gain conservative unless intentional boost is required.
- Keep limiter last in the processing chain.
- Prefer fail-safe routing so audio continues if DSP exits.
