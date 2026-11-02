#!/usr/bin/env bash
# Sourced by the setup-*.sh build scripts: one way to fetch a pinned download
# into ~/Library/Caches/SecondChance and check it is the file we tested with.
#
# fetch_verified <url> <cache file> <sha256>
#   Downloads <url> to <cache file> unless a copy with the right SHA-256 is
#   already there. A cached copy with the wrong hash (an old error page, a
#   half-written file, an upstream re-upload) is thrown away and fetched again.
#   Fails, and leaves nothing in the cache, if the download doesn't match.
#
# Name the cache file after the version (or the URL's own versioned name), so
# that changing the URL never reuses whatever was cached before.

sha256_of() {
    /usr/bin/shasum -a 256 "$1" | cut -d' ' -f1
}

fetch_verified() {
    local url="$1" dest="$2" expected="$3"

    if [ -f "$dest" ]; then
        if [ "$(sha256_of "$dest")" = "$expected" ]; then
            echo "✓ Using cached $(basename "$dest")"
            return 0
        fi
        echo "⚠️  Cached $(basename "$dest") doesn't match its pinned SHA-256; downloading it again"
        rm -f "$dest"
    fi

    echo "📥 Downloading $(basename "$dest")..."
    mkdir -p "$(dirname "$dest")"
    # -f: an HTTP error fails rather than saving the error page as the file.
    if ! curl -fL --retry 2 -o "$dest.tmp" "$url"; then
        rm -f "$dest.tmp"
        echo "❌ Couldn't download $url"
        return 1
    fi

    local actual
    actual="$(sha256_of "$dest.tmp")"
    if [ "$actual" != "$expected" ]; then
        rm -f "$dest.tmp"
        echo "❌ $url has SHA-256 $actual, expected $expected"
        return 1
    fi

    mv "$dest.tmp" "$dest"
    echo "✓ Downloaded $(basename "$dest")"
}
