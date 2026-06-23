#!/usr/bin/env python3
"""
Render one Basilisk snapshot without assembling a video.

This script intentionally reuses `Video-generic.py`'s sampling and plotting
helpers so diagnostic still images match the movie pipeline.
"""

from __future__ import annotations

import argparse
import importlib.util
import math
import shutil
import tempfile
from pathlib import Path
from types import SimpleNamespace
from typing import Any


def load_video_generic() -> Any:
    script_path = Path(__file__).resolve().with_name("Video-generic.py")
    spec = importlib.util.spec_from_file_location("video_generic", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_optional_float(value: str) -> float | None:
    if value.lower() == "auto":
        return None
    return float(value)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render a single mirrored-axis PNG from one snapshot.",
    )
    parser.add_argument(
        "--case-dir",
        type=Path,
        default=None,
        help=(
            "Case directory containing snapshots. Default: auto-detect using "
            "the same logic as Video-generic.py."
        ),
    )
    parser.add_argument(
        "--snap-glob",
        default="intermediate/snapshot-*",
        help="Snapshot glob pattern relative to --case-dir.",
    )
    parser.add_argument(
        "--snapshot",
        type=Path,
        help="Specific snapshot to render. Relative paths are resolved inside --case-dir.",
    )
    parser.add_argument(
        "--time",
        type=float,
        help="Render the snapshot nearest this simulation time.",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output PNG path. Default: case-dir/render-one-t<time>.png.",
    )
    parser.add_argument(
        "--ny",
        type=int,
        default=400,
        help="Number of grid points along physical y for scalar sampling.",
    )
    parser.add_argument(
        "--left-field",
        choices=("D2", "trA"),
        default="D2",
        help="Scalar field plotted on the left half of the mirrored domain.",
    )
    parser.add_argument("--xmin", type=parse_optional_float, default=None)
    parser.add_argument("--xmax", type=parse_optional_float, default=None)
    parser.add_argument("--ymin", type=parse_optional_float, default=None)
    parser.add_argument("--ymax", type=parse_optional_float, default=None)
    parser.add_argument("--vel-vmin", type=float)
    parser.add_argument("--vel-vmax", type=float)
    parser.add_argument("--left-vmin", type=float)
    parser.add_argument("--left-vmax", type=float)
    parser.add_argument("--vel-cmap", default=None)
    parser.add_argument("--left-cmap", default=None)
    parser.add_argument(
        "--keep-tools",
        action="store_true",
        help="Keep compiled helper binaries in case-dir/.render-one-tools.",
    )
    return parser.parse_args()


def resolve_snapshot(
    video: Any, case_dir: Path, snap_glob: str, snapshot: Path | None, time: float | None
) -> Path:
    if snapshot is not None:
        candidate = snapshot if snapshot.is_absolute() else case_dir / snapshot
        if not candidate.is_file():
            raise FileNotFoundError(f"Snapshot not found: {candidate}")
        return candidate.resolve()

    snapshots = video.list_snapshots(case_dir, snap_glob)
    if not snapshots:
        raise FileNotFoundError(f"No snapshots found in {case_dir} matching {snap_glob!r}")

    if time is None:
        return snapshots[-1].resolve()

    return min(snapshots, key=lambda path: abs(video.snapshot_time(path) - time)).resolve()


def render_one(video: Any, args: argparse.Namespace) -> Path:
    video.ensure_python_dependencies()
    video.ensure_plotting_runtime()

    cwd = Path.cwd().resolve()
    case_dir = args.case_dir.resolve() if args.case_dir else video.auto_detect_case_dir(cwd, args.snap_glob)
    snapshot = resolve_snapshot(video, case_dir, args.snap_glob, args.snapshot, args.time)
    t = video.snapshot_time(snapshot)

    build_root: Path | None = None
    cleanup: tempfile.TemporaryDirectory[str] | None = None
    if args.keep_tools:
        build_root = case_dir / ".render-one-tools"
        build_root.mkdir(parents=True, exist_ok=True)
    else:
        cleanup = tempfile.TemporaryDirectory(prefix="render-one-tools-", dir=case_dir)
        build_root = Path(cleanup.name)

    try:
        assert build_root is not None
        facet_bin, data_bin = video.precompile_get_helpers(Path(__file__).resolve().parent, build_root)
        interface_segments = video.get_facets(snapshot, facet_bin, case_dir)
        xmin, xmax, ymin, ymax = video.resolve_plot_window_from_facets(
            interface_segments, args.xmin, args.xmax, args.ymin, args.ymax
        )
        sample_ymin, sample_ymax = video.sampling_y_bounds_for_window(ymin, ymax)

        x_vel, y_vel, vel_field = video.get_field_grid(
            snapshot, data_bin, case_dir, "vel", xmin, sample_ymin, xmax, sample_ymax, args.ny
        )
        x_left, y_left, left_field = video.get_field_grid(
            snapshot,
            data_bin,
            case_dir,
            args.left_field,
            xmin,
            sample_ymin,
            xmax,
            sample_ymax,
            args.ny,
        )
        if len(x_vel) != len(x_left) or len(y_vel) != len(y_left):
            raise RuntimeError("vel/left grids are inconsistent.")
        if not video.np.allclose(x_vel, x_left) or not video.np.allclose(y_vel, y_left):
            raise RuntimeError("vel/left coordinate arrays are inconsistent.")

        vel_vmin, vel_vmax = args.vel_vmin, args.vel_vmax
        if vel_vmin is None or vel_vmax is None:
            auto_vmin, auto_vmax = finite_limits(video, vel_field)
            vel_vmin = auto_vmin if vel_vmin is None else vel_vmin
            vel_vmax = auto_vmax if vel_vmax is None else vel_vmax

        left_vmin, left_vmax = args.left_vmin, args.left_vmax
        if left_vmin is None or left_vmax is None:
            auto_vmin, auto_vmax = finite_limits(video, left_field)
            left_vmin = auto_vmin if left_vmin is None else left_vmin
            left_vmax = auto_vmax if left_vmax is None else left_vmax

        output = args.output
        if output is None:
            output = case_dir / f"render-one-t{t:0.4f}.png"
        output = output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)

        render_args = SimpleNamespace(
            xmin=xmin,
            xmax=xmax,
            ymin=ymin,
            ymax=ymax,
            ny=args.ny,
            vel_cmap=args.vel_cmap or video.default_cmap_for_field("vel"),
            left_cmap=args.left_cmap or video.default_cmap_for_field(args.left_field),
        )
        video.render_frame(
            frame_path=output,
            t=t,
            x=x_vel,
            y=y_vel,
            vel_field=vel_field,
            left_field=left_field,
            interface_segments=interface_segments,
            args=render_args,
            left_field_key=args.left_field,
            vel_vmin=vel_vmin,
            vel_vmax=vel_vmax,
            left_vmin=left_vmin,
            left_vmax=left_vmax,
        )
        print(f"WROTE {output} t={t:0.4f} snapshot={snapshot}")
        return output
    finally:
        if cleanup is not None:
            cleanup.cleanup()
        elif not args.keep_tools and build_root is not None:
            shutil.rmtree(build_root, ignore_errors=True)


def finite_limits(video: Any, field: Any) -> tuple[float | None, float | None]:
    values = field.compressed()
    values = values[video.np.isfinite(values)]
    if len(values) == 0:
        return None, None
    lo, hi = video.np.percentile(values, [2.0, 98.0])
    if not math.isfinite(float(lo)) or not math.isfinite(float(hi)) or lo == hi:
        return None, None
    return float(lo), float(hi)


if __name__ == "__main__":
    render_one(load_video_generic(), parse_args())
