#!/bin/bash
# Checks that every library the IINA app needs is inside it, before Custom Rebase installs it.
#
# other/download_libs.sh downloads the libraries of the next IINA version, not those of the tag being
# built. On 2026-11-25 the new set added libssl.4.dylib, which the 1.5.1 project does not copy into
# the app: the build succeeded, but the installed app could not be opened ("Library not loaded").
#
# Usage: custom/check_bundle_dylibs.sh [path/to/IINA.app]
# Exits with 1 and lists the missing libraries if any is missing.

app="${1:-build/DerivedData/Build/Products/Release/IINA.app}"
contents="$app/Contents"
frameworks="$contents/Frameworks"

if [ ! -x "$contents/MacOS/IINA" ]; then
  echo "No IINA app at $app" >&2
  exit 1
fi

missing=$(
  for file in "$contents/MacOS/IINA" "$frameworks"/*.dylib; do
    otool -L "$file" | awk 'NR > 1 { print $1 }' | grep '^@rpath/' | sed 's|^@rpath/||'
  done | sort -u | while read -r library; do
    # Frameworks are referenced as Name.framework/Versions/A/Name.
    [ -e "$frameworks/$library" ] || [ -e "$frameworks/${library%%/*}" ] || echo "$library"
  done
)

if [ -n "$missing" ]; then
  echo "Libraries missing from $app:" >&2
  echo "$missing" | sed 's/^/  /' >&2
  echo "The app would not open. Restore deps/lib from the installed app and build again." >&2
  exit 1
fi
echo "All the libraries the app needs are inside it ($(ls "$frameworks" | grep -c '\.dylib$') dylibs)."
