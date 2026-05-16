#!/bin/bash
cd /home/qfh/curb-build/karo-tx-linux/include/linux

# Hent originale fra git for å reverse våre dårlige edits
echo "=== Reset compiler-gcc*.h til original git-versjon ==="
cd /home/qfh/curb-build/karo-tx-linux
git checkout HEAD -- include/linux/compiler-gcc.h 2>&1 || echo "git checkout feilet"
cd include/linux

# Fjern våre dårlige symlinker
for n in 5 6 7 8 9 10 11 12 13 14 15; do
  rm -f "compiler-gcc${n}.h"
done

# Bekreft hva som er originalt
echo "=== Etter cleanup: ==="
ls -la compiler-gcc*.h

# Lag nye symlinker — alle nyere GCC peker mot compiler-gcc4.h (den eldste vi har innhold for)
for n in 5 6 7 8 9 10 11 12 13 14 15; do
  ln -sf compiler-gcc4.h "compiler-gcc${n}.h"
done

echo "=== Etter fix: ==="
ls -la compiler-gcc*.h

# Sjekk at compiler-gcc.h finnes (dispatcher)
if [ ! -e compiler-gcc.h ]; then
  echo "ADVARSEL: compiler-gcc.h mangler! Bruker git checkout..."
  cd /home/qfh/curb-build/karo-tx-linux
  git checkout HEAD -- include/linux/compiler-gcc.h
fi
