# Bootstrap

`stage1.c` is the self-contained C source for the Qoz-v2 compiler. It
is what Stage B emits when it compiles its own source (`compiler/main.qoz`),
inlined with the runtime so no separate linkage is needed.

Anyone with a C11 compiler can rebuild the compiler from scratch
without the Stage A Odin toolchain:

```
clang -std=c11 -pedantic -Wall -Wno-unused-function -Wno-unused-variable \
      -Wno-unused-but-set-variable -Wno-unused-const-variable \
      -Wno-parentheses-equality -Wno-unused-value -Wno-overlength-strings \
      bootstrap/stage1.c -o stage1
```

The resulting `stage1` binary accepts a `compile compiler/main.qoz` style
invocation. It will emit a new `compiler/main.qoz.c` and report the C
file path. Compile that file the same way to obtain a fresh compiler
binary. That binary is byte-equivalent (modulo runtime header diffs)
to a build produced from the Odin Stage A.

The file is regenerated whenever Stage B's source changes meaningfully.
Treat it as a checked-in build artifact rather than a hand-written
source file. Edit `compiler/*.qoz`, run `./main compiler/main.qoz`,
and copy the resulting `compiler/main.qoz.c` here.
