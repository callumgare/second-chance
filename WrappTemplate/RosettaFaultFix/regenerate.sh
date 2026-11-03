#!/usr/bin/env bash
# Rebuilds fault_fix.c's machine code and prints it as the Swift array
# RosettaFaultFix.swift embeds (paste it over `RosettaFaultFix.code`). Needs
# MinGW (`brew install mingw-w64`); a normal build doesn't, as the bytes are
# committed.
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

i686-w64-mingw32-gcc -O2 -ffreestanding -fno-jump-tables -fno-asynchronous-unwind-tables \
    -fno-stack-protector -c fault_fix.c -o "$out/fault_fix.o"

# The bytes are copied into ntdll as they are, so nothing may need relocating.
if i686-w64-mingw32-objdump -r "$out/fault_fix.o" | grep -qE 'DIR32|REL32'; then
    echo "fault_fix.c compiled to code with relocations: it can't use globals, calls or jump tables" >&2
    exit 1
fi

i686-w64-mingw32-objcopy -O binary -j .text "$out/fault_fix.o" "$out/fault_fix.bin"
xxd -i < "$out/fault_fix.bin" | sed 's/^ */        /'
