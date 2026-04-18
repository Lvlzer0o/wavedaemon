# WaveDaemon

![Version](https://img.shields.io/badge/version-v0.1.0-blue)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)
![GitHub Release](https://img.shields.io/github/v/release/Lvlzer0o/wavedaemon)

WaveDaemon is a macOS audio-DSP toolkit built around **CamillaDSP**, **BlackHole**, and a live **WebSocket control surface**. It provides a repeatable way to route system audio through a configurable DSP chain, with scripts for setup, validation, and fail-safe operation.

## What’s in this repo

WaveDaemon currently includes:

- A script-based DSP daemon workflow (`scripts/`) that starts/stops CamillaDSP and health tooling.
- DSP configuration and profiles (`dsp/`) including EQ/reverb profile variants.
- A browser-based control UI (`ui/control.html`).
- A native SwiftUI macOS app (`app/WaveDaemon`) and tests (`app/WaveDaemonTests`).
- Documentation and diagrams (`docs/`).

## Architecture

![WaveDaemon Architecture](docs/architecture.svg)

### Audio signal path

```text
macOS
→ Multi-Output Device (example: System DSP Output)
→ BlackHole 2ch
→ WaveDaemon (CamillaDSP engine)
→ Aggregate Output Device (example: DSP Aggregate)
→ Built-in speakers / external output
```

### Control path

```text
Browser UI or native app
→ WebSocket client connection (example: ws://127.0.0.1:1234)
→ CamillaDSP
→ Live DSP updates (volume, mute, profiles, EQ)
```

## Demo

![WaveDaemon Demo](docs/wavedaemon-demo.gif)

## Repository layout

```text
wavedaemon/
├── app/                        # Native macOS app (SwiftUI) + tests
├── docs/                       # Architecture, routing, demo assets
├── dsp/                        # CamillaDSP config, profiles, IR assets
├── scripts/                    # Start/stop, keepalive, install, doctor
├── tools/                      # Utility tools (latency estimator, helpers)
├── ui/                         # Browser control surface
├── README.md
└── LICENSE
```

## Prerequisites

- macOS
- Homebrew
- `blackhole-2ch`
- `camilladsp` (available in `PATH` or via `CAMILLADSP_BIN`)
- `switchaudio-osx`
- `websocat`
- `jq`
- `python3`

## Install dependencies

```bash
./scripts/install-deps.sh
```

Manual fallback:

```bash
brew install camilladsp switchaudio-osx websocat jq
brew install --cask blackhole-2ch
```

## Quick start

1. Configure routing in Audio MIDI Setup (see [`docs/routing.md`](docs/routing.md)).
2. Start DSP from repo root:

   ```bash
   CAMILLADSP_AUTO_KEEPALIVE=1 ./scripts/start-audio-dsp-failsafe.sh
   ```

3. Start the browser UI server:

   ```bash
   ./scripts/start-audio-control-ui.sh
   ```

4. Open:

   ```text
   http://127.0.0.1:9137/ui/control.html?ws=ws://127.0.0.1:1234
   ```

Suggested CoreAudio device names used in examples:

- Multi-output device: `System DSP Output`
- Aggregate output device: `DSP Aggregate`

## Environment variables

### Output/routing behavior

- `CAMILLADSP_MULTI_OUTPUT_NAME`
- `CAMILLADSP_MULTI_OUTPUT_FALLBACK`
- `CAMILLADSP_SAFE_OUTPUT_FALLBACK` (default: `Built-in Output`)
- `CAMILLADSP_ALLOW_RAW_OUTPUT_FALLBACK` (`1` enables auto-fallback to raw output)
- `CAMILLADSP_RAW_OUTPUT_FALLBACK` (default: `BlackHole 2ch`)
- `CAMILLADSP_STOP_OUTPUT_DEVICE`

### WebSocket topology

- **Daemon bind** (where locally spawned CamillaDSP listens):
  - `CAMILLADSP_BIND_ADDRESS`
  - `CAMILLADSP_BIND_PORT`
- **Client connect URL** (what UI/app connects to):
  - `CAMILLADSP_CLIENT_WS_URL`
- Backward compatibility:
  - If bind vars are not set, daemon bind falls back to `CAMILLADSP_WS_ADDRESS` / `CAMILLADSP_WS_PORT`.
  - Existing saved `preferredWebSocketURL` values continue to affect client connection behavior.

## Health checks (Doctor)

Run setup/runtime checks before or after configuration:

```bash
./scripts/wavedaemon-doctor.sh
```

Doctor validates:

- dependency availability (`camilladsp`, `SwitchAudioSource`, `websocat`, `jq`, `python3`)
- WebSocket bind/connect topology and local probe behavior
- required audio devices (`BlackHole 2ch`, aggregate, multi-output/fallback)
- sample-rate expectations (default target: `48000 Hz`)
- port availability (effective daemon bind port, UI port `9137`)
- config validity (`camilladsp --check`)
- runtime status (CamillaDSP, keepalive, UI server)

## Runtime validation

If daemon bind address is `0.0.0.0` or `*`, use `127.0.0.1` for local checks. If daemon bind is `::`, use `::1`.

```bash
lsof -nP -iTCP:1234 -sTCP:LISTEN
printf '"GetVersion"\n' | websocat -n1 ws://127.0.0.1:1234
printf '"GetState"\n' | websocat -n1 ws://127.0.0.1:1234
```

## Latency tooling

```bash
./tools/latency-test.sh
./tools/latency-test.sh ./dsp/config.yml
```

Recommended low-latency tuning target:

- `chunksize: 256`
- `target_level: 128`

## Safety notes

- Keep master gain at `0 dB` unless intentional boost is required.
- Prefer placing limiter stages at the end of the chain.
- Use fail-safe routing so audio continues if DSP exits unexpectedly.
