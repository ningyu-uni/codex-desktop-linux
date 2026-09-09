#!/bin/bash
set -Eeuo pipefail

# Portable x86_64 AppImage builder for old-glibc targets (Debian 10, glibc 2.28).
#
# The official ChatGPT Linux payload references GLIBC_2.35+ symbols, so the
# host loader on Debian 10 cannot run it, and bundling ordinary libraries
# cannot fix that: the dynamic loader itself is part of glibc. This builder
# therefore bundles the payload's complete application-library closure — including
# glibc with its dynamic loader and libstdc++ — inside the AppImage. Mesa,
# libdrm, GBM, EGL, GLX, X11, XCB, and Wayland remain host-provided: those
# libraries must match the host kernel and graphics driver rather than the
# Ubuntu build runner. Every executable gets PT_INTERP redirected to a fixed
# short path that AppRun points at the bundled loader on each launch (AppImage
# mount paths change per run, so the link must be recreated then).
# Chromium re-executes its own binary for child processes, so every executable
# in the image — not just the main one — needs the redirected interpreter.
# Bundled libraries are found through the scoped LD_LIBRARY_PATH applied only
# while launching ChatGPT; host utilities and host graphics libraries stay
# outside that environment.
#
# The result runs on hosts with glibc >= 2.28 (for example Debian 10, kernel
# 4.19) without using the host glibc. Residual risks of the bundled-glibc
# approach: glibc iconv/gconv modules are not bundled (Chromium uses its own
# ICU), and host dlopen modules such as GTK module or printbackends load the
# host copies, which works because libraries built for an older glibc load
# fine into a newer one. Run this natively on an x86_64 host only.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$REPO_DIR/scripts/lib/package-common.sh"

PORTABLE_INTERP_NAME="ld-linux-x86-64.so.2"
# Kept shorter than the stock interpreter path (/lib64/ld-linux-x86-64.so.2,
# 27 bytes) so patchelf rewrites PT_INTERP in place instead of shifting
# segments, which corrupts large PIE binaries such as the Chromium payload.
PORTABLE_INTERP="/tmp/.cdx-portable-ld.so"
RUNTIME_LIB_REL="opt/codex-desktop/.codex-linux/runtime/lib"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/1.9.0/appimagetool-x86_64.AppImage"
NODE_DIST_VERSION="v20.19.1"

require_x86_64_host() {
    [ "$(uname -m)" = "x86_64" ] || \
        error "This builder must run natively on an x86_64 host (found $(uname -m))"
}

