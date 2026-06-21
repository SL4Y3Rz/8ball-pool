ARCHS  = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME                = 80poolUnlimited
80poolUnlimited_FILES     = Tweak.xm
80poolUnlimited_FRAMEWORKS = UIKit Foundation
80poolUnlimited_LIBRARIES  = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

