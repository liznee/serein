#!/usr/bin/env python3
"""Replace the generated phone UI in the Serein promo with real app captures.

The source clip has two hand-held phone shots.  The screen planes are tracked
with a small set of hand-checked keyframes, then the supplied HarmonyOS
captures are projected onto those planes per frame.  The source audio is muxed
back afterwards so this script is safe to rerun without touching the original.

Usage (PowerShell):
  python tools/video/replace_promo_screens.py \
    --input "path\\to\\watermark-free-promo.mp4" \
    --ffmpeg "path\\to\\ffmpeg.exe" \
    --capture project="path\\to\\project.jpg" \
    --capture terminal="path\\to\\terminal.jpg" \
    --capture community="path\\to\\community.jpg" \
    --capture approval="path\\to\\approval.jpg" \
    --capture remote="path\\to\\remote.jpg"
"""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path
from typing import Iterable

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / "ui" / "assets" / "serein-workflow.mp4"
CAPTURE_NAMES = ("project", "terminal", "community", "approval", "remote")

# Coordinates are ordered top-left, top-right, bottom-right, bottom-left and
# describe the *lit display*, leaving the handset bezel and camera cutout alone.
METRO_TRACK = [
    (3.38, ((539, 103), (792, 111), (753, 618), (455, 607))),
    (4.60, ((538, 101), (786, 111), (748, 618), (454, 606))),
    (5.30, ((540, 96), (789, 105), (746, 625), (451, 613))),
    (6.20, ((547, 91), (786, 91), (739, 619), (451, 608))),
    (7.82, ((549, 92), (783, 98), (730, 610), (447, 598))),
]
OUTDOOR_TRACK = [
    (7.96, ((377, 305), (525, 312), (610, 635), (444, 650))),
    (8.70, ((367, 305), (538, 319), (598, 626), (420, 655))),
    (9.55, ((360, 284), (524, 289), (606, 625), (442, 651))),
]

# (start, end, capture name).  The order mirrors the actual product loop.
SCREEN_SEQUENCE = [
    (3.38, 4.52, "project"),
    (4.52, 5.48, "terminal"),
    (5.48, 6.42, "community"),
    (6.42, 7.82, "approval"),
    (7.96, 9.55, "remote"),
]
FADE_SECONDS = 0.14


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="new watermark-free promo source")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--ffmpeg", type=Path, required=True, help="ffmpeg executable used to mux original audio")
    parser.add_argument(
        "--capture",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="real app capture; required names: project, terminal, community, approval, remote",
    )
    return parser.parse_args()


def parse_captures(values: list[str]) -> dict[str, Path]:
    captures: dict[str, Path] = {}
    for value in values:
        name, separator, raw_path = value.partition("=")
        if not separator or name not in CAPTURE_NAMES or not raw_path:
            raise SystemExit(f"invalid --capture {value!r}; expected one of {CAPTURE_NAMES}=PATH")
        captures[name] = Path(raw_path)
    missing_names = [name for name in CAPTURE_NAMES if name not in captures]
    if missing_names:
        raise SystemExit("missing --capture values: " + ", ".join(missing_names))
    return captures


def as_points(points: Iterable[Iterable[int]]) -> np.ndarray:
    return np.asarray(points, dtype=np.float32)


def interpolate_track(track: list[tuple[float, tuple[tuple[int, int], ...]]], time_s: float) -> np.ndarray:
    if time_s <= track[0][0]:
        return as_points(track[0][1])
    if time_s >= track[-1][0]:
        return as_points(track[-1][1])
    for (left_t, left), (right_t, right) in zip(track, track[1:]):
        if left_t <= time_s <= right_t:
            ratio = (time_s - left_t) / (right_t - left_t)
            return as_points(left) * (1 - ratio) + as_points(right) * ratio
    raise RuntimeError("track interpolation failed")


def sequence_entry(time_s: float) -> tuple[float, float, str] | None:
    for entry in SCREEN_SEQUENCE:
        if entry[0] <= time_s <= entry[1]:
            return entry
    return None