install_build_dependencies() {
    [ "${PORTABLE_SKIP_APT:-0}" = "1" ] && return 0
    local sudo_cmd=""
    [ "$(id -u)" = 0 ] || sudo_cmd="sudo"
    export DEBIAN_FRONTEND=noninteractive
    $sudo_cmd apt-get update -qq
    # Tooling plus the runtime-library set the bundled closure is sourced from.
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

# Statically linked payload executables carry no .dynamic section; they need
# neither RPATH nor interpreter rewrites and patchelf rejects them.
is_dynamic_elf() {
    is_elf "$1" && readelf -d "$1" 2>/dev/null | grep -q 'Dynamic section at offset'
}

ldd_resolved_paths() {
    LD_LIBRARY_PATH="$1" ldd "$2" 2>/dev/null | awk '
        $2 == "=>" && $3 ~ /^\// { print $3; next }
        $1 ~ /^\// && $2 ~ /^\(0x/ { print $1 }
    ' | sort -u
}

ldd_missing_count() {
    LD_LIBRARY_PATH="$1" ldd "$2" 2>/dev/null | grep -cF 'not found' || true
}
host_graphics_library() {
    case "$(basename "$1")" in
        libGL.so.*|libEGL.so.*|libGLX.so.*|libOpenGL.so.*|libGLES*.so.*| \
        libGLdispatch.so.*|libgbm.so.*|libdrm.so.*|libvulkan.so.*|libva.so.*| \
        libwayland-*.so.*|libX11.so.*|libX11-xcb.so.*|libXext.so.*| \
        libXfixes.so.*|libXdamage.so.*|libXrandr.so.*|libXi.so.*| \
        libxcb*.so.*|libxkbcommon*.so.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


bundle_library_closure() {
    local appdir="$1"
    local runtime_lib="$appdir/$RUNTIME_LIB_REL"
    mkdir -p "$runtime_lib"

    local -a queue=()
    local f
    while IFS= read -r -d '' f; do
        is_elf "$f" || continue
        queue+=("$(realpath "$f")")
    done < <(find "$appdir" -type f -print0)

    local index=0 bundled=0
    while [ "$index" -lt "${#queue[@]}" ]; do
        local elf="${queue[$index]}"
        index=$((index + 1))
        local dep resolved target
        while IFS= read -r dep; do
            [ -e "$dep" ] || continue
            resolved="$(realpath "$dep")"
            case "$resolved" in
                "$appdir"/*) continue ;;
            esac
            case "$(basename "$dep")" in
                "$PORTABLE_INTERP_NAME"|ld-linux*|linux-vdso*) continue ;;
            esac
            # Mesa/DRM/desktop libraries must match the host kernel and GPU
            # driver. The bundled glibc loader can resolve them from the host.
            host_graphics_library "$dep" && continue
            target="$runtime_lib/$(basename "$dep")"
            [ -e "$target" ] && continue
            cp -L --preserve=mode,timestamps "$dep" "$target"
            bundled=$((bundled + 1))
            queue+=("$resolved")
        done < <(ldd_resolved_paths "$runtime_lib" "$elf")
    done
    info "Bundled $bundled shared libraries into $RUNTIME_LIB_REL"
}

copy_dynamic_loader() {
    local appdir="$1"
    local runtime_lib="$appdir/$RUNTIME_LIB_REL"
    local loader
    loader="$(ldd /bin/true | awk '/ld-linux/ {print $1; exit}')"
    [ -n "$loader" ] || error "Could not locate the host dynamic loader"
    cp -L --preserve=mode,timestamps "$loader" "$runtime_lib/$PORTABLE_INTERP_NAME"
    info "Bundled dynamic loader: $loader"
}

rewrite_elf_interpreters() {
    local appdir="$1"
    local rewritten=0
    local f
    while IFS= read -r -d '' f; do
        is_dynamic_elf "$f" || continue
        if has_interpreter "$f"; then
            patchelf --set-interpreter "$PORTABLE_INTERP" "$f"
            rewritten=$((rewritten + 1))
        fi
    done < <(find "$appdir" -type f -print0)
    info "Redirected $rewritten executable interpreters to $PORTABLE_INTERP"
}

install_portable_apprun() {
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

# The payload runs on the AppImage-internal glibc. Every executable inside
# the image has PT_INTERP pointed at the fixed LOADER_LINK path; the symlink
# below makes that path resolve to the loader in the current mount. It is
# recreated on each launch because AppImage mount points differ per run, and
# every Chromium child process that re-executes the main binary resolves it
# again. Do not export LD_LIBRARY_PATH here: AppRun and start.sh invoke host
# utilities before launching ChatGPT, and a Debian 10 host loader must not
# combine those utilities with this AppImage's newer libc. The generated
# start.sh applies this path only to ChatGPT and its inherited child tree.
RUNTIME_LIB="$APPDIR/opt/codex-desktop/.codex-linux/runtime/lib"
LOADER_LINK="/tmp/.cdx-portable-ld.so"
if [ -x "$RUNTIME_LIB/ld-linux-x86-64.so.2" ]; then
    ln -sfn "$RUNTIME_LIB/ld-linux-x86-64.so.2" "$LOADER_LINK" 2>/dev/null || {
        printf 'ChatGPT Community: cannot create the portable loader link %s; remove it and retry.\n' "$LOADER_LINK" >&2
        exit 1
    }
    expected="$(cd "$RUNTIME_LIB" && pwd)/ld-linux-x86-64.so.2"
    if [ "$(readlink -f "$LOADER_LINK")" != "$expected" ]; then
        printf 'ChatGPT Community: portable loader link mismatch at %s.\n' "$LOADER_LINK" >&2
        exit 1
    fi
    export CODEX_PORTABLE_RUNTIME_LIB="$RUNTIME_LIB"
fi

exec "$APPDIR/opt/codex-desktop/start.sh" "$@"
APPRUN_EOF
    chmod 0755 "$appdir/AppRun"
    info "Installed portable AppRun"
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
runtime = 'LD_LIBRARY_PATH="${CODEX_PORTABLE_RUNTIME_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"'

exec_line = '    exec "$CHATGPT_BINARY" "${ELECTRON_ARGS[@]}" "${ORIGINAL_ARGS[@]}"'
gpu_guard = '''    if [ "${CODEX_PORTABLE_DISABLE_GPU:-0}" = "1" ]; then
        ELECTRON_ARGS+=("--disable-gpu")
    fi

'''
exec_replacement = f'{gpu_guard}    exec env {runtime} "$CHATGPT_BINARY" "${{ELECTRON_ARGS[@]}}" "${{ORIGINAL_ARGS[@]}}"'
if text.count(exec_line) != 1:
    raise SystemExit(f"expected one direct ChatGPT exec, found {text.count(exec_line)}")
text = text.replace(exec_line, exec_replacement, 1)

after_exit_line = '\n"$CHATGPT_BINARY" "${ELECTRON_ARGS[@]}" "${ORIGINAL_ARGS[@]}"'
after_exit_replacement = f'\nenv {runtime} "$CHATGPT_BINARY" "${{ELECTRON_ARGS[@]}}" "${{ORIGINAL_ARGS[@]}}"'
if text.count(after_exit_line) != 1:
    raise SystemExit(f"expected one after-exit ChatGPT launch, found {text.count(after_exit_line)}")
text = text.replace(after_exit_line, after_exit_replacement, 1)

launcher.write_text(text)
PY
    info "Scoped bundled LD_LIBRARY_PATH to ChatGPT launches"
}

install_loader_link() {
    local runtime_lib="$1"
    ln -sfn "$runtime_lib/$PORTABLE_INTERP_NAME" "$PORTABLE_INTERP"
}

# Payload components that are optional by design: the Qt shims are dlopen'd
# only when a Qt runtime exists on the host (the official deb does not depend
# on Qt either), and musl prebuild variants are never loaded on glibc hosts
# because glibc counterparts ship in the same prebuilds tree.
audit_exempt() {
    case "$1" in
        */libqt5_shim.so|*/libqt6_shim.so|*musl*) return 0 ;;
        *) return 1 ;;
    esac
}

