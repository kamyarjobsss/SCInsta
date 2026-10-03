TARGET := iphone:clang:16.2
INSTALL_TARGET_PROCESSES = Instagram
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SCInsta

$(TWEAK_NAME)_FILES = $(shell find src -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \)) $(wildcard modules/JGProgressHUD/*.m) modules/fishhook/fishhook.c
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreGraphics Photos CoreServices SystemConfiguration SafariServices Security QuartzCore AVFoundation UniformTypeIdentifiers CoreLocation MapKit WebKit
$(TWEAK_NAME)_PRIVATE_FRAMEWORKS = Preferences
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-unsupported-availability-guard -Wno-unused-value -Wno-deprecated-declarations -Wno-nullability-completeness -Wno-unused-function -Wno-incompatible-pointer-types -include src/SCIPrefix.h
$(TWEAK_NAME)_LOGOSFLAGS = --c warnings=none

# Xray is IXRayCore.dylib, dlopened only while the VPN is on.
ifeq ($(IX_LITE),1)
  $(TWEAK_NAME)_CFLAGS += -DIX_LITE=1
else
  ifeq ($(IX_HAS_XRAY),1)
    $(TWEAK_NAME)_CFLAGS += -DIX_HAS_XRAY=1
  endif
endif

CCFLAGS += -std=c++11

include $(THEOS_MAKE_PATH)/tweak.mk

# Build FLEXing for sideloading (not building in dev-mode)
ifdef SIDELOAD
	$(TWEAK_NAME)_SUBPROJECTS += modules/flexing
endif