#!/bin/bash
set -Eeuo pipefail

# Debian 10 x86_64 AppImage builder using the host glibc and Electron's bundled
# SwiftShader. The InnoSilicon userspace driver is incompatible with the newer
# portable glibc previously injected into the AppImage, while its hardware
# Vulkan path exhausts VRAM shortly after startup. This build therefore keeps
# every native executable on the host loader, removes LD_LIBRARY_PATH runtime
# injection, and selects the bundled CPU Vulkan implementation explicitly.
# Chromium sandboxing is disabled for this compatibility build by requirement.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$REPO_DIR/scripts/lib/package-common.sh"

HOST_INTERP="/lib64/ld-linux-x86-64.so.2"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/1.9.0/appimagetool-x86_64.AppImage"
NODE_DIST_VERSION="v20.19.1"

require_x86_64_host() {
    [ "$(uname -m)" = "x86_64" ] || \
        error "This builder must run natively on an x86_64 host (found $(uname -m))"
    [ -e "$HOST_INTERP" ] || error "Host dynamic loader is missing: $HOST_INTERP"
}

install_build_dependencies() {
    [ "${PORTABLE_SKIP_APT:-0}" = "1" ] && return 0
    local sudo_cmd=""
    [ "$(id -u)" = 0 ] || sudo_cmd="sudo"
    export DEBIAN_FRONTEND=noninteractive
    $sudo_cmd apt-get update -qq
    $sudo_cmd apt-get install -y --no-install-recommends \
        build-essential dpkg-dev gnupg gpgv patchelf file binutils desktop-file-utils \
        curl ca-certificates xz-utils python3 strace \
        libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
        libcairo2 libcups2t64 libdbus-1-3 libdrm2 libexpat1 libgbm1 \
        libgdk-pixbuf-2.0-0 libgl1 libglib2.0-0t64 libgtk-3-0t64 \
        libnotify4 libnspr4 libnss3 libpango-1.0-0 libstdc++6 libudev1 \
        libusb-1.0-0 libx11-6 libx11-xcb1 libxcb-dri3-0 libxcb1 \
        libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 \
        libxkbcommon0 libxrandr2 libxrender1 libxss1 libxtst6
}

ensure_node() {
    if command -v node >/dev/null 2>&1; then
        local major
        major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
        [ "$major" -ge 20 ] && return 0
    fi

    local node_root="$REPO_DIR/.node-portable"
    if [ ! -x "$node_root/bin/node" ]; then
        info "Installing Node.js $NODE_DIST_VERSION (linux-x64) for the build scripts"
        curl -fsSL --retry 3 -o /tmp/node-portable.tar.xz \
            "https://nodejs.org/dist/$NODE_DIST_VERSION/node-$NODE_DIST_VERSION-linux-x64.tar.xz"
        mkdir -p "$node_root"
        tar -xJf /tmp/node-portable.tar.xz -C "$node_root" --strip-components=1
    fi
    export PATH="$node_root/bin:$PATH"
}

resolve_upstream_package() {
    local output_dir="$REPO_DIR/dist/portable-upstream"
    mkdir -p "$output_dir"
    node "$REPO_DIR/scripts/lib/upstream-linux-package.js" \
        --output-dir "$output_dir" \
        --metadata "$output_dir/upstream-linux-package.json" \
        --key-base64 "$REPO_DIR/assets/openai-codex-linux-repository-key.gpg.base64" \
        --arch amd64
}

build_app_tree() {
    local package="$1"
    CODEX_TARGET_ARCH=amd64 \
    CODEX_LINUX_FEATURES_CONFIG="$REPO_DIR/linux-features/features.example.json" \
    CODEX_INSTALL_DIR="$REPO_DIR/codex-app" \
        "$REPO_DIR/install.sh" "$package"
}

stage_appdir() {
    local version="$1"
    PACKAGE_WITH_UPDATER=0 \
    PACKAGE_VERSION="$version" \
    APPIMAGE_STAGE_ONLY=1 \
        "$REPO_DIR/scripts/build-appimage.sh"
}