audit_bundled_runtime() {
    local appdir="$1"
    local runtime_lib="$appdir/$RUNTIME_LIB_REL"
    local essential
    for essential in "$PORTABLE_INTERP_NAME" libc.so.6 libstdc++.so.6 libm.so.6; do
        [ -e "$runtime_lib/$essential" ] || error "Bundled runtime is missing $essential"
    done

    local elf_count=0 missing_files=0 interp_files=0
    local f interp
    while IFS= read -r -d '' f; do
        is_elf "$f" || continue
        elf_count=$((elf_count + 1))
        if audit_exempt "$f"; then
            continue
        fi
        if [ "$(ldd_missing_count "$runtime_lib" "$f")" -gt 0 ]; then
            missing_files=$((missing_files + 1))
            warn "Unresolved dependencies in: $f"
            LD_LIBRARY_PATH="$runtime_lib" ldd "$f" 2>/dev/null | grep -F 'not found' >&2 || true
        fi
        if has_interpreter "$f"; then
            interp="$(readelf -l "$f" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p')"
            if [ "$interp" != "$PORTABLE_INTERP" ]; then
                interp_files=$((interp_files + 1))
                warn "Interpreter not redirected in: $f ($interp)"
            fi
        fi
    done < <(find "$appdir" -type f -print0)
    [ "$missing_files" -eq 0 ] || error "Audit failed: $missing_files ELF files have unresolved dependencies"
    [ "$interp_files" -eq 0 ] || error "Audit failed: $interp_files executables still use a host interpreter"
    info "Audit passed: $elf_count ELF files, $(ls -1 "$runtime_lib" | wc -l) bundled libraries, $(du -sh "$runtime_lib" | cut -f1)"
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
    [ -f "$output" ] || error "appimagetool produced no output (exit code lost through APPIMAGE_EXTRACT_AND_RUN)"
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

    info "Smoke: resolving dependencies through the bundled loader"
    local extracted_lib="$workdir/squashfs-root/$RUNTIME_LIB_REL"
    env -u LD_LIBRARY_PATH "$extracted_lib/$PORTABLE_INTERP_NAME" \
        --library-path "$extracted_lib" \
        --list "$workdir/squashfs-root/opt/codex-desktop/ChatGPT" > "$workdir/loader-list.txt" 2>&1 || true
    grep -vE '^(linux-vdso|linux-gate)' "$workdir/loader-list.txt" | head -80 || true
    if command -v strace >/dev/null 2>&1; then
        timeout 180 strace -f -e trace=execve,openat,access,statx \
            "$workdir/squashfs-root/AppRun" --version \
            > "$workdir/strace.txt" 2>&1 || true
        tail -60 "$workdir/strace.txt" || true
    fi
    timeout 180 "$workdir/squashfs-root/AppRun" --version
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
    version="$(dpkg-deb --field "$package" Version)-portable1"
    info "Portable package version: $version"

    local appdir
    appdir="$(stage_appdir "$version")"
    local runtime_lib="$appdir/$RUNTIME_LIB_REL"

    bundle_library_closure "$appdir"
    copy_dynamic_loader "$appdir"
    rewrite_elf_interpreters "$appdir"
    install_portable_apprun "$appdir"
    patch_staged_launcher "$appdir"
    install_loader_link "$runtime_lib"
    audit_bundled_runtime "$appdir"

    local output
    output="$(pack_appimage "$appdir" "$version")"
    smoke_test "$output"

    sha256sum "$output" | tee "$output.sha256"
    info "Portable AppImage ready: $output"
}

main "$@"