def current_layers(time_s: float) -> list[tuple[str, float]]:
    """Return one or two screen captures, with a tiny crossfade at boundaries."""
    current = sequence_entry(time_s)
    if not current:
        return []
    start, end, name = current
    layers = [(name, 1.0)]
    for next_start, _, next_name in SCREEN_SEQUENCE:
        if next_start > start and next_start - FADE_SECONDS <= time_s <= next_start + FADE_SECONDS:
            progress = (time_s - (next_start - FADE_SECONDS)) / (2 * FADE_SECONDS)
            return [(name, float(1 - progress)), (next_name, float(progress))]
    # Fade in/out avoids a hard pop as a screen first becomes visible.
    layers[0] = (name, min(1.0, (time_s - start) / FADE_SECONDS, (end - time_s) / FADE_SECONDS))
    return [(screen_name, max(0.0, alpha)) for screen_name, alpha in layers]


def crop_to_phone_aspect(image: np.ndarray, aspect: float) -> np.ndarray:
    height, width = image.shape[:2]
    current = width / height
    if current > aspect:
        crop_width = int(height * aspect)
        offset = (width - crop_width) // 2
        return image[:, offset : offset + crop_width]
    crop_height = int(width / aspect)
    offset = (height - crop_height) // 2
    return image[offset : offset + crop_height, :]


def project_screen(frame: np.ndarray, capture: np.ndarray, destination: np.ndarray, opacity: float) -> np.ndarray:
    height, width = frame.shape[:2]
    side_left = np.linalg.norm(destination[3] - destination[0])
    side_right = np.linalg.norm(destination[2] - destination[1])
    top = np.linalg.norm(destination[1] - destination[0])
    bottom = np.linalg.norm(destination[2] - destination[3])
    aspect = (top + bottom) / max(1.0, side_left + side_right)
    phone_image = crop_to_phone_aspect(capture, aspect)
    src = as_points(((0, 0), (phone_image.shape[1] - 1, 0), (phone_image.shape[1] - 1, phone_image.shape[0] - 1), (0, phone_image.shape[0] - 1)))
    transform = cv2.getPerspectiveTransform(src, destination)
    warped = cv2.warpPerspective(phone_image, transform, (width, height), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_CONSTANT)
    mask = np.full(phone_image.shape[:2], 255, dtype=np.uint8)
    warped_mask = cv2.warpPerspective(mask, transform, (width, height), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
    alpha = (warped_mask.astype(np.float32) / 255.0) * opacity
    return (frame * (1.0 - alpha[:, :, None]) + warped * alpha[:, :, None]).astype(np.uint8)


def main() -> None:
    args = parse_args()
    capture_paths = parse_captures(args.capture)
    if not args.input.is_file():
        raise SystemExit(f"input not found: {args.input}")
    if not args.ffmpeg.is_file():
        raise SystemExit(f"ffmpeg not found: {args.ffmpeg}")
    missing = [path for path in capture_paths.values() if not path.is_file()]
    if missing:
        raise SystemExit("missing supplied captures:\n" + "\n".join(map(str, missing)))

    captures = {name: cv2.imread(str(path), cv2.IMREAD_COLOR) for name, path in capture_paths.items()}
    if any(image is None for image in captures.values()):
        raise SystemExit("failed to read one or more supplied captures")

    source = cv2.VideoCapture(str(args.input))
    if not source.isOpened():
        raise SystemExit(f"could not open: {args.input}")
    fps = source.get(cv2.CAP_PROP_FPS) or 60.0
    width = int(source.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(source.get(cv2.CAP_PROP_FRAME_HEIGHT))
    args.output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="serein-promo-") as temp_dir:
        silent_path = Path(temp_dir) / "video-with-real-ui.mp4"
        writer = cv2.VideoWriter(str(silent_path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
        if not writer.isOpened():
            raise SystemExit("could not initialize video writer")

        frame_index = 0
        while True:
            ok, frame = source.read()
            if not ok:
                break
            time_s = frame_index / fps
            entry = sequence_entry(time_s)
            if entry:
                track = METRO_TRACK if time_s <= METRO_TRACK[-1][0] else OUTDOOR_TRACK
                destination = interpolate_track(track, time_s)
                for capture_name, opacity in current_layers(time_s):
                    if opacity > 0.001:
                        frame = project_screen(frame, captures[capture_name], destination, opacity)
            writer.write(frame)
            frame_index += 1

        writer.release()
        source.release()
        command = [
            str(args.ffmpeg), "-y", "-i", str(silent_path), "-i", str(args.input),
            "-map", "0:v:0", "-map", "1:a?", "-c:v", "libx264", "-preset", "slow", "-crf", "17",
            "-c:a", "copy", "-movflags", "+faststart", str(args.output),
        ]
        subprocess.run(command, check=True)
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
