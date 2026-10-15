#!/bin/sh
# Point ara/install and spatz/install (both git-ignored) at the prebuilt toolchains.
for p in ara spatz; do
    if [ -d "/work/$p" ] && [ ! -e "/work/$p/install" ]; then
        ln -s "/opt/$p/install" "/work/$p/install"
    fi
done
# Source Vivado if a host install is mounted
for s in /tools/Xilinx/Vivado/*/settings64.sh; do
    [ -f "$s" ] && . "$s"
done
exec "$@"
