#!/usr/bin/env python3
"""
# Video-generic.py

Create a mirrored-axis video from Basilisk `snapshot-*` states for
axisymmetric two-phase runs.

## Pipeline

1. Restore each snapshot.
2. Sample `vel` plus one left-overlay scalar (`trA` by default, `D2` via flag)
   on a uniform grid using `getData-elastic.c`.
3. Extract `f` interface facets via `output_facets(f, ...)`.
4. Mirror about the axis of symmetry `y = 0` and render the full
   axisymmetric cross-section with the interface overlaid.
5. Write PNG frames and optionally assemble an MP4 with `ffmpeg`.

## Dependencies

- `qcc`: builds helper binaries from `getFacet.c` and
  `getData-elastic.c`.
- `numpy`: parsing, masking, and percentile-based color scaling.
- `matplotlib`: frame rendering.
- `ffmpeg`: optional MP4 assembly (skipped with `--skip-video`).

## Default Visualization

- Base layer: `vel` across the full mirrored domain, with the right colorbar.
- Left overlay: `trA` by default, or `D2` with `--left-d2`, shown only on the
  left half (`r <= 0`).
- Interface overlay: mirrored `f` facets from `output_facets`.
- Coordinate mapping:
  - horizontal axis: `r = y` (Basilisk `y`)
  - vertical axis: `z = x` (Basilisk `x`)
- Mirror facets across `r = 0` so the full axisymmetric cross-section is shown.
- Default window: `z in [0, 4*pi]` and `r in [-2, 2]`.
- Scalar sampling stays on the physical half-domain `y >= 0`; the negative-`r`
  side is created only by mirroring in post-processing.
- Default duration: `10 s` with `fps = N_frames / duration` when `--fps` is unset.

#### Example

```bash
python3 postProcess/Video-generic.py --case-dir simulationCases/1000
```
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import numpy as _np_types

    NDArray = _np_types.ndarray
    MaskedArray = _np_types.ma.MaskedArray
else:
    NDArray = Any
    MaskedArray = Any

np: Any = None
plt: Any = None
LineCollection: Any = None
WORKER_ENV_PID: int | None = None


FIELD_INDEX = {"D2": 2, "vel": 3, "trA": 4}
FIELD_LABEL = {
    "D2": r"$\log_{10}\!\left(\|\mathcal{D}\|\right)$",
    "vel": r"$\lvert \mathbf{u} \rvert$",
    "trA": r"$\log_{10}\!\left(\mathrm{tr}(\mathbf{A})/3\right)$",
}


def parse_args() -> argparse.Namespace:
    """
    Parse command-line options for frame extraction and video assembly.

    #### Returns

    - `argparse.Namespace`: Parsed command-line arguments.
    """
    parser = argparse.ArgumentParser(
        description="Create an axisymmetric video from Basilisk snapshots.",
    )
    parser.add_argument(
        "--case-dir",
        type=Path,
        default=None,
        help=(
            "Case directory containing `intermediate/snapshot-*`. "
            "Default: auto-detect from current directory and simulationCases/."
        ),
    )
    parser.add_argument(
        "--snap-glob",
        default="intermediate/snapshot-*",
        help="Snapshot glob pattern relative to `case-dir`.",
    )
    parser.add_argument(
        "--ny",
        type=int,
        default=400,
        help="Number of grid points along y for sampled scalar field.",
    )
    parser.add_argument(
        "--cpus",
        "--CPUs",
        dest="cpus",
        type=int,
        default=4,
        help="Number of worker processes for snapshot rendering (default: 4).",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=None,
        help="Output FPS. If omitted, computed from --duration.",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=10.0,
        help="Target output duration in seconds when --fps is not set (default: 10).",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="video-film-generic.mp4",
        help="Output MP4 path (relative paths resolved inside case-dir).",
    )
    parser.add_argument(
        "--frames-dir",
        type=Path,
        help="Directory for PNG frames (default: case-dir/Video).",
    )
    parser.add_argument(
        "--clean-frames",
        dest="clean_frames",
        action="store_true",
        default=True,
        help="Delete existing PNG files in frames-dir before rendering (default).",
    )
    parser.add_argument(
        "--no-clean-frames",
        dest="clean_frames",
        action="store_false",
        help="Keep existing PNG files in frames-dir.",
    )
    parser.add_argument(
        "--skip-video",
        action="store_true",
        help="Only write PNG frames and skip ffmpeg MP4 assembly.",
    )
    parser.add_argument(
        "--ffmpeg",
        default="ffmpeg",
        help="ffmpeg executable name/path.",
    )
    parser.add_argument("--max-frames", type=int, help="Render only first N frames.")
    parser.add_argument(
        "--start-time", type=float, help="Skip snapshots with t < this."
    )
    parser.add_argument("--end-time", type=float, help="Skip snapshots with t > this.")
    parser.add_argument(
        "--vel-vmin",
        type=float,
        help="vel color scale minimum (default: auto from first frame).",
    )
    parser.add_argument(
        "--vel-vmax",
        type=float,
        help="vel color scale maximum (default: auto from first frame).",
    )
    parser.add_argument(
        "--vel-cmap",
        default=None,
        help="vel colormap (default: viridis).",
    )
    parser.add_argument(
        "--tra-vmin",
        type=float,
        help="trA color scale minimum (default: auto from first frame).",
    )
    parser.add_argument(
        "--tra-vmax",
        type=float,
        help="trA color scale maximum (default: auto from first frame).",
    )
    parser.add_argument(
        "--tra-cmap",
        default=None,
        help="trA colormap when trA is selected for left plot (default: RdBu_r).",
    )
    parser.add_argument(
        "--left-d2",
        action="store_true",
        help="Plot D2 on the left instead of trA.",
    )
    parser.add_argument(
        "--d2-vmin",
        type=float,
        help="D2 color scale minimum (default: auto from first frame).",
    )
    parser.add_argument(
        "--d2-vmax",
        type=float,
        help="D2 color scale maximum (default: auto from first frame).",
    )
    parser.add_argument(
        "--d2-cmap",
        default=None,
        help="D2 colormap when --left-d2 is enabled (default: inferno).",
    )

    parser.add_argument(
        "--xmin",
        type=float,
        default=0.0,
        help="Window minimum in Basilisk x (= plotted z). Default: 0.",
    )
    parser.add_argument(
        "--xmax",
        type=float,
        default=4.0 * math.pi,
        help="Window maximum in Basilisk x (= plotted z). Default: 4*pi.",
    )
    parser.add_argument(
        "--ymin",
        type=float,
        default=-2.0,
        help="Window minimum in plotted r. Default: -2.",
    )
    parser.add_argument(
        "--ymax",
        type=float,
        default=2.0,
        help="Window maximum in plotted r. Default: 2.",
    )
    return parser.parse_args()


def ensure_python_dependencies() -> None:
    """
    Import `numpy`/`matplotlib` lazily and configure plotting defaults.

    #### Raises

    - `RuntimeError`: Required plotting dependencies are not installed.
    """
    global np, plt, LineCollection

    missing = []
    _matplotlib: Any | None = None
    try:
        import numpy as _np
    except ModuleNotFoundError:
        missing.append("numpy")
        _np = None

    try:
        import matplotlib as _matplotlib

        _matplotlib.use("Agg")
        import matplotlib.pyplot as _plt
        from matplotlib.collections import LineCollection as _LineCollection
    except ModuleNotFoundError:
        missing.append("matplotlib")
        _plt = None
        _LineCollection = None

    if missing:
        missing_str = ", ".join(sorted(set(missing)))
        raise RuntimeError(
            f"Missing required Python packages: {missing_str}. "
            "Install them (e.g. `pip install numpy matplotlib`)."
        )

    # Publication-style defaults with LaTeX typography.
    assert _matplotlib is not None
    _matplotlib.rcParams["font.family"] = "serif"
    _matplotlib.rcParams["font.serif"] = ["Computer Modern Roman", "DejaVu Serif"]
    _matplotlib.rcParams["mathtext.fontset"] = "cm"
    _matplotlib.rcParams["text.usetex"] = True
    _matplotlib.rcParams["text.latex.preamble"] = r"\usepackage{amsmath}"
    _matplotlib.rcParams["axes.linewidth"] = 2.5

    np = _np
    plt = _plt
    LineCollection = _LineCollection


def ensure_plotting_runtime() -> None:
    """
    Ensure plotting globals are available in the current process.
    """
    if np is None or plt is None or LineCollection is None:
        ensure_python_dependencies()


def configure_worker_environment(cache_root: Path | None) -> None:
    """
    Configure process-local matplotlib and LaTeX cache directories.
    """
    global WORKER_ENV_PID

    if cache_root is None:
        return

    pid = os.getpid()
    if WORKER_ENV_PID == pid:
        return

    worker_root = cache_root / f"worker-{pid}"
    mpl_dir = worker_root / "mplconfig"
    tex_var_dir = worker_root / "texmf-var"
    tex_cfg_dir = worker_root / "texmf-config"
    for path in (mpl_dir, tex_var_dir, tex_cfg_dir):
        path.mkdir(parents=True, exist_ok=True)

    os.environ["MPLCONFIGDIR"] = str(mpl_dir)
    os.environ["TEXMFVAR"] = str(tex_var_dir)
    os.environ["TEXMFCONFIG"] = str(tex_cfg_dir)
    os.environ.setdefault("OMP_NUM_THREADS", "1")

    WORKER_ENV_PID = pid


def run_capture(cmd: list[str], cwd: Path | None = None) -> str:
    """
    Run a subprocess and return combined `stdout` + `stderr` text.

    #### Args

    - `cmd`: Command and arguments passed to `subprocess.run`.
    - `cwd`: Working directory used for command execution.

    #### Returns

    - `str`: Concatenated standard output and error output.

    #### Raises

    - `subprocess.CalledProcessError`: The command exits with a non-zero code.
    """
    result = subprocess.run(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    return (result.stdout or "") + (result.stderr or "")


def snapshot_argument(snapshot: Path, case_dir: Path) -> str:
    """
    Return a case-relative snapshot path when possible.
    """
    try:
        return str(snapshot.relative_to(case_dir))
    except ValueError:
        return str(snapshot)


def snapshot_time(path: Path) -> float:
    """
    Extract time from a filename of form `snapshot-<time>`.
    """
    name = path.name
    if "snapshot-" not in name:
        return math.inf
    raw = name.split("snapshot-", 1)[1]
    try:
        return float(raw)
    except ValueError:
        return math.inf


def list_snapshots(case_dir: Path, pattern: str) -> list[Path]:
    """
    Collect and sort snapshot files by simulation time.
    """
    snapshots = sorted(case_dir.glob(pattern), key=snapshot_time)
    return [p for p in snapshots if p.is_file()]


def read_case_number_from_params(params_path: Path) -> str | None:
    """
    Parse `CaseNo=<int>` from a params file.
    """
    try:
        text = params_path.read_text(encoding="utf-8")
    except OSError:
        return None

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() != "CaseNo":
            continue
        value = value.split("#", 1)[0].strip()
        if value.isdigit():
            return value
        return None
    return None


def auto_detect_case_dir(cwd: Path, snap_glob: str) -> Path:
    """
    Auto-detect case directory when script is run from repository root.

    Detection order:
    1. `cwd` itself if snapshots are present.
    2. `simulationCases/<CaseNo>` using `default.params`.
    3. Highest numeric `simulationCases/<N>` containing snapshots.
    """
    if list_snapshots(cwd, snap_glob):
        return cwd

    sim_root = cwd / "simulationCases"
    if not sim_root.is_dir():
        return cwd

    params_case = read_case_number_from_params(cwd / "default.params")
    if params_case is not None:
        preferred = sim_root / params_case
        if preferred.is_dir() and list_snapshots(preferred, snap_glob):
            return preferred

    numeric_cases = []
    for candidate in sim_root.iterdir():
        if not candidate.is_dir() or not candidate.name.isdigit():
            continue
        if list_snapshots(candidate, snap_glob):
            numeric_cases.append(candidate)

    if not numeric_cases:
        return cwd

    numeric_cases.sort(key=lambda p: int(p.name))
    return numeric_cases[-1]


def sampling_y_bounds_for_window(ymin: float, ymax: float) -> tuple[float, float]:
    """
    Map the mirrored plotting window in `r` to physical non-negative `y` bounds.
    """
    y_hi = max(abs(ymin), abs(ymax))
    if ymin <= 0.0 <= ymax:
        return 0.0, y_hi
    y_lo = min(abs(ymin), abs(ymax))
    return y_lo, y_hi


def compile_get_helper(source: Path, output: Path) -> None:
    """
    Compile one get* helper with `qcc`.
    """
    cmd = [
        "qcc",
        "-O2",
        "-Wall",
        "-disable-dimensions",
        source.name,
        "-o",
        str(output),
        "-lm",
    ]
    subprocess.run(cmd, check=True, cwd=source.parent)


def precompile_get_helpers(script_dir: Path, build_dir: Path) -> tuple[Path, Path]:
    """
    Pre-processing step: compile get* helper binaries before rendering.

    #### Returns

    - `tuple[Path, Path]`: `(facet_bin, data_bin)`.
    """
    if shutil.which("qcc") is None:
        raise RuntimeError("qcc not found in PATH.")

    facet_src = script_dir / "getFacet.c"
    data_src = script_dir / "getData-elastic.c"

    if not facet_src.exists() or not data_src.exists():
        raise FileNotFoundError(
            "Required files not found in postProcess/: "
            "getFacet.c and/or getData-elastic.c"
        )

    facet_bin = build_dir / "getFacet"
    data_bin = build_dir / "getData-elastic"

    compile_get_helper(facet_src, facet_bin)
    compile_get_helper(data_src, data_bin)

    return facet_bin, data_bin


def parse_facet_segments(raw: str) -> NDArray:
    """
    Parse `output_facets` text into a `N x 2 x 2` segment array.
    """
    points: list[list[float]] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        vals = line.split()
        if len(vals) < 2:
            continue
        try:
            points.append([float(vals[0]), float(vals[1])])
        except ValueError:
            continue

    if len(points) < 2:
        return np.empty((0, 2, 2), dtype=float)

    usable = len(points) - (len(points) % 2)
    arr = np.asarray(points[:usable], dtype=float)
    return arr.reshape(-1, 2, 2)


def get_facets(snapshot: Path, facet_bin: Path, case_dir: Path) -> NDArray:
    """
    Extract interface segments for `f`.
    """
    raw = run_capture([str(facet_bin), snapshot_argument(snapshot, case_dir)], cwd=case_dir)
    return parse_facet_segments(raw)


def resolve_plot_window_from_facets(
    interface_segments: NDArray,
    xmin: float | None,
    xmax: float | None,
    ymin: float | None,
    ymax: float | None,
) -> tuple[float, float, float, float]:
    """
    Resolve plotting bounds, auto-detecting from facets when values are omitted.
    """
    if len(interface_segments) == 0:
        if None in (xmin, xmax, ymin, ymax):
            raise RuntimeError(
                "No interface facets found in first snapshot and plot bounds were not fully specified."
            )
        assert xmin is not None and xmax is not None and ymin is not None and ymax is not None
        return xmin, xmax, ymin, ymax

    x_vals = interface_segments[..., 0].reshape(-1)
    y_vals = interface_segments[..., 1].reshape(-1)
    x_data_min = float(np.min(x_vals))
    x_data_max = float(np.max(x_vals))
    y_abs_max = float(np.max(np.abs(y_vals)))

    x_span = max(x_data_max - x_data_min, 1e-12)
    x_pad = 0.02 * x_span
    auto_xmin = x_data_min - x_pad
    auto_xmax = x_data_max + x_pad

    y_abs_max = max(y_abs_max, 1e-12)
    auto_ymax = 1.05 * y_abs_max
    auto_ymin = -auto_ymax

    x_min_plot = auto_xmin if xmin is None else xmin
    x_max_plot = auto_xmax if xmax is None else xmax
    y_min_plot = auto_ymin if ymin is None else ymin
    y_max_plot = auto_ymax if ymax is None else ymax

    if x_min_plot >= x_max_plot:
        raise ValueError("--xmin must be < --xmax after resolving auto bounds.")
    if y_min_plot >= y_max_plot:
        raise ValueError("--ymin must be < --ymax after resolving auto bounds.")

    return x_min_plot, x_max_plot, y_min_plot, y_max_plot


def get_field_grid(
    snapshot: Path,
    data_bin: Path,
    case_dir: Path,
    field_key: str,
    xmin: float,
    ymin: float,
    xmax: float,
    ymax: float,
    ny: int,
) -> tuple[NDArray, NDArray, MaskedArray]:
    """
    Sample one derived field on a uniform grid inside `[xmin, xmax] x [ymin, ymax]`.
    """
    raw = run_capture(
        [
            str(data_bin),
            snapshot_argument(snapshot, case_dir),
            f"{xmin:.16g}",
            f"{ymin:.16g}",
            f"{xmax:.16g}",
            f"{ymax:.16g}",
            str(ny),
            "0",
            "0",
            "0",
        ],
        cwd=case_dir,
    )

    rows = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        vals = line.split()
        if len(vals) < 5:
            continue
        try:
            rows.append(
                [
                    float(vals[0]),
                    float(vals[1]),
                    float(vals[2]),
                    float(vals[3]),
                    float(vals[4]),
                ]
            )
        except ValueError:
            continue

    if not rows:
        raise RuntimeError(f"No field data parsed for snapshot: {snapshot}")

    arr = np.asarray(rows, dtype=float)
    x = arr[:, 0]
    y = arr[:, 1]
    field = arr[:, FIELD_INDEX[field_key]]

    x_unique = np.unique(x)
    y_unique = np.unique(y)
    ix = np.searchsorted(x_unique, x)
    iy = np.searchsorted(y_unique, y)

    grid = np.full((len(y_unique), len(x_unique)), np.nan, dtype=float)
    grid[iy, ix] = field

    invalid = (~np.isfinite(grid)) | (np.abs(grid) > 1e20)
    return x_unique, y_unique, np.ma.array(grid, mask=invalid)


def grid_extent(x: NDArray, y: NDArray) -> list[float]:
    """
    Convert center-coordinates to image extent bounds.
    """
    dx = float(np.median(np.diff(x))) if len(x) > 1 else 1.0
    dy = float(np.median(np.diff(y))) if len(y) > 1 else 1.0
    return [x[0] - 0.5 * dx, x[-1] + 0.5 * dx, y[0] - 0.5 * dy, y[-1] + 0.5 * dy]


def map_segments_xy_to_rz(segments: NDArray) -> NDArray:
    """
    Map Basilisk `(x, y)` segments to plotting `(r, z)` with `r = y`, `z = x`.
    """
    if len(segments) == 0:
        return segments
    return segments[..., [1, 0]].copy()


def mirror_segments_about_r0(segments_rz: NDArray) -> NDArray:
    """
    Mirror `(r, z)` segments about `r = 0` and return combined segments.
    """
    if len(segments_rz) == 0:
        return segments_rz
    mirrored = segments_rz.copy()
    mirrored[..., 0] *= -1.0
    return np.concatenate([mirrored, segments_rz], axis=0)


def mirror_field_xy_to_rz(
    field_xy: MaskedArray, r_pos: NDArray
) -> tuple[NDArray, MaskedArray]:
    """
    Build a full `(-r, +r)` field in `(r, z)` coordinates from positive-`r` data.
    """
    field_pos = np.ma.array(field_xy.T, copy=False)  # (nz, nr_pos)
    r_positive = np.asarray(r_pos, dtype=float)
    r_negative = -r_positive[::-1]
    field_negative = field_pos[:, ::-1]
    r_full = np.concatenate([r_negative, r_positive])
    field_full = np.ma.concatenate([field_negative, field_pos], axis=1)
    return r_full, field_full


def mask_field_outside_r_window(
    field_rz: MaskedArray, r_full: NDArray, rmin: float, rmax: float
) -> MaskedArray:
    """
    Mask columns whose radial coordinate lies outside `[rmin, rmax]`.
    """
    masked = np.ma.array(field_rz, copy=True)
    outside = (r_full < rmin) | (r_full > rmax)
    masked[:, outside] = np.ma.masked
    return masked


def mask_field_to_side(field_rz: MaskedArray, r_full: NDArray, side: str) -> MaskedArray:
    """
    Mask an `(r, z)` field so it is visible only on one side of the axis.
    """
    masked = np.ma.array(field_rz, copy=True)
    if side == "left":
        masked[:, r_full > 0.0] = np.ma.masked
        return masked
    if side == "right":
        masked[:, r_full < 0.0] = np.ma.masked
        return masked
    raise ValueError(f"Unsupported side selector: {side}")


def render_frame(
    frame_path: Path,
    t: float,
    x: NDArray,
    y: NDArray,
    vel_field: MaskedArray,
    left_field: MaskedArray,
    interface_segments: NDArray,
    args: argparse.Namespace,
    left_field_key: str,
    vel_vmin: float | None,
    vel_vmax: float | None,
    left_vmin: float | None,
    left_vmax: float | None,
) -> None:
    """
    Render one PNG frame with full-width vel, left-half scalar overlay, and `f`.
    """
    fig, ax = plt.subplots(figsize=(5.8, 10.5), dpi=180)
    r_full, vel_rz = mirror_field_xy_to_rz(vel_field, y)
    vel_rz = mask_field_outside_r_window(vel_rz, r_full, args.ymin, args.ymax)
    r_full_left, left_rz = mirror_field_xy_to_rz(left_field, y)
    left_rz = mask_field_outside_r_window(left_rz, r_full_left, args.ymin, args.ymax)
    left_rz = mask_field_to_side(left_rz, r_full_left, "left")
    if len(r_full_left) != len(r_full) or not np.allclose(r_full_left, r_full):
        raise RuntimeError("vel/left mirrored radial grids are inconsistent.")
    extent_rz = grid_extent(r_full, x)

    vel_image = ax.imshow(
        vel_rz,
        origin="lower",
        extent=extent_rz,
        cmap=args.vel_cmap,
        vmin=vel_vmin,
        vmax=vel_vmax,
        aspect="equal",
        interpolation="nearest",
        zorder=1,
    )

    left_image = ax.imshow(
        left_rz,
        origin="lower",
        extent=extent_rz,
        cmap=args.left_cmap,
        vmin=left_vmin,
        vmax=left_vmax,
        aspect="equal",
        interpolation="nearest",
        alpha=0.8,
        zorder=3,
    )

    interface_rz = mirror_segments_about_r0(map_segments_xy_to_rz(interface_segments))
    if len(interface_rz):
        ax.add_collection(
            LineCollection(interface_rz, colors="white", linewidths=2.8, alpha=0.9)
        )
        ax.add_collection(
            LineCollection(interface_rz, colors="black", linewidths=1.5, alpha=1.0)
        )

    ax.axvline(0.0, color="0.5", linewidth=1.0, linestyle="--", zorder=4)
    ax.set_xlim(args.ymin, args.ymax)
    ax.set_ylim(args.xmin, args.xmax)
    ax.set_aspect("equal")
    ax.set_axis_off()

    ax.set_title(
        rf"$t={t:0.4f}$",
        fontsize=32,
        pad=16,
    )

    fig.tight_layout(rect=(0.11, 0.03, 0.86, 0.97))
    l, b, w, h = ax.get_position().bounds
    cbar_w = 0.02
    cbar_gap = 0.05

    cax_right = fig.add_axes([l + w + cbar_gap, b, cbar_w, h])
    cbar_right = fig.colorbar(vel_image, cax=cax_right, orientation="vertical")
    cbar_right.set_label(FIELD_LABEL["vel"], fontsize=20, labelpad=8)
    cbar_right.ax.tick_params(labelsize=16, width=1.4, length=5, direction="out")
    cbar_right.outline.set_linewidth(1.4)

    cax_left = fig.add_axes([l - cbar_gap - cbar_w, b, cbar_w, h])
    cbar_left = fig.colorbar(left_image, cax=cax_left, orientation="vertical")
    cbar_left.set_label(FIELD_LABEL[left_field_key], fontsize=20, labelpad=8)
    cbar_left.ax.tick_params(labelsize=16, width=1.4, length=5, direction="out")
    cbar_left.outline.set_linewidth(1.4)
    cbar_left.ax.yaxis.set_ticks_position("left")
    cbar_left.ax.yaxis.set_label_position("left")

    fig.savefig(frame_path, bbox_inches="tight")
    plt.close(fig)


def format_fps(fps: float) -> str:
    """
    Format FPS for ffmpeg CLI arguments.
    """
    return f"{fps:.6f}".rstrip("0").rstrip(".")


def default_limits_for_field(field_key: str) -> tuple[float | None, float | None]:
    """
    Return fixed default color limits for known fields.

    Defaults are auto-resolved from the first rendered frame unless overridden.
    """
    return None, None


def default_cmap_for_field(field_key: str) -> str:
    """
    Return a default colormap per field.
    """
    if field_key == "trA":
        return "RdBu_r"
    if field_key == "D2":
        return "inferno"
    return "viridis"


def render_single_snapshot(
    idx: int,
    snapshot: Path,
    case_dir: Path,
    frames_dir: Path,
    facet_bin: Path,
    data_bin: Path,
    args: argparse.Namespace,
    left_field_key: str,
    vel_vmin: float | None,
    vel_vmax: float | None,
    left_vmin: float | None,
    left_vmax: float | None,
    worker_cache_root: Path | None,
) -> tuple[int, Path]:
    """
    Render one frame for a snapshot and return `(index, frame_path)`.
    """
    configure_worker_environment(worker_cache_root)
    ensure_plotting_runtime()

    t = snapshot_time(snapshot)

    xmin = args.xmin
    xmax = args.xmax
    ymin, ymax = sampling_y_bounds_for_window(args.ymin, args.ymax)

    x_vel, y_vel, vel_field = get_field_grid(
        snapshot, data_bin, case_dir, "vel", xmin, ymin, xmax, ymax, args.ny
    )
    x_left, y_left, left_field = get_field_grid(
        snapshot, data_bin, case_dir, left_field_key, xmin, ymin, xmax, ymax, args.ny
    )
    if len(x_vel) != len(x_left) or len(y_vel) != len(y_left):
        raise RuntimeError("vel/left grids are inconsistent.")
    if not np.allclose(x_vel, x_left) or not np.allclose(y_vel, y_left):
        raise RuntimeError("vel/left coordinate arrays are inconsistent.")

    interface_segments = get_facets(snapshot, facet_bin, case_dir)

    frame_path = frames_dir / f"frame_{idx:06d}.png"
    render_frame(
        frame_path=frame_path,
        t=t,
        x=x_vel,
        y=y_vel,
        vel_field=vel_field,
        left_field=left_field,
        interface_segments=interface_segments,
        args=args,
        left_field_key=left_field_key,
        vel_vmin=vel_vmin,
        vel_vmax=vel_vmax,
        left_vmin=left_vmin,
        left_vmax=left_vmax,
    )
    return idx, frame_path


def render_snapshots(
    snapshots: list[Path],
    case_dir: Path,
    frames_dir: Path,
    facet_bin: Path,
    data_bin: Path,
    args: argparse.Namespace,
    left_field_key: str,
    vel_vmin: float | None,
    vel_vmax: float | None,
    left_vmin: float | None,
    left_vmax: float | None,
    worker_cache_root: Path | None,
) -> None:
    """
    Render all snapshots, batching work in chunks of `args.cpus`.
    """
    tasks = list(enumerate(snapshots))
    total = len(tasks)

    if args.cpus <= 1:
        for idx, snapshot in tasks:
            _, frame_path = render_single_snapshot(
                idx=idx,
                snapshot=snapshot,
                case_dir=case_dir,
                frames_dir=frames_dir,
                facet_bin=facet_bin,
                data_bin=data_bin,
                args=args,
                left_field_key=left_field_key,
                vel_vmin=vel_vmin,
                vel_vmax=vel_vmax,
                left_vmin=left_vmin,
                left_vmax=left_vmax,
                worker_cache_root=None,
            )
            print(f"[{idx + 1}/{total}] wrote {frame_path}", file=sys.stderr)
        return

    with ProcessPoolExecutor(max_workers=args.cpus) as executor:
        for start in range(0, total, args.cpus):
            batch = tasks[start : start + args.cpus]
            futures = [
                executor.submit(
                    render_single_snapshot,
                    idx,
                    snapshot,
                    case_dir,
                    frames_dir,
                    facet_bin,
                    data_bin,
                    args,
                    left_field_key,
                    vel_vmin,
                    vel_vmax,
                    left_vmin,
                    left_vmax,
                    worker_cache_root,
                )
                for idx, snapshot in batch
            ]
            batch_results = [future.result() for future in futures]
            for idx, frame_path in sorted(batch_results, key=lambda item: item[0]):
                print(f"[{idx + 1}/{total}] wrote {frame_path}", file=sys.stderr)


def main() -> int:
    """
    Execute snapshot discovery, frame rendering, and optional MP4 assembly.

    #### Returns

    - `int`: Process exit code (`0` for success, non-zero for errors).
    """
    args = parse_args()
    left_field_key = "D2" if args.left_d2 else "trA"

    if args.vel_cmap is None:
        args.vel_cmap = default_cmap_for_field("vel")
    if left_field_key == "D2":
        args.left_cmap = (
            args.d2_cmap if args.d2_cmap is not None else default_cmap_for_field("D2")
        )
    else:
        args.left_cmap = (
            args.tra_cmap
            if args.tra_cmap is not None
            else default_cmap_for_field("trA")
        )

    try:
        ensure_python_dependencies()
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    explicit_case_dir = args.case_dir is not None
    if explicit_case_dir:
        case_dir = args.case_dir.resolve()
    else:
        cwd = Path.cwd().resolve()
        case_dir = auto_detect_case_dir(cwd, args.snap_glob)
        if case_dir != cwd:
            print(f"Auto-detected case directory: {case_dir}", file=sys.stderr)

    script_dir = Path(__file__).resolve().parent

    snapshots = list_snapshots(case_dir, args.snap_glob)
    if args.start_time is not None:
        snapshots = [s for s in snapshots if snapshot_time(s) >= args.start_time]
    if args.end_time is not None:
        snapshots = [s for s in snapshots if snapshot_time(s) <= args.end_time]
    if args.max_frames is not None:
        snapshots = snapshots[: args.max_frames]

    if not snapshots:
        hint = ""
        if explicit_case_dir:
            hint = " (check --case-dir and --snap-glob)"
        else:
            hint = " (you can pass --case-dir simulationCases/<CaseNo>)"
        print(
            f"No snapshots found with pattern '{args.snap_glob}' in {case_dir}{hint}",
            file=sys.stderr,
        )
        return 1
    if args.ny <= 2:
        print("--ny must be > 2", file=sys.stderr)
        return 1
    if args.duration <= 0:
        print("--duration must be > 0", file=sys.stderr)
        return 1
    sample_ymin: float | None = None
    sample_ymax: float | None = None
    if args.cpus <= 0:
        print("--cpus must be > 0", file=sys.stderr)
        return 1
    if not args.skip_video and shutil.which(args.ffmpeg) is None:
        print(f"ffmpeg executable not found: {args.ffmpeg}", file=sys.stderr)
        return 1

    out_path = Path(args.output)
    if not out_path.is_absolute():
        out_path = case_dir / out_path
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if args.frames_dir is None:
        frames_dir = case_dir / "Video"
    else:
        frames_dir = (
            args.frames_dir
            if args.frames_dir.is_absolute()
            else (case_dir / args.frames_dir)
        )
    frames_dir.mkdir(parents=True, exist_ok=True)

    if args.clean_frames:
        for old_png in frames_dir.glob("*.png"):
            old_png.unlink()

    temp_objects: list[tempfile.TemporaryDirectory[str]] = []
    temp_build = tempfile.TemporaryDirectory(prefix="video-film-tools-", dir=case_dir)
    temp_objects.append(temp_build)
    build_dir = Path(temp_build.name)
    worker_cache_root: Path | None = None
    if args.cpus > 1:
        temp_worker_cache = tempfile.TemporaryDirectory(
            prefix="video-film-worker-cache-", dir=case_dir
        )
        temp_objects.append(temp_worker_cache)
        worker_cache_root = Path(temp_worker_cache.name)

    try:
        print("Pre-processing: compiling get* helpers...", file=sys.stderr)
        facet_bin, data_bin = precompile_get_helpers(script_dir, build_dir)

        first_facets = get_facets(snapshots[0], facet_bin, case_dir)
        (
            args.xmin,
            args.xmax,
            args.ymin,
            args.ymax,
        ) = resolve_plot_window_from_facets(
            interface_segments=first_facets,
            xmin=args.xmin,
            xmax=args.xmax,
            ymin=args.ymin,
            ymax=args.ymax,
        )
        print(
            (
                f"Using plot window: z in [{args.xmin:.6g}, {args.xmax:.6g}], "
                f"r in [{args.ymin:.6g}, {args.ymax:.6g}]"
            ),
            file=sys.stderr,
        )
        sample_ymin, sample_ymax = sampling_y_bounds_for_window(args.ymin, args.ymax)
        if sample_ymax <= sample_ymin:
            raise ValueError("At least one of --ymin/--ymax must be non-zero.")

        _, _, vel0 = get_field_grid(
            snapshots[0],
            data_bin,
            case_dir,
            "vel",
            args.xmin,
            sample_ymin,
            args.xmax,
            sample_ymax,
            args.ny,
        )
        _, _, left0 = get_field_grid(
            snapshots[0],
            data_bin,
            case_dir,
            left_field_key,
            args.xmin,
            sample_ymin,
            args.xmax,
            sample_ymax,
            args.ny,
        )

        fixed_vel_vmin, fixed_vel_vmax = default_limits_for_field("vel")
        need_auto_vel = (args.vel_vmin is None and fixed_vel_vmin is None) or (
            args.vel_vmax is None and fixed_vel_vmax is None
        )
        auto_vel_vmin, auto_vel_vmax = None, None
        if need_auto_vel:
            valid_vel0 = vel0.compressed()
            if valid_vel0.size:
                auto_vel_vmin = float(np.percentile(valid_vel0, 2.0))
                auto_vel_vmax = float(np.percentile(valid_vel0, 98.0))
                if (
                    not np.isfinite(auto_vel_vmin)
                    or not np.isfinite(auto_vel_vmax)
                    or auto_vel_vmin == auto_vel_vmax
                ):
                    auto_vel_vmin = float(np.nanmin(valid_vel0))
                    auto_vel_vmax = float(np.nanmax(valid_vel0))

        use_vel_vmin = (
            args.vel_vmin
            if args.vel_vmin is not None
            else (
                fixed_vel_vmin
                if fixed_vel_vmin is not None
                else auto_vel_vmin
            )
        )
        use_vel_vmax = (
            args.vel_vmax
            if args.vel_vmax is not None
            else (
                fixed_vel_vmax
                if fixed_vel_vmax is not None
                else auto_vel_vmax
            )
        )

        user_left_vmin: float | None
        user_left_vmax: float | None
        if left_field_key == "D2":
            user_left_vmin = args.d2_vmin
            user_left_vmax = args.d2_vmax
        else:
            user_left_vmin = args.tra_vmin
            user_left_vmax = args.tra_vmax

        fixed_left_vmin, fixed_left_vmax = default_limits_for_field(left_field_key)
        need_auto_left = (user_left_vmin is None and fixed_left_vmin is None) or (
            user_left_vmax is None and fixed_left_vmax is None
        )
        auto_left_vmin, auto_left_vmax = None, None
        if need_auto_left:
            valid_left0 = left0.compressed()
            if valid_left0.size:
                auto_left_vmin = float(np.percentile(valid_left0, 2.0))
                auto_left_vmax = float(np.percentile(valid_left0, 98.0))
                if (
                    not np.isfinite(auto_left_vmin)
                    or not np.isfinite(auto_left_vmax)
                    or auto_left_vmin == auto_left_vmax
                ):
                    auto_left_vmin = float(np.nanmin(valid_left0))
                    auto_left_vmax = float(np.nanmax(valid_left0))

        use_left_vmin = (
            user_left_vmin
            if user_left_vmin is not None
            else (
                fixed_left_vmin
                if fixed_left_vmin is not None
                else auto_left_vmin
            )
        )
        use_left_vmax = (
            user_left_vmax
            if user_left_vmax is not None
            else (
                fixed_left_vmax
                if fixed_left_vmax is not None
                else auto_left_vmax
            )
        )

        render_snapshots(
            snapshots=snapshots,
            case_dir=case_dir,
            frames_dir=frames_dir,
            facet_bin=facet_bin,
            data_bin=data_bin,
            args=args,
            left_field_key=left_field_key,
            vel_vmin=use_vel_vmin,
            vel_vmax=use_vel_vmax,
            left_vmin=use_left_vmin,
            left_vmax=use_left_vmax,
            worker_cache_root=worker_cache_root,
        )

        if args.skip_video:
            print(f"Frames written to: {frames_dir}", file=sys.stderr)
            return 0

        fps = (
            float(args.fps)
            if args.fps is not None
            else (len(snapshots) / args.duration)
        )
        fps = max(1e-6, fps)
        fps_str = format_fps(fps)

        # Matches requested ffmpeg style:
        # ffmpeg -framerate <fps> -pattern_type glob -i 'Video/*.png'
        #   -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" -c:v libx264 -r <fps> -pix_fmt yuv420p out.mp4
        cmd = [
            args.ffmpeg,
            "-y",
            "-framerate",
            fps_str,
            "-pattern_type",
            "glob",
            "-i",
            str(frames_dir / "*.png"),
            "-vf",
            "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-c:v",
            "libx264",
            "-r",
            fps_str,
            "-pix_fmt",
            "yuv420p",
            str(out_path),
        ]
        subprocess.run(cmd, check=True)
        print(
            f"Wrote video: {out_path} | fps={fps_str} | frames={len(snapshots)} | duration~{args.duration}s",
            file=sys.stderr,
        )
        return 0

    except subprocess.CalledProcessError as exc:
        print(
            f"Command failed with exit code {exc.returncode}: {exc.cmd}",
            file=sys.stderr,
        )
        return 2
    except Exception as exc:  # noqa: BLE001
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    finally:
        for obj in temp_objects:
            obj.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
