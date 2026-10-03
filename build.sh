#!/usr/bin/env bash

set -e

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

    # Create IPA File
    echo -e '\033[1m\033[32mCreating the IPA file...\033[0m'
    rm -f "$IPA_OUT" packages/SCInsta-sideloaded.ipa
    cyan -i "packages/${ipaFile}" -o "$IPA_OUT" -f $SCINSTAPATH $FLEXPATH -c $COMPRESSION -m 15.0 -du

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

    echo -e "\033[1m\033[32mDone. Instagram X rootless package is ready.\033[0m\n\nYou can find the deb file at: $(pwd)/packages"

elif [ "$1" == "rootful" ];
then

    # Clean build artifacts
    make clean
    rm -rf .theos

    echo -e '\033[1m\033[32mBuilding Instagram X for rootful (built-in VLESS; Xray ships in the sideload IPA)\033[0m'

    unset THEOS_PACKAGE_SCHEME
    make package

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