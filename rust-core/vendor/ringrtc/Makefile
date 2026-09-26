#
# Copyright 2019-2021 Signal Messenger, LLC
# SPDX-License-Identifier: AGPL-3.0-only
#

V ?= 0
Q = @
ifneq ($V,0)
	Q =
endif

PREPARE_WORKSPACE ?= 0

USE_PREBUILD ?= 0
BUILD_WHAT := $(BUILD_WHAT)
ifeq ($(USE_PREBUILD), 1)
	BUILD_WHAT = "ringrtc"
endif

BUILD_TYPES := release debug

GN_ARCHS     := arm arm64 x86 x64

help:
	$(Q) echo "The following build targets are supported:"
	$(Q) echo "  ios          -- build for the iOS platform"
	$(Q) echo "  android      -- build for the Android platform"
	$(Q) echo "  electron     -- build an Electron library"
	$(Q) echo "  direct       -- build the direct/1:1 call test cli"
	$(Q) echo "  gctc         -- build the group call test cli"
	$(Q) echo "  call_sim-cli -- build the call simulator test cli"
	$(Q) echo
	$(Q) echo "For release builds, you can also set USE_PREBUILD=1 to download "
	$(Q) echo "a \"prebuild\" of WebRTC and use that instead of downloading and "
	$(Q) echo "building WebRTC. For example:"
	$(Q) echo "  $ TYPE=release make electron USE_PREBUILD=1"
	$(Q) echo "  $ make ios USE_PREBUILD=1"
	$(Q) echo
	$(Q) echo "You can optionally specify TARGET_ARCH for the electron target to "
	$(Q) echo "request a cross-build, but the default is building for the host "
	$(Q) echo "architecture. (see bin/build-desktop for requirements)"
	$(Q) echo
	$(Q) echo "Specify PREPARE_WORKSPACE=1 to request a sync of WebRTC code."
	$(Q) echo "For example:"
	$(Q) echo "  $ make ios PREPARE_WORKSPACE=1"
	$(Q) echo
	$(Q) echo "For the electron/direct/gctc builds, you may also specify a different"
	$(Q) echo "platform for which to download WebRTC. For example:"
	$(Q) echo "  $ make electron PLATFORM=unix PREPARE_WORKSPACE=1"
	$(Q) echo
	$(Q) echo "PREPARE_WORKSPACE=1 is mutually exclusive with USE_PREBUILD=1."
	$(Q) echo
	$(Q) echo "The following clean targets are supported:"
	$(Q) echo "  clean     -- remove all build artifacts"
	$(Q) echo "  distclean -- remove everything"
	$(Q) echo

ifeq ($(PREPARE_WORKSPACE), 1)
android: prepare_workspace
ios: prepare_workspace
electron: prepare_workspace
direct: prepare_workspace
gctc: prepare_workspace
call_sim-cli: prepare_workspace
else ifeq ($(USE_PREBUILD), 1)
android: fetch_artifact
ios: fetch_artifact
electron: fetch_artifact
direct: fetch_artifact
gctc: fetch_artifact
call_sim-cli: fetch_artifact
endif

android: PLATFORM := android
android:
	$(Q) if [ "$(TYPE)" = "debug" ] ; then \
		echo "Android: debug build"; \
		BUILD_WHAT="$(BUILD_WHAT)" ./bin/build-aar --debug; \
	else \
		echo "Android: Release build"; \
		BUILD_WHAT="$(BUILD_WHAT)" ./bin/build-aar --release; \
	fi

ios: PLATFORM := ios
ios:
	$(Q) if [ "$(TYPE)" = "debug" ] ; then \
		echo "iOS: Debug build" ; \
		BUILD_WHAT="$(BUILD_WHAT)" ./bin/build-ios -d ; \
	else \
		echo "iOS: Release build" ; \
		BUILD_WHAT="$(BUILD_WHAT)" ./bin/build-ios ; \
	fi

electron: PLATFORM ?= desktop
electron:
	$(Q) if [ "$(TYPE)" = "debug" ] ; then \
		echo "Electron: Debug build" ; \
		BUILD_WHAT=$(BUILD_WHAT) ./bin/build-desktop -d ; \
	else \
		echo "Electron: Release build" ; \
		BUILD_WHAT=$(BUILD_WHAT) ./bin/build-desktop -r ; \
	fi
	$(Q) (cd src/node && npm install && npm run build)

direct: PLATFORM ?= desktop
direct:
	$(Q) if [ "$(TYPE)" = "release" ] ; then \
		echo "direct: Release build" ; \
		BUILD_WHAT=$(BUILD_WHAT) ./bin/build-desktop -r --direct ; \
	else \
		echo "direct: Debug build" ; \
		BUILD_WHAT=$(BUILD_WHAT) ./bin/build-desktop -d --direct ; \
	fi

gctc: PLATFORM ?= desktop
gctc:
	$(Q) if [ "$(TYPE)" = "release" ] ; then \
		echo "gctc: Release build" ; \
		BUILD_WHAT=$(BUILD_WHAT) ./bin/build-desktop -r --gctc ; \
	else \
		echo "gctc: Debug build" ; \
		BUILD_WHAT=$(BUILD_WHAT) ./bin/build-desktop -d --gctc ; \
	fi

call_sim-cli: PLATFORM ?= desktop
call_sim-cli:
	$(Q) if [ "$(TYPE)" = "debug" ] ; then \
		echo "call_sim-cli: Debug build" ; \
		BUILD_WHAT=$(BUILD_WHAT) ./bin/build-desktop -d --call_sim-cli ; \
	else \
		echo "call_sim-cli: Release build" ; \
		BUILD_WHAT=$(BUILD_WHAT) ./bin/build-desktop -r --call_sim-cli ; \
	fi

PHONY += clean
clean:
	$(Q) ./bin/build-aar --clean
	$(Q) ./bin/build-ios --clean
	$(Q) ./bin/build-desktop --clean
	$(Q) rm -rf ./src/webrtc/src/out

PHONY += distclean
distclean:
	$(Q) rm -rf ./out
	$(Q) rm -rf ./target
	$(Q) rm -rf ./src/node/build
	$(Q) rm -rf ./src/node/dist
	$(Q) rm -rf ./src/node/node_modules
	$(Q) rm -rf ./src/webrtc/src/out

PHONY += prepare_workspace
prepare_workspace:
	$(Q) ./bin/prepare-workspace "$(PLATFORM)"

PHONY += fetch_artifact
fetch_artifact:
	$(Q) ./bin/fetch-artifact -p "$(PLATFORM)"

.PHONY: $(PHONY)
