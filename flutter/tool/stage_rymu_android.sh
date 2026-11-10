#!/usr/bin/env bash
set -euo pipefail

[[ $# == 3 ]] || { echo "Usage: $0 LIVE_FORK BRIDGE_FILES FRESH_LINUX_DESTINATION" >&2; exit 2; }
fork=$(realpath "$1")
bridge=$(realpath "$2")
stage=$(realpath -m "$3")
[[ ! -e "$stage" ]] || { echo "Android stage already exists: $stage" >&2; exit 2; }
case "$stage" in /mnt/*) echo 'Android stage must be in the Linux filesystem' >&2; exit 2 ;; esac

head=23e5bb471a040d62f0a6ad52591fb30784265b73
git -C "$fork" merge-base --is-ancestor "$head" HEAD || { echo "Unexpected client source revision" >&2; exit 2; }
git -c core.autocrlf=false clone --depth 1 --branch 1.5.1 https://github.com/rustdesk/rustdesk.git "$stage"
[[ $(git -C "$stage" rev-parse HEAD) == "$head" ]] || { echo "Unexpected tag revision" >&2; exit 2; }
git -C "$stage" submodule update --init --recursive

# Copy only the product source paths used by this Android build. Ignore IDE
# settings, caches, build output and all Android signing/local config files.
list=$(mktemp)
trap 'rm -f "$list"' EXIT
paths=(Cargo.toml Cargo.lock src libs res flutter/lib flutter/android flutter/assets flutter/pubspec.yaml flutter/pubspec.lock flutter/test)
{
  git -c core.safecrlf=false -C "$fork" diff --name-only -z --no-renames "$head" -- "${paths[@]}"
  git -C "$fork" ls-files -z --others --exclude-standard -- "${paths[@]}"
} | sort -zu > "$list"
while IFS= read -r -d '' file; do
  case "$file" in
    */.env*|*/local.properties|*/key.properties|*.jks|*.keystore) continue ;;
  esac
  if [[ -f "$fork/$file" && ! -L "$fork/$file" ]]; then
    install -D -m 0644 "$fork/$file" "$stage/$file"
  elif [[ ! -e "$fork/$file" && -f "$stage/$file" ]]; then
    rm -f -- "$stage/$file"
  fi
done < "$list"
if [[ -f "$stage/flutter/android/gradlew" ]]; then chmod +x "$stage/flutter/android/gradlew"; fi
for file in src/bridge_generated.rs src/bridge_generated.io.rs flutter/lib/generated_bridge.dart flutter/lib/generated_bridge.freezed.dart; do
  install -D -m 0644 "$bridge/$file" "$stage/$file"
done
