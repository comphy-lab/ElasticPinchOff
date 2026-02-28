/**
# 1 is the VE liquid and 2 is the Newtonian gas.
*/

#include "axi.h"
#include "navier-stokes/centered.h"
#define FILTERED // Smear density and viscosity jumps
#include "two-phaseVE.h"

// #include "log-conform.h" // main version
#include "log-conform-viscoelastic-scalar-2D.h"
#include "navier-stokes/conserving.h"
#include "tension.h"
#include "distance.h"

#define tsnap (1e-3)
// Error tolerancs
#define fErr (1e-3)                                 // error tolerance in f1 VOF
#define KErr (1e-6)                                 // error tolerance in VoF curvature calculated using heigh function method (see adapt event)
#define VelErr (1e-3)                               // error tolerances in velocity -- Use 1e-2 for low Oh and 1e-3 to 5e-3 for high Oh/moderate to high J
#define AErr (1e-3)                                 // error tolerances in conformation inside the liquid

#define epsilon (0.05)

// boundary conditions
u.n[top] = neumann(0.);
p[top] = dirichlet(0.);

int MAXlevel;
// Oh -> Solvent Ohnesorge number
// Oha -> air Ohnesorge number
// De -> Deborah number
// Ec -> Elasto-capillary number

double Oh, Oha, De, Ec, tmax;
char nameOut[80], dumpFile[80];

int main(int argc, char const *argv[]) {

  dtmax = 1e-5; //  BEWARE of this for stability issues.

  L0 = 2*pi;
  //origin (-L0/2., 0.);

  // Values taken from the terminal
  MAXlevel = 12;
  De = 1e30;
  Ec = 1e0;
  Oh = 1e-2;
  tmax = 200;

  init_grid (1 << 8);
  // Create a folder named intermediate where all the simulation snapshots are stored.
  char comm[80];
  sprintf (comm, "mkdir -p intermediate");
  system(comm);
  // Name of the restart file. See writingFiles event.
  sprintf (dumpFile, "dump");


  rho1 = 1., rho2 = 1e-2;
  Oha = 1e-2 * Oh;
  mu1 = Oh, mu2 = Oha;
  G1 = Ec; G2 = 0.0;
  lambda1 = De; lambda2 = 0.0;

  f.sigma = 1.0;

  run();

}


event init (t = 0) {
  if (!restore (file = dumpFile)){
   fraction (f, -(1-epsilon*sin(x/4)-y));
  }
}

/**
## Adaptive Mesh Refinement
*/
event adapt(i++){
  scalar KAPPA[];
  curvature(f, KAPPA);
   adapt_wavelet ((scalar *){f, u.x, u.y, A11, A22, A12, AThTh, KAPPA},
      (double[]){fErr, VelErr, VelErr, AErr, AErr, AErr, AErr, KErr},
      MAXlevel, 6);
}

/**
## Dumping snapshots
*/
event writingFiles (t = 0; t += tsnap; t <= tmax) {
  dump (file = dumpFile);
  sprintf (nameOut, "intermediate/snapshot-%5.4f", t);
  dump(file=nameOut);
}

/**
## Ending Simulation
*/
event end (t = end) {
  if (pid() == 0)
    fprintf(ferr, "Level %d, De %2.1e, Ec %2.1e, Oh %2.1e\n", MAXlevel, De, Ec, Oh);
}

/**
## Log writing
*/
scalar Y[];

event logWriting (i++) {
  double ke = 0.;
  foreach (reduction(+:ke)){
    ke += (2*pi*y)*(0.5*rho(f[])*(sq(u.x[]) + sq(u.y[])))*sq(Delta);
  }

  position (f, Y, {0,1});

  static FILE * fp;
  if (pid() == 0){
    if (i == 0) {
      fprintf (ferr, "i dt t ke hm vm\n");
      fp = fopen ("log", "w");
      fprintf(fp, "Level %d, De %g, Ec %g, Oh %g, Oha %g\n", MAXlevel, De, Ec, Oh, Oha);
      fprintf (fp, "i dt t ke hm vm\n");
      fprintf (fp, "%d %g %g %g %6.5e %6.5e\n", i, dt, t, ke, statsf(Y).min, normf(u.x).max);
      fclose(fp);
    } else {
      fp = fopen ("log", "a");
      fprintf (fp, "%d %g %g %g %6.5e %6.5e\n", i, dt, t, ke, statsf(Y).min, normf(u.x).max);
      fclose(fp);
    }
    fprintf (ferr, "%d %g %g %g %6.5e %6.5e\n", i, dt, t, ke, statsf(Y).min, normf(u.x).max);

    assert(ke > -1e-10);

    if (ke > 1e2 && i > 1e1){
      fprintf(ferr, "The kinetic energy blew up. Stopping simulation\n");
        fp = fopen ("log", "a");
        fprintf(fp, "The kinetic energy blew up. Stopping simulation\n");
        fclose(fp);
        dump(file=dumpFile);
        return 1;
    }
    if (ke < 1e-8 && i > 1e1){
        fprintf(ferr, "kinetic energy too small now! Stopping!\n");
        dump(file=dumpFile);
        fp = fopen ("log", "a");
        fprintf(fp, "kinetic energy too small now! Stopping!\n");
        fclose(fp);
        return 1;
    }
  }
}
