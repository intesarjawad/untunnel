# Builds the Untunnel audio server plug-in into .build/driver/Untunnel.driver, signed ad hoc.
#
# LIVENESS picks what takes the microphone away when the app is gone: `writes` (no write to
# the feed for 2 s) or `clients` (the last client leaves the feed device).
# `install` and `uninstall` use sudo and restart coreaudiod; they are for development.

VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ../Support/Info.plist)
LIVENESS ?= writes

CORE := ../Sources/UntunnelDriverCore
BUILD := ../.build/driver
BUNDLE := $(BUILD)/Untunnel.driver
HAL := /Library/Audio/Plug-Ins/HAL

ifeq ($(LIVENESS),clients)
LIVENESS_FLAG := -DUNTUNNEL_LIVENESS_BY_CLIENTS=1
else ifeq ($(LIVENESS),writes)
LIVENESS_FLAG := -DUNTUNNEL_LIVENESS_BY_CLIENTS=0
else
$(error LIVENESS must be writes or clients)
endif

CFLAGS := -std=c11 -O2 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=15.0 \
	-fvisibility=default -I$(CORE)/include \
	-DUNTUNNEL_DRIVER_VERSION='"$(VERSION)"' $(LIVENESS_FLAG)

# The bundle always rebuilds, so a changed LIVENESS or VERSION can never install a stale build.
.PHONY: all clean install uninstall $(BUNDLE)

all: $(BUNDLE)

$(BUNDLE):
	rm -rf $@
	mkdir -p $@/Contents/MacOS
	sed 's/@VERSION@/$(VERSION)/g' Info.plist > $@/Contents/Info.plist
	xcrun clang $(CFLAGS) -bundle -o $@/Contents/MacOS/Untunnel Untunnel.c $(CORE)/DriverCore.c \
		-framework CoreAudio -framework CoreFoundation
	codesign --force --sign - $@
	codesign --verify --strict $@

clean:
	rm -rf $(BUILD)

install: $(BUNDLE)
	sudo rm -rf $(HAL)/Untunnel.driver
	sudo cp -R $(BUNDLE) $(HAL)/Untunnel.driver
	sudo killall coreaudiod

uninstall:
	sudo rm -rf $(HAL)/Untunnel.driver
	sudo killall coreaudiod
