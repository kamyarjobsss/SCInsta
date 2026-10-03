TARGET := iphone:clang:16.2
INSTALL_TARGET_PROCESSES = Instagram
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SCInsta

$(TWEAK_NAME)_FILES = $(shell find src -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \)) $(wildcard modules/JGProgressHUD/*.m)
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreGraphics Photos CoreServices SystemConfiguration SafariServices Security QuartzCore MapKit CoreLocation WebKit
$(TWEAK_NAME)_PRIVATE_FRAMEWORKS = Preferences
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-unsupported-availability-guard -Wno-unused-value -Wno-deprecated-declarations -Wno-nullability-completeness -Wno-unused-function -Wno-incompatible-pointer-types
$(TWEAK_NAME)_LOGOSFLAGS = --c warnings=none

# Optional in-process Xray core. scripts/build_ixray.sh produces this archive on macOS.
# CFLAGS must be appended after the assignment above, or -DIX_HAS_XRAY is lost.
IXRAY_LIB := $(THEOS_PROJECT_DIR)/vendor/ixray/libixray.a
ifeq ($(IX_HAS_XRAY),1)
  ifeq ($(wildcard $(IXRAY_LIB)),)
    $(error IX_HAS_XRAY=1 but $(IXRAY_LIB) was not built)
  endif
  $(TWEAK_NAME)_CFLAGS += -DIX_HAS_XRAY=1
  $(TWEAK_NAME)_LDFLAGS += -Wl,-force_load,$(IXRAY_LIB) -Wl,-no_dead_strip_inits_and_terms -lz -lresolv -liconv -lc++
endif

CCFLAGS += -std=c++11

include $(THEOS_MAKE_PATH)/tweak.mk

# Build FLEXing for sideloading (not building in dev-mode)
ifdef SIDELOAD
	$(TWEAK_NAME)_SUBPROJECTS += modules/flexing
endif