ARCHS  = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME                 = 80poolUnlimited
80poolUnlimited_FILES        = Tweak.xm
80poolUnlimited_FRAMEWORKS   = UIKit
80poolUnlimited_LIBRARIES    = substrate
80poolUnlimited_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
