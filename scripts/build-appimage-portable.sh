#!/bin/bash
set -Eeuo pipefail

# Portable x86_64 AppImage builder for old-glibc targets (Debian 10, glibc 2.28).
#
# The official ChatGPT Linux payload references GLIBC_2.35+ symbols, so the
# host loader on Debian 10 cannot run it, and bundling ordinary libraries
# cannot fix that: the dynamic loader itself is part of glibc. This builder
# therefore bundles the payload's complete shared-library closure — including
# glibc with its dynamic loader, libstdc++, GTK, NSS, and the graphics and
# audio stack, sourced from the x86_64 build host (GitHub's ubuntu-24.04
# runner) — inside the AppImage. Every ELF gets PT_INTERP redirected to a
# fixed path that AppRun points at the bundled loader on each launch (AppImage
# mount paths change per run, so the link must be recreated then), and RPATH
# entries are repointed at the bundled library directory. Chromium re-executes
# its own binary for child processes, so every executable in the image — not
# just the main one — needs the redirected interpreter.
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

PORTABLE_LOADER_DIR="/tmp/.codex-desktop-portable-ld"
PORTABLE_INTERP_NAME="ld-linux-x86-64.so.2"
PORTABLE_INTERP="$PORTABLE_LOADER_DIR/$PORTABLE_INTERP_NAME"
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
        build-essential dpkg-dev gnupg gpgv patchelf file binutils \
        curl ca-certificates xz-utils python3 \
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

ldd_resolved_paths() {
    LD_LIBRARY_PATH="$1" ldd "$2" 2>/dev/null | awk '
        $2 == "=>" && $3 ~ /^\// { print $3; next }
        $1 ~ /^\// && $2 ~ /^\(0x/ { print $1 }
    ' | sort -u
}

ldd_missing_count() {
    LD_LIBRARY_PATH="$1" ldd "$2" 2>/dev/null | grep -cF 'not found' || true
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

rewrite_elf_metadata() {
    local appdir="$1"
    local runtime_lib="$appdir/$RUNTIME_LIB_REL"
    local rewritten=0
    local f
    while IFS= read -r -d '' f; do
        is_elf "$f" || continue
        local new_rpath old_rpath
        if [[ "$(realpath "$f")" == "$runtime_lib"/* ]]; then
            new_rpath='$ORIGIN'
        else
            local rel
            rel="$(python3 -c 'import os, sys
print("$ORIGIN/" + os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' \
                "$runtime_lib" "$f")"
            old_rpath="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
            if [ -n "$old_rpath" ]; then
                new_rpath="$rel:$old_rpath"
            else
                new_rpath="$rel"
            fi
        fi
        patchelf --set-rpath "$new_rpath" "$f"
        if has_interpreter "$f"; then
            patchelf --set-interpreter "$PORTABLE_INTERP" "$f"
        fi
        rewritten=$((rewritten + 1))
    done < <(find "$appdir" -type f -print0)
    info "Rewrote $rewritten ELF files (RPATH + interpreter)"
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

# The payload runs on the AppImage-internal glibc. Every ELF inside the image
# has PT_INTERP pointed at a fixed path; this symlink makes that path resolve
# to the loader in the current mount. It is recreated on each launch because
# AppImage mount points differ per run, and every Chromium child process that
# re-executes the main binary resolves it again.
RUNTIME_LIB="$APPDIR/opt/codex-desktop/.codex-linux/runtime/lib"
LOADER_DIR="/tmp/.codex-desktop-portable-ld"
if [ -x "$RUNTIME_LIB/ld-linux-x86-64.so.2" ]; then
    if ! mkdir -m 0755 -p "$LOADER_DIR" 2>/dev/null; then
        printf 'ChatGPT Community: cannot create %s; remove it and retry.\n' "$LOADER_DIR" >&2
        exit 1
    fi
    ln -sfn "$RUNTIME_LIB/ld-linux-x86-64.so.2" "$LOADER_DIR/ld-linux-x86-64.so.2" 2>/dev/null || {
        printf 'ChatGPT Community: cannot link the portable loader in %s.\n' "$LOADER_DIR" >&2
        exit 1
    }
    resolved="$(readlink -f "$LOADER_DIR/ld-linux-x86-64.so.2")"
    expected="$(cd "$RUNTIME_LIB" && pwd)/ld-linux-x86-64.so.2"
    if [ "$resolved" != "$expected" ]; then
        printf 'ChatGPT Community: portable loader link mismatch in %s.\n' "$LOADER_DIR" >&2
        exit 1
    fi
fi

exec "$APPDIR/opt/codex-desktop/start.sh" "$@"
APPRUN_EOF
    chmod 0755 "$appdir/AppRun"
    info "Installed portable AppRun"
}

install_loader_link() {
    local runtime_lib="$1"
    mkdir -m 0755 -p "$PORTABLE_LOADER_DIR"
    ln -sfn "$runtime_lib/$PORTABLE_INTERP_NAME" "$PORTABLE_INTERP"
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
    info "Smoke: launching the official binary through the bundled loader (--version)"
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
    rewrite_elf_metadata "$appdir"
    install_portable_apprun "$appdir"
    install_loader_link "$runtime_lib"
    audit_bundled_runtime "$appdir"

    local output
    output="$(pack_appimage "$appdir" "$version")"
    smoke_test "$output"

    sha256sum "$output" | tee "$output.sha256"
    info "Portable AppImage ready: $output"
}

main "$@"
