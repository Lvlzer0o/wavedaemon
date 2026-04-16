# WaveDaemon

[![Version](https://img.shields.io/badge/version-v0.1.0-blue)](https://github.com/Lvlzer0o/wavedaemon/releases)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/Lvlzer0o/wavedaemon)](https://github.com/Lvlzer0o/wavedaemon/releases)

**WaveDaemon** is a macOS system-audio DSP stack built around **CamillaDSP**, **BlackHole**, and a lightweight browser control UI.

It is designed to keep your system audio flowing safely while giving you real-time control of:

- master volume
- mute
- DSP profiles
- 10-band EQ and processing chain updates

---

## Why WaveDaemon

- **System-wide processing** without changing individual apps.
- **Live control** via WebSocket-powered browser UI.
- **Fail-safe routing** options to avoid audio dropouts if DSP exits.
- **Script-first operations** for repeatable setup, start, stop, and diagnostics.

---

## Architecture

> GitHub can render complex SVG/GIF content inconsistently depending on browser, zoom, and theme. The architecture and demo assets are still included in `docs/` and linked below.

- [Architecture diagram (`docs/architecture.svg`)](docs/architecture.svg)
- [Demo animation (`docs/wavedaemon-demo.gif`)](docs/wavedaemon-demo.gif)
- [Routing guide (`docs/routing.md`)](docs/routing.md)

### Signal Path

```text
macOS Apps / System Audio
  -> <multi-output-device>
  -> BlackHole 2ch
  -> WaveDaemon (CamillaDSP)
  -> <aggregate-output-device>
  -> Built-in speakers / selected output
```

### Control Path

```text
Browser UI
  -> WebSocket (ws://127.0.0.1:1234)
  -> CamillaDSP
  -> Live DSP updates (volume, mute, profiles, EQ)
```

---

## Repository Layout

```text
wavedaemon/
├── dsp/
│   ├── config.yml
│   └── profiles/
├── scripts/
│   ├── install-deps.sh
│   ├── start-audio-dsp.sh
│   ├── stop-audio-dsp.sh
│   ├── start-audio-dsp-failsafe.sh
│   ├── stop-audio-dsp-failsafe.sh
│   ├── start-audio-control-ui.sh
│   ├── stop-audio-control-ui.sh
│   ├── audio-stream-keepalive.sh
│   └── wavedaemon-doctor.sh
├── tools/
│   └── latency-test.sh
├── ui/
│   └── control.html
├── docs/
│   ├── architecture.svg
│   ├── wavedaemon-demo.gif
│   └── routing.md
├── README.md
└── LICENSE
```

---

## Requirements

- macOS
- Homebrew
- `blackhole-2ch`
- `camilladsp` (in `PATH` or set via `CAMILLADSP_BIN`)
- `switchaudio-osx`
- `websocat`
- `jq`

---

## Install

```bash
./scripts/install-deps.sh
```

Manual fallback:

```bash
brew install camilladsp switchaudio-osx websocat jq
brew install --cask blackhole-2ch
```

---

## Quick Start

1. Configure routing in Audio MIDI Setup using the [routing guide](docs/routing.md).
2. Start WaveDaemon DSP (from repository root):

```bash
CAMILLADSP_AUTO_KEEPALIVE=1 ./scripts/start-audio-dsp-failsafe.sh
```

3. Start the control UI:

```bash
./scripts/start-audio-control-ui.sh
```

4. Open the UI:

```text
http://127.0.0.1:9137/ui/control.html?ws=ws://127.0.0.1:1234
```

Suggested CoreAudio device names used in examples:

- `<multi-output-device>`: `System DSP Output`
- `<aggregate-output-device>`: `DSP Aggregate`

---

## Configuration Notes

Optional environment overrides:

- `CAMILLADSP_MULTI_OUTPUT_NAME`
- `CAMILLADSP_MULTI_OUTPUT_FALLBACK`
- `CAMILLADSP_SAFE_OUTPUT_FALLBACK` (default: `Built-in Output`)
- `CAMILLADSP_ALLOW_RAW_OUTPUT_FALLBACK` (`1` enables fallback)
- `CAMILLADSP_RAW_OUTPUT_FALLBACK` (default: `BlackHole 2ch`)
- `CAMILLADSP_STOP_OUTPUT_DEVICE`

WebSocket bind/connect split (migration-safe defaults):

- **Daemon bind**: `CAMILLADSP_BIND_ADDRESS`, `CAMILLADSP_BIND_PORT`
- **Client connect URL**: `CAMILLADSP_CLIENT_WS_URL`
- Backward compatibility: if bind vars are unset, daemon bind falls back to `CAMILLADSP_WS_ADDRESS` / `CAMILLADSP_WS_PORT`.

---

## Health Checks

Run diagnostics before or after setup:

```bash
./scripts/wavedaemon-doctor.sh
```

Typical checks include dependencies, device presence, sample rates, WebSocket topology, ports, config validation, and runtime status.

---

## Validation

If the daemon binds to `0.0.0.0` or `*`, use `127.0.0.1` for local checks. If it binds to `::`, use `::1`.

```bash
lsof -nP -iTCP:1234 -sTCP:LISTEN
printf '"GetVersion"\n' | websocat -n1 ws://127.0.0.1:1234
printf '"GetState"\n' | websocat -n1 ws://127.0.0.1:1234
```

---

## Latency

Use the estimator:

```bash
./tools/latency-test.sh
./tools/latency-test.sh ./dsp/config.yml
```

Recommended low-latency tuning target:

- `chunksize: 256`
- `target_level: 128`

---

## Safety Guidance

- Keep main gain at `0 dB` unless intentional boost is required.
- Keep the limiter last in the chain.
- Prefer fail-safe routing so audio remains available if DSP exits.
