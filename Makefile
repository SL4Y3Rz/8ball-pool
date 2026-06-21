ARCHS  = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME                 = 8ball-pool
8ball-pool_FILES        = Tweak.xm
8ball-pool_FRAMEWORKS   = UIKit
8ball-pool_LIBRARIES    = substrate
8ball-pool_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
