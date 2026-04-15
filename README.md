# WaveDaemon

![Version](https://img.shields.io/badge/version-v0.1.0-blue)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)
![GitHub Release](https://img.shields.io/github/v/release/Lvlzer0o/wavedaemon)

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

## Demo

![WaveDaemon Demo](docs/wavedaemon-demo.gif)

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
│   ├── wavedaemon-doctor.sh
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
│   ├── wavedaemon-demo.gif
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
- `CAMILLADSP_SAFE_OUTPUT_FALLBACK` (default: `Built-in Output`)
- `CAMILLADSP_ALLOW_RAW_OUTPUT_FALLBACK` (`1` to allow auto-fallback to `CAMILLADSP_RAW_OUTPUT_FALLBACK`)
- `CAMILLADSP_RAW_OUTPUT_FALLBACK` (default: `BlackHole 2ch`)
- `CAMILLADSP_STOP_OUTPUT_DEVICE`

WebSocket bind/connect split (migration-safe defaults):

- **Daemon bind** (where locally spawned CamillaDSP listens): `CAMILLADSP_BIND_ADDRESS`, `CAMILLADSP_BIND_PORT`
- **Client connect URL** (what UI/app connects to): `CAMILLADSP_CLIENT_WS_URL`
- Backward compatibility: if bind vars are not set, daemon bind falls back to `CAMILLADSP_WS_ADDRESS` / `CAMILLADSP_WS_PORT`; existing saved `preferredWebSocketURL` values continue to control client connection only.

## Doctor

Run health checks before or after setup:

```bash
./scripts/wavedaemon-doctor.sh
```

Checks include:

- dependencies (`camilladsp`, `SwitchAudioSource`, `websocat`, `jq`, `python3`)
- effective WebSocket topology (daemon bind, local probe, client connect URL)
- required audio devices (`BlackHole 2ch`, aggregate, multi-output/fallback)
- sample rates (target default: `48000 Hz`)
- port availability (effective daemon bind port, `9137`)
- config validation (`camilladsp --check`)
- runtime status (CamillaDSP, keepalive, UI server)

## Validate

Adjust host and port to match your deployment. If the daemon binds to `0.0.0.0` or `*`, use `127.0.0.1` for local readiness checks. If it binds to `::`, use `::1`.

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