is_elf() {
    readelf -h "$1" >/dev/null 2>&1
}

has_interpreter() {
    readelf -l "$1" 2>/dev/null | grep -q 'Requesting program interpreter'
}

is_dynamic_elf() {
    is_elf "$1" && readelf -d "$1" 2>/dev/null | grep -q 'Dynamic section at offset'
}

rewrite_elf_interpreters() {
    local appdir="$1"
    local rewritten=0
    local file
    while IFS= read -r -d '' file; do
        is_dynamic_elf "$file" || continue
        has_interpreter "$file" || continue
        patchelf --set-interpreter "$HOST_INTERP" "$file"
        rewritten=$((rewritten + 1))
    done < <(find "$appdir" -type f -print0)
    info "Redirected $rewritten executable interpreters to host loader $HOST_INTERP"
}

install_swiftshader_apprun() {
    local appdir="$1"
    cat > "$appdir/AppRun" <<'APPRUN_EOF'
#!/bin/bash
set -euo pipefail

resolve_appdir() {
    local source="${BASH_SOURCE[0]}"
    local dir
    while [ -L "$source" ]; do
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        case "$source" in
            /*) ;;
            *) source="$dir/$source" ;;
        esac
    done
    cd -P "$(dirname "$source")" && pwd
}

APPDIR="${APPDIR:-$(resolve_appdir)}"
export APPDIR
unset LD_LIBRARY_PATH

SWIFTSHADER_ICD="$APPDIR/opt/codex-desktop/vk_swiftshader_icd.json"
[ -f "$SWIFTSHADER_ICD" ] || {
    printf 'ChatGPT Community: bundled SwiftShader ICD is missing: %s\n' "$SWIFTSHADER_ICD" >&2
    exit 1
}
export VK_ICD_FILENAMES="$SWIFTSHADER_ICD"
export VK_DRIVER_FILES="$SWIFTSHADER_ICD"

exec "$APPDIR/opt/codex-desktop/start.sh" "$@"
APPRUN_EOF
    chmod 0755 "$appdir/AppRun"
    info "Installed host-loader SwiftShader AppRun"
}

patch_staged_launcher() {
    local appdir="$1"
    local launcher="$appdir/opt/codex-desktop/start.sh"
    [ -f "$launcher" ] || error "Missing staged launcher: $launcher"

    python3 - "$launcher" <<'PY'
import pathlib
import sys

launcher = pathlib.Path(sys.argv[1])
text = launcher.read_text()
anchor = '''report_daily_usage
run_hook_directory "$HOOK_ROOT/cold-start.d" cold-start &'''
replacement = '''ELECTRON_ARGS+=(
    "--use-gl=angle"
    "--use-angle=swiftshader"
    "--enable-unsafe-swiftshader"
    "--disable-gpu-compositing"
    "--no-sandbox"
    "--disable-dev-shm-usage"
    "--disable-gpu-sandbox"
)

report_daily_usage
run_hook_directory "$HOOK_ROOT/cold-start.d" cold-start &'''
if text.count(anchor) != 1:
    raise SystemExit(f"expected one launcher insertion point, found {text.count(anchor)}")
launcher.write_text(text.replace(anchor, replacement, 1))
PY
    info "Pinned Electron to bundled SwiftShader without Chromium sandboxing"
}

audit_swiftshader_runtime() {
    local appdir="$1"
    local required
    for required in \
        opt/codex-desktop/ChatGPT \
        opt/codex-desktop/libEGL.so \
        opt/codex-desktop/libGLESv2.so \
        opt/codex-desktop/libvk_swiftshader.so \
        opt/codex-desktop/vk_swiftshader_icd.json; do
        [ -e "$appdir/$required" ] || error "SwiftShader runtime is missing: $required"
    done

    local file interp
    local elf_count=0
    local interp_count=0
    local wrong_count=0
    while IFS= read -r -d '' file; do
        is_elf "$file" || continue
        elf_count=$((elf_count + 1))
        has_interpreter "$file" || continue
        interp_count=$((interp_count + 1))
        interp="$(readelf -l "$file" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p')"
        if [ "$interp" != "$HOST_INTERP" ]; then
            warn "Unexpected interpreter in $file: $interp"
            wrong_count=$((wrong_count + 1))
        fi
    done < <(find "$appdir" -type f -print0)

    [ "$wrong_count" -eq 0 ] || error "Audit failed: $wrong_count executables do not use $HOST_INTERP"
    ! grep -q 'LD_LIBRARY_PATH=' "$appdir/AppRun" || error "AppRun still injects LD_LIBRARY_PATH"
    grep -q -- '"--use-angle=swiftshader"' "$appdir/opt/codex-desktop/start.sh" || \
        error "Launcher does not select SwiftShader"
    grep -q -- '"--no-sandbox"' "$appdir/opt/codex-desktop/start.sh" || \
        error "Launcher does not disable Chromium sandboxing"
    info "Audit passed: $elf_count ELF files, $interp_count host-loader executables, bundled SwiftShader selected"
}

resolve_appimagetool() {
    if [ -n "${APPIMAGETOOL:-}" ]; then
        [ -x "$APPIMAGETOOL" ] || error "APPIMAGETOOL is not executable: $APPIMAGETOOL"
        printf '%s\n' "$APPIMAGETOOL"
        return 0
    fi
    if command -v appimagetool >/dev/null 2>&1; then
        command -v appimagetool
        return 0
    fi

    local tool="$REPO_DIR/dist/appimagetool-x86_64.AppImage"
    if [ ! -x "$tool" ]; then
        info "Downloading appimagetool 1.9.0"
        curl -fL --retry 3 -o "$tool" "$APPIMAGETOOL_URL"
        chmod 0755 "$tool"
    fi
    printf '%s\n' "$tool"
}

pack_appimage() {
    local appdir="$1"
    local version="$2"
    local tool
    tool="$(resolve_appimagetool)"
    local output="$REPO_DIR/dist/codex-desktop-${version}-x86_64.AppImage"
    rm -f "$output"
    info "Packing AppImage: $output"
    ARCH=x86_64 VERSION="$version" APPIMAGE_EXTRACT_AND_RUN=1 \
        "$tool" --no-appstream "$appdir" "$output" >&2
    [ -f "$output" ] || error "appimagetool produced no output"
    chmod 0755 "$output"
    printf '%s\n' "$output"
}

smoke_test() {
    local output="$1"
    local workdir
    workdir="$(mktemp -d)"
    info "Smoke: extracting the packed AppImage"
    (cd "$workdir" && "$output" --appimage-extract >/dev/null)
    info "Smoke: AppRun --diagnose"
    "$workdir/squashfs-root/AppRun" --diagnose
    info "Smoke: host-loader SwiftShader launch"
    timeout 180 env LD_LIBRARY_PATH=/must/not/survive \
        "$workdir/squashfs-root/AppRun" --version
    rm -rf "$workdir"
}

main() {
    require_x86_64_host
    install_build_dependencies
    ensure_node

    local package
    package="$(resolve_upstream_package)"
    info "Official package: $package"
    build_app_tree "$package"

    local version
    version="$(dpkg-deb --field "$package" Version)-portable-swiftshader1"
    info "SwiftShader compatibility package version: $version"

    local appdir
    appdir="$(stage_appdir "$version")"
    rm -rf "$appdir/opt/codex-desktop/.codex-linux/runtime"
    rewrite_elf_interpreters "$appdir"
    install_swiftshader_apprun "$appdir"
    patch_staged_launcher "$appdir"
    audit_swiftshader_runtime "$appdir"

    local output
    output="$(pack_appimage "$appdir" "$version")"
    smoke_test "$output"

    (cd "$(dirname "$output")" && sha256sum "$(basename "$output")") | tee "$output.sha256"
    info "SwiftShader compatibility AppImage ready: $output"
}

main "$@"
