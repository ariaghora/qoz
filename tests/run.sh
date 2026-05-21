#!/bin/bash
# Regression runner. Expects to be invoked from the repo root.
#
# tests/tokenizer/* and tests/parser/*: must compile and run with exit 0.
# tests/typecheck/*: must FAIL compilation. Output is not checked beyond that.

set -u

QOZ="./stage_a/stage_a.exe"
if [ ! -x "$QOZ" ]; then
    echo "$QOZ not found. Build with: cd stage_a && odin build . -out:stage_a.exe -debug"
    exit 2
fi

PASS=0
FAIL=0
fails=()

run_pos() {
    local t="$1"
    out=$("$QOZ" run "$t" 2>&1)
    rc=$?
    if [ $rc -ne 0 ] || echo "$out" | grep -q "error"; then
        FAIL=$((FAIL+1))
        fails+=("$t (expected pass)")
        return 1
    fi
    PASS=$((PASS+1))
}

run_neg() {
    local t="$1"
    out=$("$QOZ" run "$t" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        FAIL=$((FAIL+1))
        fails+=("$t (expected fail, exit 0)")
        return 1
    fi
    PASS=$((PASS+1))
}

for t in tests/tokenizer/*.qoz tests/parser/*.qoz; do
    [ -f "$t" ] || continue
    run_pos "$t"
done

for t in tests/typecheck/*.qoz; do
    [ -f "$t" ] || continue
    run_neg "$t"
done

rm -f *.qoz.c 2>/dev/null

if [ ${#fails[@]} -gt 0 ]; then
    echo
    echo "FAILED:"
    for f in "${fails[@]}"; do echo "  $f"; done
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
exit $FAIL
