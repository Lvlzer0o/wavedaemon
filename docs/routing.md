# Routing Setup (CoreAudio)

This is the stable routing model for WaveDaemon on macOS.

## Goal

```text
macOS
↓
<multi-output-device>
↓
BlackHole 2ch
↓
CamillaDSP
↓
<aggregate-output-device>
↓
Speakers
```

## 1. Create Aggregate Device

In Audio MIDI Setup:

1. Click `+` and choose `Create Aggregate Device`.
2. Name it `<aggregate-output-device>` (recommended: `DSP Aggregate`).
3. Enable devices:
- `BlackHole 2ch`
- your hardware output (for example `Built-in Output`)
4. Set:
- Clock Source: your hardware output
- Sample Rate: `48000 Hz`

## 2. Create Multi-Output Device

1. Click `+` and choose `Create Multi-Output Device`.
2. Name it `<multi-output-device>` (recommended: `System DSP Output`).
3. Enable devices:
- your hardware output
- `<aggregate-output-device>`
4. Set macOS output device to `<multi-output-device>`.

## 3. CamillaDSP device mapping

In `dsp/config.yml`:

- capture device: `BlackHole 2ch`
- playback device: `<aggregate-output-device>`

If you use the recommended names, playback is `DSP Aggregate`.

## 4. Start commands

```bash
CAMILLADSP_AUTO_KEEPALIVE=1 ./scripts/start-audio-dsp-failsafe.sh
./scripts/start-audio-control-ui.sh
```

## 5. Verify

```bash
lsof -nP -iTCP:1234 -sTCP:LISTEN
printf '"GetVersion"\n' | websocat -n1 ws://127.0.0.1:1234
printf '"GetState"\n' | websocat -n1 ws://127.0.0.1:1234
```

Expected state is `Running`.
