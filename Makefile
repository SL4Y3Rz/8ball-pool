THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES = MiniclipPool

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxiomPool

AxiomPool_FILES = Tweak.xm
AxiomPool_CFLAGS = -fobjc-arc \
    -Wno-unused-function \
    -Wno-unused-variable \
    -Wno-ignored-attributes
AxiomPool_CCFLAGS = -std=c++17
AxiomPool_FRAMEWORKS = UIKit CoreGraphics QuartzCore
AxiomPool_PRIVATE_FRAMEWORKS = GraphicsServices
AxiomPool_LIBRARIES = substrate

include $(THEOS)/makefiles/tweak.mk
