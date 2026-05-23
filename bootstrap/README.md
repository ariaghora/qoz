# Bootstrap

`stage1.c` is the self-contained C source for the Qoz compiler. It is
what the compiler emits when it compiles its own source
(`compiler/main.qoz`), inlined with the runtime so no separate linkage
is needed.

Anyone with a C11 compiler can rebuild the compiler from scratch:

```
clang -std=c11 -pedantic -Wall -Wno-unused-function -Wno-unused-variable \
      -Wno-unused-but-set-variable -Wno-unused-const-variable \
      -Wno-parentheses-equality -Wno-unused-value -Wno-overlength-strings \
      bootstrap/stage1.c -o stage0
```

The resulting `stage0` binary accepts `stage0 <path>` and emits
`<path>.c`. Run `stage0 compiler/main.qoz`, then clang the resulting
`compiler/main.qoz.c` to produce a fresh `qoz` binary. The Makefile at
the repo root automates this:

```
make            # produce ./qoz
make test       # run the regression suite
make self-host  # build qoz, then run the stage-2 self-host gate
```

The file is regenerated whenever the live compiler source changes
meaningfully. Treat it as a checked-in build artifact, not a
hand-written source file. The `make refresh-bootstrap` target rebuilds
it from the current source.
