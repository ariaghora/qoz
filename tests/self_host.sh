#!/bin/bash
# Self-host gate. The deliverable check.
#
# Build stage-2 from the live source using the current ./main, then
# run the full test suite against stage-2. Any regression here means
# the compiler can no longer build itself correctly.
#
# Sequence:
#   1. Insist ./main exists. The runner does not synthesise it; the
#      caller should have built it from bootstrap/stage1.c, the
#      archived Stage A, or a previous self-host cycle.
#   2. Use ./main to emit a fresh compiler/main.qoz.c.
#   3. Clang that .c to ./stage2.
#   4. Swap stage2 into the position of ./main and run tests/run.sh.
#   5. Restore the original ./main.
#
# A non-zero exit means stage-2 does not match the deliverable.

set -u

REPO="$PWD"

if [ ! -x "$REPO/main" ]; then
    echo "self-host: ./main not present. Build it first:"
    echo "    clang -std=c11 -pedantic -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-const-variable -Wno-parentheses-equality -Wno-unused-value -Wno-overlength-strings bootstrap/stage1.c -o main"
    exit 2
fi

echo "self-host: emitting stage-2 .c from compiler/main.qoz via ./main"
QOZ_ROOT="$REPO" ./main compiler/main.qoz
if [ $? -ne 0 ]; then
    echo "self-host: ./main failed to emit compiler/main.qoz.c"
    exit 1
fi

echo "self-host: building stage-2 binary"
clang -std=c11 -pedantic -Wall -Werror \
      -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable \
      -Wno-unused-const-variable -Wno-parentheses-equality -Wno-unused-value \
      -Wno-overlength-strings \
      compiler/main.qoz.c -o stage2
if [ $? -ne 0 ]; then
    echo "self-host: clang failed on the stage-2 .c"
    exit 1
fi

echo "self-host: swapping stage2 in for ./main and running the suite"
cp main main.bak
cp stage2 main
bash tests/run.sh
RC=$?

# Restore. Always, even on failure, so the developer keeps a working
# ./main in place.
cp main.bak main
rm -f main.bak

if [ "$RC" -ne 0 ]; then
    echo "self-host: stage-2 failed the suite (exit $RC)"
    exit "$RC"
fi

echo "self-host: stage-2 passes the suite"
