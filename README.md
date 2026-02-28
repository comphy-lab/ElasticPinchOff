# ElasticPinchOff

Axisymmetric viscoelastic pinch-off simulation using Basilisk.

## Layout

- `simulationCases/` simulation entry points and generated case folders (`<CaseNo>/`)
- `src-local/` project-specific Basilisk headers
  - `params.h` hyphal-flow style runtime API: `params_init_from_argv`, `param_int`, `param_double`
  - `parse_params.h` low-level key/value loading used by `params.h`
- `runSimulation.sh` single-case compile/run driver
- `runParameterSweep.sh` sweep driver that generates per-case parameter files
- `default.params` base parameters for `LiquidOutThinning.c`
- `sweep.params` example sweep over `Ec`, `De`, and `tmax`

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
The log file is written as `c<CaseNo>-log` (for example: `c42-log`).

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
