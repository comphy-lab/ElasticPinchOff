/**
# getFacet-threePhase.c

Extract `f` interface facets from a saved snapshot.

## Purpose

Restore a snapshot and emit line segments from `output_facets(f, ...)`.
The output is written to `stderr` in Basilisk's facet text format.

## Build Example

```bash
qcc -Wall -O2 postProcess/getFacet-threePhase.c -o getFacet -lm
```
*/

#include "utils.h"
#include "output.h"
#include "fractions.h"

scalar f[];
char filename[80];

/**
## main()

Usage:
`./getFacet-threePhase snapshot`
#### Arguments

- `snapshot`: Basilisk dump/snapshot file to restore.

#### Returns

`0` after writing facet segments to `stderr`.
*/
int main(int a, char const *arguments[]){
  if (a < 2) {
    fprintf(ferr, "Usage: %s snapshot\n", arguments[0]);
    return 1;
  }

  sprintf(filename, "%s", arguments[1]);
  restore (file = filename);

  FILE * fp = ferr;
  output_facets(f,fp);
  fflush (fp);
  fclose (fp);
}
