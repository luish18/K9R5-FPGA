#!/bin/sh
# Point ara/install and spatz/install (both git-ignored) at the prebuilt
# toolchains, in the repo mounted at the working directory.
for p in ara spatz; do
    if [ -d "$PWD/$p" ] && [ ! -e "$PWD/$p/install" ]; then
        ln -s "/opt/$p/install" "$PWD/$p/install"
    fi
done
# Source Vivado if a host install is mounted
for s in /tools/Xilinx/Vivado/*/settings64.sh; do
    [ -f "$s" ] && . "$s"
done
exec "$@"
