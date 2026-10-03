#!/usr/bin/env bash

set -e

BUNDLE_NAME="InstagramX.bundle"

copy_localization_into_bundle() {
    local DEST="$1"
    local SRC="src/Localization/Resources"
    [ -d "$SRC" ] || return 0
    mkdir -p "$DEST"
    for lproj in "$SRC"/*.lproj; do
        [ -d "$lproj" ] || continue
        cp -R "$lproj" "$DEST/"
    done
}

copy_bundle_assets() {
    local DEST="$1"
    local SRC="src/BundleAssets"
    [ -d "$SRC" ] || return 0
    mkdir -p "$DEST"
    find "$SRC" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.pdf' \) \
        -exec cp {} "$DEST/" \;
    if [ -d "$SRC/Fonts" ]; then
        mkdir -p "$DEST/Fonts"
        find "$SRC/Fonts" -type f \( -iname '*.ttf' -o -iname '*.otf' \) -exec cp {} "$DEST/Fonts/" \;
    fi
}

# Optional. modules/ffmpegkit is gitignored. setup-ffmpegkit.sh downloads the
# public ffmpeg-kit 6.0 iOS frameworks when they are not already present.
copy_ffmpeg_into_bundle() {
    local DEST="$1"
    [ -d "modules/ffmpegkit/ffmpegkit.framework" ] || return 0
    local fw
    for fw in modules/ffmpegkit/*.framework; do
        [ -d "$fw" ] || continue
        cp -R "$fw" "$DEST/"
    done
    local LIBS="libavutil libavcodec libavformat libavfilter libavdevice libswresample libswscale"
    local lib target
    for lib in $LIBS; do
        [ -d "$DEST/${lib}.framework" ] || continue
        mv "$DEST/${lib}.framework" "$DEST/${lib}_sci.framework"
        if [ -f "$DEST/${lib}_sci.framework/${lib}" ]; then
            install_name_tool -id "@rpath/${lib}_sci.framework/${lib}" \
                "$DEST/${lib}_sci.framework/${lib}" 2>/dev/null || true
        fi
    done
    for target in "$DEST/ffmpegkit.framework/ffmpegkit" \
                  "$DEST"/libav*_sci.framework/libav* \
                  "$DEST"/libsw*_sci.framework/libsw*; do
        [ -f "$target" ] || continue
        for lib in $LIBS; do
            install_name_tool -change \
                "@rpath/${lib}.framework/${lib}" \
                "@rpath/${lib}_sci.framework/${lib}" \
                "$target" 2>/dev/null || true
        done
    done
    if [ -f "$DEST/ffmpegkit.framework/ffmpegkit" ]; then
        install_name_tool -add_rpath @loader_path/.. \
            "$DEST/ffmpegkit.framework/ffmpegkit" 2>/dev/null || true
    fi
}

write_bundle_plist() {
    local DEST="$1"
    cat > "$DEST/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.kamyar.instagramx.resources</string>
    <key>CFBundleName</key>
    <string>InstagramX</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleVersion</key>
    <string>2.0.0</string>
</dict>
</plist>
PLIST
}

build_resource_bundle() {
    local DEST="packages/${BUNDLE_NAME}"
    rm -rf "$DEST"
    mkdir -p "$DEST"
    copy_localization_into_bundle "$DEST"
    copy_bundle_assets "$DEST"
    copy_ffmpeg_into_bundle "$DEST"
    write_bundle_plist "$DEST"
}

inject_bundle_into_deb() {
    local BASE_DEB="$1"
    local TMPDIR DYLIB_DIR PREFIX BUNDLE_DIR
    TMPDIR=$(mktemp -d)
    dpkg-deb -R "$BASE_DEB" "$TMPDIR"
    DYLIB_DIR=$(find "$TMPDIR" -name "SCInsta.dylib" -exec dirname {} \; | head -1)
    if [ -z "$DYLIB_DIR" ]; then
        rm -rf "$TMPDIR"
        return
    fi
    PREFIX=""
    [[ "$DYLIB_DIR" == *"/var/jb/"* ]] && PREFIX="var/jb/"
    BUNDLE_DIR="$TMPDIR/${PREFIX}Library/Application Support/${BUNDLE_NAME}"
    mkdir -p "$BUNDLE_DIR"
    copy_localization_into_bundle "$BUNDLE_DIR"
    copy_bundle_assets "$BUNDLE_DIR"
    copy_ffmpeg_into_bundle "$BUNDLE_DIR"
    write_bundle_plist "$BUNDLE_DIR"
    dpkg-deb -b "$TMPDIR" "$BASE_DEB"
    rm -rf "$TMPDIR"
}


CMAKE_OSX_ARCHITECTURES="arm64e;arm64"
CMAKE_OSX_SYSROOT="iphoneos"

# Prerequisites
if [ -z "$(ls -A modules/FLEXing)" ]; then
    echo -e '\033[1m\033[0;31mFLEXing submodule not found.\nPlease run the following command to checkout submodules:\n\n\033[0m    git submodule update --init --recursive'
    exit 1
fi

# Building modes
if [ "$1" == "sideload" ];
then

    # Check if building with dev mode
    if [ "$2" == "--dev" ];
    then
        # Cache pre-built FLEX libs
        mkdir -p "packages/cache"
        cp -f ".theos/obj/debug/FLEXing.dylib" "packages/cache/FLEXing.dylib" 2>/dev/null || true
        cp -f ".theos/obj/debug/libflex.dylib" "packages/cache/libflex.dylib" 2>/dev/null || true

        if [[ ! -f "packages/cache/FLEXing.dylib" || ! -f "packages/cache/libflex.dylib" ]]; then
            echo -e '\033[1m\033[0;33mCould not find cached pre-built FLEX libs, building prerequisite binaries\033[0m'
            echo

            ./build.sh sideload --buildonly
            ./build-dev.sh true
            exit
        fi

        MAKEARGS='DEV=1'
        FLEXPATH='packages/cache/FLEXing.dylib packages/cache/libflex.dylib'
        COMPRESSION=0
    else
        # Clear cached FLEX libs
        rm -rf "packages/cache"

        MAKEARGS='SIDELOAD=1'
        FLEXPATH='.theos/obj/debug/FLEXing.dylib .theos/obj/debug/libflex.dylib'
        COMPRESSION=9
    fi

    # Clean build artifacts
    make clean
    rm -rf .theos

    # Check for decrypted instagram ipa
    ipaFile="$(find ./packages/*com.burbn.instagram*.ipa -type f -exec basename {} \;)"
    if [ -z "${ipaFile}" ]; then
        echo -e '\033[1m\033[0;31m./packages/com.burbn.instagram.ipa not found.\nPlease put a decrypted Instagram IPA in its path.\033[0m'
        exit 1
    fi

    echo -e '\033[1m\033[32mBuilding Instagram X for sideloading (as IPA)\033[0m'

    IPA_OUT="packages/InstagramX-sideloaded.ipa"
    DISPLAY_NAME="${IX_DISPLAY_NAME:-Instagram X}"
    CHECK_ARGS=()
    if [[ "${IX_LITE:-}" == "1" ]]; then
        unset IX_HAS_XRAY
        export IX_LITE=1
        IPA_OUT="packages/InstagramX-lite-sideloaded.ipa"
        DISPLAY_NAME="${IX_DISPLAY_NAME:-Instagram X Lite}"
        CHECK_ARGS=(--lite)
        echo -e '\033[1m\033[32mLite build: no VPN and no Xray\033[0m'
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        echo -e '\033[1m\033[32mBuilding in-process Xray core\033[0m'
        ./scripts/build_ixray.sh
        export IX_HAS_XRAY=1
    fi

    make $MAKEARGS

    # Only build libs (for future use in dev build mode)
    if [ "$2" == "--buildonly" ];
    then
        exit
    fi

    SCINSTAPATH=".theos/obj/debug/SCInsta.dylib"
    if [ "$2" == "--devquick" ];
    then
        # Exclude SCInsta.dylib from ipa for livecontainer quick builds
        SCINSTAPATH=""
    fi

    # A previous sideload already has SCInsta/FLEX/zxPluginsInject load
    # commands. cyan adds another tweak load instead of replacing it, and
    # ipapatch exits if zxPluginsInject is already loaded. Strip those first.
    # CydiaSubstrate stays; cyan replaces that one framework in place.
    echo -e '\033[1m\033[32mStripping any previous SCInsta injection...\033[0m'
    python3 scripts/strip_previous_tweak.py "packages/${ipaFile}"

    if [[ "${IX_LITE:-}" != "1" ]]; then
        echo -e '\033[1m\033[32mFetching FFmpegKit if it is not already present\033[0m'
        ./scripts/setup-ffmpegkit.sh || echo -e '\033[0;33mFFmpegKit download failed. Media conversion stays off.\033[0m'
    fi
    echo -e '\033[1m\033[32mBuilding InstagramX.bundle\033[0m'
    build_resource_bundle

    # Create IPA File
    echo -e '\033[1m\033[32mCreating the IPA file...\033[0m'
    rm -f "$IPA_OUT" packages/SCInsta-sideloaded.ipa
    cyan -i "packages/${ipaFile}" -o "$IPA_OUT" -f $SCINSTAPATH $FLEXPATH "packages/${BUNDLE_NAME}" -c $COMPRESSION -m 15.0 -du

    # Display name, holographic icon, and optional bundle id (IX_BUNDLE_ID).
    IX_DISPLAY_NAME="$DISPLAY_NAME" python3 scripts/brand_ipa.py "$IPA_OUT" "$DISPLAY_NAME"

    # Patch IPA for sideloading
    ipapatch --input "$IPA_OUT" --inplace --noconfirm

    # Full builds only. No LC_LOAD: the tweak dlopens this after the VPN is on.
    if [[ "${IX_LITE:-}" != "1" && -f vendor/ixray/IXRayCore.dylib ]]; then
        python3 scripts/embed_ixray.py "$IPA_OUT" vendor/ixray/IXRayCore.dylib
    fi

    python3 scripts/check_sideload_ipa.py "$IPA_OUT" "${CHECK_ARGS[@]}"

    echo -e "\033[1m\033[32mDone. Instagram X IPA is ready to sideload.\033[0m\n\nYou can find the ipa file at: $(pwd)/$IPA_OUT"

    # The sideload entry point builds the full IPA, then the lite IPA.
    if [[ "${IX_LITE:-}" != "1" && "$2" != "--dev" && "$2" != "--buildonly" && "$2" != "--devquick" ]]; then
        IX_LITE=1 IX_DISPLAY_NAME="Instagram X Lite" ./build.sh sideload
    fi
    if [[ -n "${IX_BUNDLE_ID:-}" ]]; then
        echo "Bundle id: ${IX_BUNDLE_ID} (installs next to the App Store app)"
    else
        echo "Bundle id unchanged. Set IX_BUNDLE_ID=com.example.instagramx to install beside the official app."
    fi

elif [ "$1" == "rootless" ];
then
    
    # Clean build artifacts
    make clean
    rm -rf .theos

    echo -e '\033[1m\033[32mBuilding Instagram X for rootless (built-in VLESS; Xray ships in the sideload IPA)\033[0m'

    export THEOS_PACKAGE_SCHEME=rootless
    make package
    DEB=$(ls -t packages/*.deb 2>/dev/null | head -1 || true)
    if [ -n "$DEB" ]; then
        echo -e '\033[1m\033[32mAdding InstagramX.bundle to the rootless package\033[0m'
        inject_bundle_into_deb "$DEB"
    fi

    echo -e "\033[1m\033[32mDone. Instagram X rootless package is ready.\033[0m\n\nYou can find the deb file at: $(pwd)/packages"

elif [ "$1" == "rootful" ];
then

    # Clean build artifacts
    make clean
    rm -rf .theos

    echo -e '\033[1m\033[32mBuilding Instagram X for rootful (built-in VLESS; Xray ships in the sideload IPA)\033[0m'

    unset THEOS_PACKAGE_SCHEME
    make package
    DEB=$(ls -t packages/*.deb 2>/dev/null | head -1 || true)
    if [ -n "$DEB" ]; then
        echo -e '\033[1m\033[32mAdding InstagramX.bundle to the rootful package\033[0m'
        inject_bundle_into_deb "$DEB"
    fi

    echo -e "\033[1m\033[32mDone. Instagram X rootful package is ready.\033[0m\n\nYou can find the deb file at: $(pwd)/packages"

else
    echo '+-----------------------+'
    echo '|Instagram X Build Script|'
    echo '+-----------------------+'
    echo
    echo 'Usage: ./build.sh <sideload/rootless/rootful>'
    echo 'Optional: IX_BUNDLE_ID=com.example.instagramx IX_DISPLAY_NAME="Instagram X" ./build.sh sideload'
    exit 1
fi