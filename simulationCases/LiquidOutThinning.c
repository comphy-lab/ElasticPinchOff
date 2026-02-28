/**
# 1 is the VE liquid and 2 is the Newtonian gas.
*/

#include "axi.h"
#include "navier-stokes/centered.h"
#include "log-conform-viscoelastic-scalar-2D.h"

#define FILTERED // Smear density and viscosity jumps
#include "two-phaseVE.h"

// #include "log-conform.h" // main version
#include "navier-stokes/conserving.h"
#include "tension.h"
#include "distance.h"
#include "params.h"

#define SNAP_INTERVAL (1e-3)
// Error tolerances
#define fErr (1e-3)   // error tolerance in f1 VOF
#define KErr (1e-6)   // error tolerance in VoF curvature (height-function method)
#define VelErr (1e-3) // velocity error tolerance
#define AErr (1e-3)   // conformation error tolerance in liquid

#define epsilon (0.05)

// boundary conditions
u.n[top] = neumann(0.);
p[top] = dirichlet(0.);

int MAXlevel, CaseNo;
double Oh, Oha, De, Ec, tmax;
char nameOut[128], dumpFile[128], logFile[128];

int main (int argc, char const *argv[])
{
  const char *paramFile = NULL;

  stokes = true;
  params_init_from_argv(argc, argv);

  if (argc > 1)
    paramFile = argv[1];

  CaseNo = param_int("CaseNo", 1000);
  MAXlevel = param_int("MAXlevel", 12);
  tmax = param_double("tmax", 2e2);

  Oh = param_double("Oh", 1e0);
  Oha = param_double("Oha", 1e-2 * Oh);
  De = param_double("De", 1e30);
  Ec = param_double("Ec", 1e0);
  dtmax = param_double("dtmax", 1e-5); // BEWARE of this for stability issues.

  if (CaseNo < 1000 || MAXlevel <= 0 || Oh <= 0. || Oha < 0. ||
      De < 0. || Ec < 0. || tmax <= 0. || dtmax <= 0. || dtmax > tmax) {
    fprintf(ferr, "ERROR: Invalid runtime parameters.\n");
    return 1;
  }

  L0 = 2*pi;
  init_grid(1 << 8);

  // Create a folder where all simulation snapshots are stored.
  system("mkdir -p intermediate");

  // Name of the restart file. See writingFiles event.
  sprintf(dumpFile, "dump");
  sprintf(logFile, "c%d-log", CaseNo);

  rho1 = 1.; rho2 = 1e-3;
  mu1 = Oh; mu2 = Oha;
  G1 = Ec; G2 = 0.0;
  lambda1 = De; lambda2 = 0.0;

  f.sigma = 1.0;

  TOLERANCE = 1e-4;
  CFL = 0.5;

  if (pid() == 0) {
    fprintf(ferr, "CaseNo=%d MAXlevel=%d De=%g Ec=%g Oh=%g tmax=%g dtmax=%g\n",
            CaseNo, MAXlevel, De, Ec, Oh, tmax, dtmax);
    if (paramFile != NULL)
      fprintf(ferr, "Loaded parameters from %s\n", paramFile);
    fprintf(ferr, "Logging to %s\n", logFile);
  }

  run();
}

event init (t = 0)
{
  if (!restore(file = dumpFile))
    fraction(f, -(1 - epsilon*sin(x/4) - y));
}

/**
## Adaptive Mesh Refinement
*/
event adapt (i++)
{
  scalar KAPPA[];
  curvature(f, KAPPA);
  adapt_wavelet((scalar *) {f, u.x, u.y, A11, A22, A12, AThTh, KAPPA},
                (double []) {fErr, VelErr, VelErr, AErr, AErr, AErr, AErr, KErr},
                MAXlevel, 6);
}

/**
## Dumping snapshots
*/
event writingFiles (t = 0; t += SNAP_INTERVAL; t <= tmax)
{
  dump(file = dumpFile);
  sprintf(nameOut, "intermediate/snapshot-%5.4f", t);
  dump(file = nameOut);
}

/**
## Ending Simulation
*/
event stopSimulation (t = tmax)
{
  if (pid() == 0)
    fprintf(ferr, "Case %d complete. Level %d, De %2.1e, Ec %2.1e, Oh %2.1e\n",
            CaseNo, MAXlevel, De, Ec, Oh);
  return 1;
}

/**
## Log writing
*/
scalar Y[];

event logWriting (i++)
{
  double ke = 0.;
  FILE *fp = NULL;
  foreach (reduction(+:ke))
    ke += (2*pi*y)*(0.5*rho(f[])*(sq(u.x[]) + sq(u.y[])))*sq(Delta);

  position(f, Y, {0, 1});

  if (pid() == 0) {
    if (i == 0) {
      fprintf(ferr, "i dt t ke hm vm\n");
      fp = fopen(logFile, "w");
      if (fp == NULL) {
        fprintf(ferr, "ERROR: cannot open log file %s\n", logFile);
        exit(1);
      }
      fprintf(fp, "CaseNo %d, Level %d, De %g, Ec %g, Oh %g, Oha %g\n",
              CaseNo, MAXlevel, De, Ec, Oh, Oha);
      fprintf(fp, "i dt t ke hm vm\n");
      fprintf(fp, "%d %g %g %g %6.5e %6.5e\n", i, dt, t, ke, statsf(Y).min, normf(u.x).max);
      fclose(fp);
    } else {
      fp = fopen(logFile, "a");
      if (fp == NULL) {
        fprintf(ferr, "ERROR: cannot open log file %s\n", logFile);
        exit(1);
      }
      fprintf(fp, "%d %g %g %g %6.5e %6.5e\n", i, dt, t, ke, statsf(Y).min, normf(u.x).max);
      fclose(fp);
    }
    fprintf(ferr, "%d %g %g %g %6.5e %6.5e\n", i, dt, t, ke, statsf(Y).min, normf(u.x).max);

    assert(ke > -1e-10);

    if (ke > 1e2 && i > 1e1) {
      fprintf(ferr, "The kinetic energy blew up. Stopping simulation\n");
      fp = fopen(logFile, "a");
      if (fp != NULL) {
        fprintf(fp, "The kinetic energy blew up. Stopping simulation\n");
        fclose(fp);
      }
      dump(file = dumpFile);
      return 1;
    }
    if (ke < 1e-8 && i > 1e1) {
      fprintf(ferr, "Kinetic energy too small now. Stopping simulation\n");
      dump(file = dumpFile);
      fp = fopen(logFile, "a");
      if (fp != NULL) {
        fprintf(fp, "Kinetic energy too small now. Stopping simulation\n");
        fclose(fp);
      }
      return 1;
    }
  }
}
