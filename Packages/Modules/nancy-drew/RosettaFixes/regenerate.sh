#!/usr/bin/env bash
# Rebuilds the nancy-drew module's assets/rosetta-fixes/comdlg32.dll from
# rosetta_fixes.c, with libogg and libvorbis compiled for SSE2 (never the x87,
# which Rosetta runs in software). Needs MinGW (`brew install mingw-w64`); a
# normal build doesn't, as the DLL is committed. Raise the module's release
# after committing a new one. docs/modules.md#rosetta-fixes has why.
set -euo pipefail
cd "$(dirname "$0")"
here="$PWD"
dest="$here/../../../../Modules/nancy-drew/assets/rosetta-fixes/comdlg32.dll"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() { # url sha256
    local file="$work/$(basename "$1")"
    curl -sSfL "$1" -o "$file"
    echo "$2  $file" | shasum -a 256 -c --quiet
    tar xzf "$file" -C "$work"
}
fetch https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz \
    0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664
fetch https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz \
    0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab
ogg="$work/libogg-1.3.5"
vorbis="$work/libvorbis-1.3.7"

# What libogg's configure would write for this target.
mkdir -p "$work/gen/ogg"
cat > "$work/gen/ogg/config_types.h" <<'EOF'
#ifndef __CONFIG_TYPES_H__
#define __CONFIG_TYPES_H__
#include <stdint.h>
typedef int16_t ogg_int16_t;
typedef uint16_t ogg_uint16_t;
typedef int32_t ogg_int32_t;
typedef uint32_t ogg_uint32_t;
typedef int64_t ogg_int64_t;
typedef uint64_t ogg_uint64_t;
#endif
EOF

# SSE2 for every float, and no assumption that the game's 4-byte-aligned
# stack is 16-byte aligned when it calls in.
flags=(-O2 -msse2 -mfpmath=sse -mincoming-stack-boundary=2 -fno-strict-aliasing
       -DNDEBUG -I"$work/gen" -I"$ogg/include" -I"$vorbis/include" -I"$vorbis/lib")
sources=("$ogg/src/framing.c" "$ogg/src/bitwise.c")
for file in mdct smallft block envelope window lsp lpc analysis synthesis psy info \
            floor1 floor0 res0 mapping0 registry codebook sharedbook lookup bitrate vorbisfile; do
    sources+=("$vorbis/lib/$file.c")
done
i686-w64-mingw32-gcc "${flags[@]}" -w -shared -static-libgcc -o "$work/comdlg32.dll" \
    "$here/rosetta_fixes.c" "${sources[@]}" "$here/comdlg32.def" -Wl,--enable-stdcall-fixup

# Nothing on the decoding path may use the x87: that is what's slow. Elsewhere
# it can't all go: a 32-bit function returns a float on the x87 stack, and
# setup (codebooks, MDCT tables), the encoder, the time functions and floor0
# (which no encoder has used since 2002) keep a few. So each decoding
# function is checked for none.
decoding='mdct_backward|floor1_inverse|res[0-9]_inverse|_01inverse|_2inverse|vorbis_book_decode|decode_packed_entry|vorbis_synthesis|mapping0_inverse|apply_window|render_line|ov_read|_ov_getlap|vorbis_ftoi|ogg_'
x87="$(i686-w64-mingw32-objdump -d "$work/comdlg32.dll" | awk -v decoding="$decoding" '
    /^[0-9a-f]+ <.*>:$/ { name = $2; hot = name ~ decoding; next }
    hot && /\tf(ld|st|add|sub|mul|div|ild|ist|xch|chs|abs|sqrt|com|ucom)[a-z]*[ \t]/ { print name }' | sort | uniq -c)"
if [ -n "$x87" ]; then
    printf 'x87 instructions on the decoding path, which must be SSE2:\n%s\n' "$x87" >&2
    exit 1
fi
i686-w64-mingw32-strip "$work/comdlg32.dll"

mkdir -p "$(dirname "$dest")"
cp "$work/comdlg32.dll" "$dest"
echo "Wrote $dest ($(wc -c < "$dest" | tr -d ' ') bytes)"
