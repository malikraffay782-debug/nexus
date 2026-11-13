# Optional C++17 samples for Nexus

Header-only assets (C++17). Requires optional clang++ toolchain from Settings → Languages.

Build example (after Install C++17):

```
clang++ -std=c++17 -O2 -DGA_DEMO_MAIN -x c++ GameAssets.hpp -o /tmp/ga_demo
```

`GameAssets.hpp` is engine-agnostic mesh/particle generators (sword, crates, effects).

