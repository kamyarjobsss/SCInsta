TARGET := iphone:clang:16.2
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Instagram

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = InstagramXAddon

# No Logos and no CydiaSubstrate. ObjC hooks are method_setImplementation.
# Socket hooks live in IXSymbolRebind and run only while the VPN is on.
$(TWEAK_NAME)_FILES = \
	../src/Launch/IXLaunchGuard.m \
	../src/Brand/IXBrand.m \
	../src/Proxy/IXVLESSProfile.m \
	../src/Proxy/IXSymbolRebind.m \
	../src/Proxy/IXRayLoader.m \
	../src/Proxy/IXNativeEngine.m \
	../src/Proxy/IXTrafficGuard.m \
	../src/Proxy/IXProxyManager.m \
	../src/Proxy/IXProxyViewController.m \
	../src/Location/IXLocationStore.m \
	../src/Location/IXLocationPickerViewController.m \
	../src/Features/General/IXSettingsEntry.m \
	IXAddon.m \
	IXAddonSettings.m \
	IXAddonSwizzle.m

$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore CoreLocation MapKit Security SystemConfiguration
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -DIX_ADDON=1 -Wno-deprecated-declarations -Wno-unused-function
ifeq ($(IX_HAS_XRAY),1)
  $(TWEAK_NAME)_CFLAGS += -DIX_HAS_XRAY=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk
