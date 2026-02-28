# ElasticPinchOff

Axisymmetric viscoelastic pinch-off simulation using Basilisk.

## Layout

```text
|-- basilisk/ - Local Basilisk checkout (ignored; do not commit)
|-- simulationCases/ - Simulation entry points and generated case outputs
|   `-- LiquidOutThinning.c - Axisymmetric viscoelastic pinch-off case
|-- src-local/ - Project-specific Basilisk extensions and runtime parameter API
|   |-- parse_params.h - Low-level key/value parser for parameter files
|   |-- params.h - Typed parameter accessors (`param_int`, `param_double`, ...)
|   |-- two-phaseVE.h - Two-phase viscoelastic solver extensions
|   `-- log-conform-viscoelastic-scalar-2D.h - Log-conformation model implementation
|-- .github/ - Documentation assets, scripts, workflows, and generated site
|   |-- scripts/ - Docs build and local deploy scripts
|   |-- workflows/ - GitHub Actions workflows (Pages deploy and search sync)
|   |-- assets/ - Static CSS/JS/logos/template for the docs site
|   `-- docs/ - Generated HTML documentation output
|-- runSimulation.sh - Single-case compile/run driver
|-- runParameterSweep.sh - Parameter sweep driver
|-- default.params - Base runtime parameters for single-case runs
|-- sweep.params - Example sweep definition (`SWEEP_*`, `CASE_START`, `CASE_END`)
|-- display.html - Local visualization helper
|-- LICENSE - Project license
`-- README.md - Project overview and usage
```

## Requirements

- Basilisk `qcc` available in `PATH`
- Optional for MPI runs: `mpicc`, `mpirun`
- Optional local environment bootstrap: `.project_config` in repo root

## Single Case Run

```bash
bash runSimulation.sh default.params
```

Optional:

```bash
bash runSimulation.sh default.params --mpi --CPUs 8
```

The case is executed in `simulationCases/<CaseNo>/`.
The log file is written as `c<CaseNo>-log` (for example: `c1000-log`).

## Parameter Sweep

```bash
bash runParameterSweep.sh sweep.params
```

Preview generated combinations only:

```bash
bash runParameterSweep.sh sweep.params --dry-run
```

`runParameterSweep.sh` reads `SWEEP_*` entries, creates temporary case parameter files, injects `CaseNo`, then runs each case via `runSimulation.sh`.

## Parameter File Keys

`LiquidOutThinning.c` currently reads these keys from a `key=value` file:

- `CaseNo`
- `MAXlevel`
- `Oh`
- `Oha` (optional; defaults to `1e-2*Oh` if omitted)
- `De`
- `Ec`
- `tmax`
- `dtmax`

For sortable case folders, use `CaseNo >= 1000` (e.g., `1000`, `1001`, ...).

## Documentation Website and CI

The repository includes CoMPhy's docs/CI bundle under `.github/`.

Build documentation locally:

```bash
bash .github/scripts/build.sh
```

Preview generated docs locally:

```bash
bash .github/scripts/deploy.sh
```

This project uses the committed docs model:
- generated site files live in `.github/docs/`,
- the GitHub Pages deploy workflow triggers on changes to `.github/docs/**` on `main`.

For GitHub Pages, set:
- Settings -> Pages -> Source: `GitHub Actions`.
