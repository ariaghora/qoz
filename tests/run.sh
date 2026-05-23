#!/bin/bash
# Regression runner. Expects to be invoked from the repo root.
#
# tests/tokenizer/* and tests/parser/*: must compile and run with exit 0.
# tests/typecheck/*: must FAIL compilation. Output is not checked beyond that.

set -u

# Resource caps inherited by every child process. A runaway compiler
# invocation can otherwise grow without bound: see the parser hang on
# unhandled function types. These caps trade a hard fail for a hung laptop.
ulimit -d 1048576 2>/dev/null || true   # data segment: 1 GB
ulimit -t 30 2>/dev/null || true        # CPU seconds: 30 per child

# Stage B (./main) is the active compiler. When it is missing the
# runner builds it from bootstrap/stage1.c via clang. Two further
# fall-backs exist for development: the live Stage B source in
# compiler/main.qoz (compiled by an existing ./main), and the
# archived Stage A.
STAGE_B="$PWD/main"
if [ ! -x "$STAGE_B" ] && [ -f bootstrap/stage1.c ]; then
    clang -std=c11 -pedantic -Wall \
          -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable \
          -Wno-unused-const-variable -Wno-parentheses-equality -Wno-unused-value \
          -Wno-overlength-strings \
          bootstrap/stage1.c -o "$STAGE_B" >/dev/null 2>&1
fi
if [ ! -x "$STAGE_B" ] && [ -x ./archive/qoz-stage-a/stage_a/stage_a.exe ]; then
    ./archive/qoz-stage-a/stage_a/stage_a.exe build compiler/main.qoz >/dev/null 2>&1
fi
if [ ! -x "$STAGE_B" ]; then
    echo "Stage B binary (./main) not found, no bootstrap/stage1.c, no Stage A."
    exit 2
fi
QOZ="$STAGE_B"

PASS=0
FAIL=0
fails=()

# Positive: Stage B compiles, links, and runs. The binary must exit 0.
# Some tests (e.g. let_else) exercise features Stage B does not yet
# support. They carry the marker `// stage-b-skip` on the first line
# and the runner skips them so the suite still represents what works.
run_pos() {
    local t="$1"
    if head -1 "$t" | grep -q 'stage-b-skip'; then
        return 0
    fi
    out=$(QOZ_ROOT="$PWD" "$QOZ" run "$t" 2>&1)
    rc=$?
    rm -f "${t}.c" "${t}.bin"
    if [ $rc -ne 0 ]; then
        FAIL=$((FAIL+1))
        fails+=("$t (expected pass; exit $rc; $out)")
        return 1
    fi
    PASS=$((PASS+1))
}

run_neg() {
    local t="$1"
    out=$(QOZ_ROOT="$PWD" "$QOZ" emit "$t" 2>&1)
    rc=$?
    rm -f "${t}.c"
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

# Stage B integration tests: compile each source through Stage B's
# emit, link with clang under -Wall -Werror, and check the binary's
# exit code against the value declared in the file's `// expect: N`
# header line.
if true; then
    # Stage B's emitted .c is self-contained (runtime baked in via
    # #load_string in emit.qoz), so no extra object files or -I needed.

    run_stage_b_pos() {
        local t="$1"
        local expect
        expect=$(head -1 "$t" | awk '/^\/\/ expect: [0-9]+/{print $3; exit}')
        if [ -z "$expect" ]; then
            FAIL=$((FAIL+1))
            fails+=("$t (missing // expect: header)")
            return 1
        fi
        out=$(QOZ_ROOT="$PWD" "$STAGE_B" emit "$t" 2>&1)
        rc=$?
        if [ $rc -ne 0 ]; then
            FAIL=$((FAIL+1))
            fails+=("$t (Stage B failed: $out)")
            return 1
        fi
        bin=$(mktemp -t qozb.XXXXXX)
        if ! clang -std=c11 -pedantic -Wall -Werror -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-const-variable -Wno-parentheses-equality -Wno-unused-value -Wno-overlength-strings "${t}.c" -o "$bin" >/tmp/qozb_clang.log 2>&1; then
            FAIL=$((FAIL+1))
            fails+=("$t (clang failed; see /tmp/qozb_clang.log)")
            rm -f "$bin" "${t}.c"
            return 1
        fi
        "$bin"
        rc=$?
        rm -f "$bin" "${t}.c"
        if [ "$rc" != "$expect" ]; then
            FAIL=$((FAIL+1))
            fails+=("$t (exit $rc, expected $expect)")
            return 1
        fi
        PASS=$((PASS+1))
    }

    run_stage_b_neg() {
        local t="$1"
        out=$(QOZ_ROOT="$PWD" "$STAGE_B" emit "$t" 2>&1)
        rc=$?
        rm -f "${t}.c"
        if [ $rc -eq 0 ]; then
            FAIL=$((FAIL+1))
            fails+=("$t (expected rejection, exit 0)")
            return 1
        fi
        PASS=$((PASS+1))
    }

    for t in tests/stage_b/*.qoz; do
        [ -f "$t" ] || continue
        run_stage_b_pos "$t"
    done

    for t in tests/stage_b_neg/*.qoz; do
        [ -f "$t" ] || continue
        run_stage_b_neg "$t"
    done

    for t in tests/stage_b_gaps/*.qoz; do
        [ -f "$t" ] || continue
        run_stage_b_pos "$t"
    done
fi

rm -f *.qoz.c 2>/dev/null

if [ ${#fails[@]} -gt 0 ]; then
    echo
    echo "FAILED:"
    for f in "${fails[@]}"; do echo "  $f"; done
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
exit $FAIL
