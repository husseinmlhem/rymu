#!/usr/bin/env bash
set -euo pipefail

# Pass a dedicated Linux source checkout. This script stages compiled libraries
# in its jniLibs tree before invoking the upstream Flutter APK builder.
usage() { echo "Usage: $0 SOURCE APK_OUTPUT_DIR {arm64-v8a|x86_64} {rymu|upstream}" >&2; exit 2; }
[[ $# == 4 ]] || usage
source_dir=$(realpath "$1")
output_dir=$(realpath -m "$2")
abi=$3
variant=$4
build_mode=${RYMU_ANDROID_BUILD_MODE:-debug}
[[ "$build_mode" == debug || "$build_mode" == release ]] || usage
if [[ "$build_mode" == release ]]; then
  : "${RYMU_ANDROID_KEYSTORE:?Public release requires an existing private keystore}"
  : "${RYMU_ANDROID_STORE_PASSWORD_FILE:?Public release requires a private password file}"
  test -f "$RYMU_ANDROID_KEYSTORE"
  test -f "$RYMU_ANDROID_STORE_PASSWORD_FILE"
  export RYMU_ANDROID_UNSIGNED_RELEASE=1
fi
case "$abi" in
  arm64-v8a) target=aarch64-linux-android; platform=android-arm64; features=flutter,hwcodec ;;
  x86_64) target=x86_64-linux-android; platform=android-x64; features=flutter ;;
  *) usage ;;
esac
[[ "$variant" == rymu || "$variant" == upstream ]] || usage

: "${FLUTTER_ROOT:?Path to isolated Flutter 3.24.5 SDK (with upstream dropdown patch)}"
: "${JAVA_HOME:?Path to OpenJDK 17}"
: "${ANDROID_HOME:?Path to Android SDK with API 36 and build-tools 36.0.0}"
: "${ANDROID_NDK_HOME:?Path to Android NDK r28c}"
: "${VCPKG_ROOT:?Path to pinned vcpkg checkout and native build outputs}"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export VCPKG_DISABLE_METRICS=1
export PATH="$FLUTTER_ROOT/bin:$JAVA_HOME/bin:$PATH"
# The Android bindgen pass must use the NDK headers, including for hwcodec's
# C++ bindings. Leave the host's bindgen configuration alone.
bindgen_key="BINDGEN_EXTRA_CLANG_ARGS_${target//-/_}"
export "$bindgen_key=--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot ${!bindgen_key:-}"

cd "$source_dir"
expected=23e5bb471a040d62f0a6ad52591fb30784265b73
if [[ "$variant" == upstream ]]; then
  [[ $(git rev-parse HEAD) == "$expected" ]] && git diff --quiet HEAD || {
    echo "Expected clean upstream HEAD $expected" >&2; exit 2;
  }
else
  git merge-base --is-ancestor "$expected" HEAD || {
    echo "Expected pinned upstream ancestor $expected" >&2; exit 2;
  }
fi
[[ $(git -C libs/hbb_common rev-parse HEAD) == fae47e024dd83cef6aaecde0aa7d11731df11649 ]] || {
  echo 'Initialize the pinned hbb_common submodule' >&2; exit 2;
}
[[ -f src/bridge_generated.rs && -f flutter/lib/generated_bridge.freezed.dart ]] || {
  echo 'Generate the upstream Flutter/Rust bridge per .github/workflows/bridge.yml first' >&2; exit 2;
}
[[ -x "$JAVA_HOME/bin/java" && -f "$ANDROID_HOME/platforms/android-36/android.jar" ]] || {
  echo 'JDK or Android SDK platform 36 missing' >&2; exit 2;
}
grep -Eq '^Pkg.Revision *= *28\.2\.13676358$' "$ANDROID_NDK_HOME/source.properties" || {
  echo 'Expected NDK r28c (28.2.13676358)' >&2; exit 2;
}
[[ $(git -C "$VCPKG_ROOT" rev-parse HEAD) == 9e593bb18ea69cc5095e012465dcd675a822ed0d ]] || {
  echo 'Unexpected vcpkg revision' >&2; exit 2;
}

echo "Building $variant $abi with $expected"
cargo -V
cargo ndk --version
flutter --suppress-analytics --version
"$JAVA_HOME/bin/java" -version
if [[ -n "${RYMU_ANDROID_DEPS_SOURCE:-}" ]]; then
  deps_source=$(realpath "$RYMU_ANDROID_DEPS_SOURCE")
  [[ $(git -C "$deps_source" rev-parse HEAD) == "$expected" ]] || {
    echo 'Android dependency source has a different upstream revision' >&2; exit 2;
  }
  "$deps_source/flutter/build_android_deps.sh" "$abi"
else
  ./flutter/build_android_deps.sh "$abi"
fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$source_dir/target}"
# The APK consumes the shared library only. Android has no Rust CLI or service
# executable; skip those Cargo targets and keep the upstream JNI features.
cargo ndk --platform 21 --target "$target" build --locked --release --lib --features "$features"

libraries="flutter/android/app/src/main/jniLibs/$abi"
mkdir -p "$libraries" "$output_dir"
cp "$CARGO_TARGET_DIR/$target/release/liblibrustdesk.so" "$libraries/librustdesk.so"
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$target/libc++_shared.so" "$libraries/libc++_shared.so"

args=()
if [[ "$variant" == rymu && "${RYMU_LOCAL_BUILD:-}" == 1 ]]; then
  args+=(--dart-define=RYMU_LOCAL_BUILD=true)
fi
for key in RYMU_API_BASE RYMU_WEB_ORIGIN RYMU_RENDEZVOUS_ENDPOINT RYMU_RELAY_ENDPOINT RYMU_SERVER_PUBLIC_KEY; do
  if [[ "$variant" == rymu && -n "${!key:-}" ]]; then args+=("--dart-define=$key=${!key}"); fi
done
cd flutter
flutter --suppress-analytics pub get
if [[ -n "${RYMU_ANDROID_BUILD_NUMBER:-}" ]]; then
  [[ "$RYMU_ANDROID_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]
  args+=("--build-number=$RYMU_ANDROID_BUILD_NUMBER")
fi
flutter --suppress-analytics build apk "--$build_mode" --no-pub --target-platform "$platform" --split-per-abi "${args[@]}"
candidate="build/app/outputs/flutter-apk/app-$abi-$build_mode.apk"
test -s "$candidate"
apk="$output_dir/$variant-$abi-$build_mode${RYMU_ANDROID_BUILD_NUMBER:+-$RYMU_ANDROID_BUILD_NUMBER}.apk"
test ! -e "$apk" || { echo 'Refusing to overwrite an existing APK' >&2; exit 2; }
if [[ "$build_mode" == release ]]; then
  "$ANDROID_HOME/build-tools/36.0.0/zipalign" -c -P 16 4 "$candidate"
  signed_candidate="$source_dir/rymu-$abi-signed-release.apk"
  test ! -e "$signed_candidate"
  "$ANDROID_HOME/build-tools/36.0.0/apksigner" sign \
    --ks "$RYMU_ANDROID_KEYSTORE" --ks-key-alias rymu-release \
    --ks-pass "file:$RYMU_ANDROID_STORE_PASSWORD_FILE" \
    --out "$signed_candidate" "$candidate"
  candidate="$signed_candidate"
fi
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose "$candidate"
unzip -Z1 "$candidate" | grep -Fx "lib/$abi/librustdesk.so"
unzip -Z1 "$candidate" | grep -Fx "lib/$abi/libc++_shared.so"
cp "$candidate" "$apk"
sha256sum "$apk"
