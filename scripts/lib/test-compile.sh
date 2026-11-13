#!/bin/sh
# Runs inside a JupyDo image, offline: compiles and runs a C and a Fortran program.
set -e
cd "$(mktemp -d)"
cat > t.c <<'EOF_C'
#include <stdio.h>
int main(void) { printf("%d\n", 6 * 7); return 0; }
EOF_C
cat > t.f90 <<'EOF_F'
program t
  print '(i0)', 6 * 7
end program t
EOF_F
gcc t.c -o t_c && ./t_c
gfortran t.f90 -o t_f && ./t_f
