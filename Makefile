# Douyin Lucky Bag Helper - Theos tweak
#
# Design note: this tweak deliberately avoids hooking ANY Douyin class.
# Everything is driven by screen capture + Vision OCR + hit-testing, so a
# Douyin update only invalidates OCR keywords, not class names.

export TARGET := iphone:clang:latest:15.0
export ARCHS  := arm64 arm64e
export THEOS_PACKAGE_SCHEME := rootless

INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

# arm64e: clang 17 signs the class_ro pointer of every Objective-C class, and
# only libobjc from iOS 17 on authenticates that slot. Older runtimes dereference
# the signed pointer as-is, so the injected process dies in readClass() while dyld
# maps the tweak. Probe rather than hardcode — clangs that reject the flag do not
# emit the signing either.
DY_PTRAUTH_CFLAGS := $(shell $(TARGET_CC) -x objective-c -fsyntax-only -fno-ptrauth-objc-class-ro /dev/null >/dev/null 2>&1 && echo -fno-ptrauth-objc-class-ro)
export DY_PTRAUTH_CFLAGS

TWEAK_NAME = DYLuckyBag

DYLuckyBag_FILES = \
	DYLuckyBag.xm \
	DYConfig.m \
	DYOCRDetector.m \
	DYTouch.m \
	DYEngine.m \
	DYPanel.m \
	DYLog.m

DYLuckyBag_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unsupported-availability-guard $(DY_PTRAUTH_CFLAGS)
DYLuckyBag_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO Vision

include $(THEOS_MAKE_PATH)/tweak.mk
