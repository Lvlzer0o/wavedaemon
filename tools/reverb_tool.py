#!/usr/bin/env python3
"""
Generate convolution reverb impulse responses and WaveDaemon profiles.

Examples:
  python3 tools/reverb_tool.py list-presets
  python3 tools/reverb_tool.py preset small_room
  python3 tools/reverb_tool.py make --name custom_wide --length 1.8 --decay 1.1 --wet 0.24
"""

from __future__ import annotations

import argparse
import math
import random
import re
import sys
import wave
from array import array
from dataclasses import dataclass
from pathlib import Path
from typing import Dict


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DSP_DIR = REPO_ROOT / "dsp"
IRS_DIR = DSP_DIR / "irs"
PROFILES_DIR = DSP_DIR / "profiles"


@dataclass(frozen=True)
class ReverbSettings:
    length: float
    decay: float
    wet: float
    dry: float
    predelay_ms: float
    hf_damping: float
    early_reflections: int
    samplerate: int = 48_000
    seed: int = 42


PRESETS: Dict[str, ReverbSettings] = {
    "small_room": ReverbSettings(
        length=0.70,
        decay=0.35,
        wet=0.18,
        dry=0.94,
        predelay_ms=8.0,
        hf_damping=0.72,
        early_reflections=12,
        seed=101,
    ),
    "vocal_plate": ReverbSettings(
        length=1.20,
        decay=0.78,
        wet=0.24,
        dry=0.88,
        predelay_ms=16.0,
        hf_damping=0.60,
        early_reflections=20,
        seed=202,
    ),
    "large_hall": ReverbSettings(
        length=2.10,
        decay=1.45,
        wet=0.30,
        dry=0.82,
        predelay_ms=22.0,
        hf_damping=0.80,
        early_reflections=26,
        seed=303,
    ),
}


def sanitize_name(name: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9_-]+", "_", name.strip()).strip("_").lower()
    if not safe:
        raise ValueError("name must contain letters, numbers, underscore, or dash")
    return safe


def synthesize_impulse(settings: ReverbSettings) -> list[float]:
    sr = settings.samplerate
    total_samples = max(1, int(settings.length * sr))
    predelay = max(0, int(settings.predelay_ms / 1000.0 * sr))
    predelay = min(predelay, total_samples - 1)
    decay = max(0.05, settings.decay)
    wet = max(0.0, min(settings.wet, 1.0))
    dry = max(0.0, min(settings.dry, 1.0))
    reflections = max(0, settings.early_reflections)
    damping = max(0.0, min(settings.hf_damping, 0.98))

    rng = random.Random(settings.seed)
    impulse = [0.0] * total_samples
    impulse[0] = dry

    early_window = min(total_samples - 1, predelay + int(sr * 0.12))
    for _ in range(reflections):
        position = rng.randint(predelay, max(predelay, early_window))
        time_s = max(0.0, (position - predelay) / sr)
        amplitude = wet * rng.uniform(0.22, 0.78) * math.exp(-time_s / decay)
        if rng.random() < 0.5:
            amplitude *= -1.0
        impulse[position] += amplitude

    lp = 0.0
    for i in range(predelay, total_samples):
        time_s = (i - predelay) / sr
        envelope = math.exp(-time_s / decay)
        noise = rng.uniform(-1.0, 1.0)
        lp = damping * lp + (1.0 - damping) * noise
        impulse[i] += wet * 0.085 * envelope * lp

    for delay_s, gain_scale in ((0.013, 0.10), (0.021, 0.07), (0.034, 0.05)):
        delay_samples = int(delay_s * sr)
        if delay_samples <= 0 or delay_samples >= total_samples:
            continue
        feedback = wet * gain_scale
        for i in range(delay_samples, total_samples):
            impulse[i] += impulse[i - delay_samples] * feedback

    mean = sum(impulse) / len(impulse)
    impulse = [sample - mean for sample in impulse]

    peak = max(abs(sample) for sample in impulse) or 1.0
    if peak > 0.98:
        scale = 0.98 / peak
        impulse = [sample * scale for sample in impulse]

    return impulse


def write_impulse_wav(path: Path, samples: list[float], samplerate: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = array("h")
    for sample in samples:
        bounded = max(-1.0, min(1.0, sample))
        pcm.append(int(round(bounded * 32767)))

    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(samplerate)
        wav_file.writeframes(pcm.tobytes())


def render_profile(base_text: str, ir_filename: str) -> str:
    convolution_block = (
        "  convolution_placeholder:\n"
        "    type: Conv\n"
        "    parameters:\n"
        "      type: Wav\n"
        f"      filename: \"dsp/irs/{ir_filename}\"\n"
        "      channel: 0\n"
    )

    start = base_text.find("  convolution_placeholder:")
    processors_idx = base_text.find("\n\nprocessors:", start)
    if start == -1 or processors_idx == -1:
        raise ValueError("Could not locate convolution_placeholder filter block in base profile")
    updated = base_text[:start] + convolution_block + base_text[processors_idx + 2 :]

    bypass_snippet = (
        "  - type: Filter\n"
        "    bypassed: true\n"
        "    channels: [0, 1]\n"
        "    names: [convolution_placeholder]\n"
    )
    enabled_snippet = (
        "  - type: Filter\n"
        "    channels: [0, 1]\n"
        "    names: [convolution_placeholder]\n"
    )

    if bypass_snippet in updated:
        updated = updated.replace(bypass_snippet, enabled_snippet)
    else:
        updated = re.sub(
            r"(?ms)^  - type: Filter\n(?:    .*?\n)*?    names: \[convolution_placeholder\]\n",
            enabled_snippet,
            updated,
            count=1,
        )
        if "names: [convolution_placeholder]" not in updated:
            raise ValueError("Could not find convolution pipeline step in base profile")

    return updated


def build_artifacts(
    name: str,
    settings: ReverbSettings,
    base_profile: Path,
    force: bool,
) -> tuple[Path, Path]:
    safe_name = sanitize_name(name)
    ir_path = IRS_DIR / f"{safe_name}.wav"
    profile_path = PROFILES_DIR / f"{safe_name}.yml"

    if not base_profile.exists():
        raise FileNotFoundError(f"Base profile not found: {base_profile}")

    if not force:
        for output in (ir_path, profile_path):
            if output.exists():
                raise FileExistsError(f"{output} exists. Use --force to overwrite.")

    samples = synthesize_impulse(settings)
    write_impulse_wav(ir_path, samples, settings.samplerate)

    base_text = base_profile.read_text(encoding="utf-8")
    profile_text = render_profile(base_text, ir_path.name)
    profile_path.write_text(profile_text, encoding="utf-8")

    return ir_path, profile_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="WaveDaemon reverb tooling")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list-presets", help="List built-in reverb presets")

    preset_parser = subparsers.add_parser("preset", help="Generate a built-in preset")
    preset_parser.add_argument("preset_name", choices=sorted(PRESETS.keys()))
    preset_parser.add_argument(
        "--base-profile",
        default=str(PROFILES_DIR / "flat.yml"),
        help="Base profile to clone (default: dsp/profiles/flat.yml)",
    )
    preset_parser.add_argument("--force", action="store_true", help="Overwrite existing files")

    make_parser = subparsers.add_parser("make", help="Generate a custom reverb preset")
    make_parser.add_argument("--name", required=True, help="Output preset/profile name")
    make_parser.add_argument("--length", type=float, default=1.1, help="Impulse length in seconds")
    make_parser.add_argument("--decay", type=float, default=0.75, help="Decay time in seconds")
    make_parser.add_argument("--wet", type=float, default=0.22, help="Wet level 0..1")
    make_parser.add_argument("--dry", type=float, default=0.90, help="Dry level 0..1")
    make_parser.add_argument("--predelay-ms", type=float, default=14.0, help="Predelay in milliseconds")
    make_parser.add_argument("--hf-damping", type=float, default=0.68, help="HF damping 0..0.98")
    make_parser.add_argument("--early-reflections", type=int, default=18, help="Early reflection count")
    make_parser.add_argument("--seed", type=int, default=777, help="Random seed")
    make_parser.add_argument(
        "--base-profile",
        default=str(PROFILES_DIR / "flat.yml"),
        help="Base profile to clone (default: dsp/profiles/flat.yml)",
    )
    make_parser.add_argument("--force", action="store_true", help="Overwrite existing files")

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.command == "list-presets":
        print("Available presets:")
        for name in sorted(PRESETS.keys()):
            settings = PRESETS[name]
            print(
                f"- {name}: length={settings.length}s decay={settings.decay}s "
                f"wet={settings.wet} predelay={settings.predelay_ms}ms"
            )
        return 0

    if args.command == "preset":
        settings = PRESETS[args.preset_name]
        base_profile = Path(args.base_profile).expanduser().resolve()
        ir_path, profile_path = build_artifacts(
            name=args.preset_name,
            settings=settings,
            base_profile=base_profile,
            force=args.force,
        )
        print(f"Generated IR: {ir_path}")
        print(f"Generated profile: {profile_path}")
        return 0

    if args.command == "make":
        settings = ReverbSettings(
            length=args.length,
            decay=args.decay,
            wet=args.wet,
            dry=args.dry,
            predelay_ms=args.predelay_ms,
            hf_damping=args.hf_damping,
            early_reflections=args.early_reflections,
            seed=args.seed,
        )
        base_profile = Path(args.base_profile).expanduser().resolve()
        ir_path, profile_path = build_artifacts(
            name=args.name,
            settings=settings,
            base_profile=base_profile,
            force=args.force,
        )
        print(f"Generated IR: {ir_path}")
        print(f"Generated profile: {profile_path}")
        return 0

    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - CLI ergonomics
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
