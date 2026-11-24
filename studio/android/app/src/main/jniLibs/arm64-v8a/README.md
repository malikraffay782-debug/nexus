Place native libraries here (static proot):

- libproot.so
- libproot-loader.so
- libproot-loader32.so (optional)

Static proot (green-green-avk / Termux) links talloc in; do **not** ship
libtalloc.so or libandroid-shmem.so — they are unused and were removed (B29).

These must come from scripts/ci-prepare-runtime.sh or a trusted build.
