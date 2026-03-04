#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required. Install it first: https://brew.sh"
  exit 1
fi

echo "Installing WaveDaemon dependencies..."

brew install camilladsp switchaudio-osx websocat jq
brew install --cask blackhole-2ch

echo "Done."
echo "Next:"
echo "  1) configure Audio MIDI Setup"
echo "  2) run ./scripts/wavedaemon-doctor.sh"
echo "  3) run ./scripts/start-audio-dsp-failsafe.sh"
