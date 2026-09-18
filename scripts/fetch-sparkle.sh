#!/bin/zsh
set -euo pipefail

# Pin both the official release and its archive digest. No unversioned downloads.
PROJECT_ROOT="${0:A:h:h}"
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
DEPENDENCIES_PATH="$PROJECT_ROOT/build/dependencies"
ARCHIVE_PATH="$DEPENDENCIES_PATH/Sparkle-$SPARKLE_VERSION.tar.xz"
SPARKLE_PATH="$DEPENDENCIES_PATH/Sparkle-$SPARKLE_VERSION"
mkdir -p "$DEPENDENCIES_PATH"

WORK_PATH=$(/usr/bin/mktemp -d "$DEPENDENCIES_PATH/.sparkle.XXXXXX")
trap '/bin/rm -rf "$WORK_PATH"' EXIT

verify_archive() {
  local archive_digest
  archive_digest=$(/usr/bin/shasum -a 256 "$1")
  [[ "${archive_digest%% *}" == "$SPARKLE_SHA256" ]]
}

if [[ ! -f "$ARCHIVE_PATH" ]] || ! verify_archive "$ARCHIVE_PATH"; then
  /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 20 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    --output "$WORK_PATH/Sparkle.tar.xz"
  if ! verify_archive "$WORK_PATH/Sparkle.tar.xz"; then
    printf 'Sparkle archive checksum did not match the pinned release.\n' >&2
    exit 1
  fi
  /bin/mv -f "$WORK_PATH/Sparkle.tar.xz" "$ARCHIVE_PATH"
fi

# Extract only verified archives, then expose the complete directory atomically.
if [[ ! -f "$SPARKLE_PATH/.archive-sha256" ]] || \
   [[ "$(<"$SPARKLE_PATH/.archive-sha256")" != "$SPARKLE_SHA256" ]] || \
   [[ ! -e "$SPARKLE_PATH/Sparkle.framework/Sparkle" ]] || \
   [[ ! -x "$SPARKLE_PATH/bin/generate_appcast" ]]; then
  mkdir "$WORK_PATH/extracted"
  /usr/bin/tar -xf "$ARCHIVE_PATH" -C "$WORK_PATH/extracted"
  if [[ ! -e "$WORK_PATH/extracted/Sparkle.framework/Sparkle" || ! -x "$WORK_PATH/extracted/bin/generate_appcast" ]]; then
    printf 'The pinned Sparkle archive has an unexpected layout.\n' >&2
    exit 1
  fi
  /usr/bin/codesign --verify --deep --strict "$WORK_PATH/extracted/Sparkle.framework"
  printf '%s\n' "$SPARKLE_SHA256" > "$WORK_PATH/extracted/.archive-sha256"
  if [[ -e "$SPARKLE_PATH" ]]; then
    /bin/mv "$SPARKLE_PATH" "$WORK_PATH/previous"
  fi
  /bin/mv "$WORK_PATH/extracted" "$SPARKLE_PATH"
fi

/usr/bin/codesign --verify --deep --strict "$SPARKLE_PATH/Sparkle.framework"
printf '%s\n' "$SPARKLE_PATH"
