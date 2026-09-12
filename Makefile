PROJECT := LinkGate.xcodeproj
SCHEME := LinkGate
CONFIGURATION := Debug
DERIVED_DATA_PATH := build/DerivedData
HOST_ARCH := $(shell uname -m)
MACOS_DESTINATION := platform=macOS,arch=$(HOST_ARCH)

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(MACOS_DESTINATION)' -derivedDataPath $(DERIVED_DATA_PATH)

.PHONY: build test verify release-tests run release

build:
	$(XCODEBUILD) build

run: build
	open $(DERIVED_DATA_PATH)/Build/Products/$(CONFIGURATION)/LinkGate.app

test:
	$(XCODEBUILD) test

verify:
	@status=0; \
	$(XCODEBUILD) build || status=$$?; \
	$(XCODEBUILD) test || status=$$?; \
	./scripts/release/tests/release-support-tests.sh || status=$$?; \
	./scripts/release/tests/release-preflight-tests.sh || status=$$?; \
	./scripts/release/tests/release-workflow-tests.sh || status=$$?; \
	./scripts/release/tests/release-interface-tests.sh || status=$$?; \
	exit $$status

release-tests:
	./scripts/release/tests/release-support-tests.sh
	./scripts/release/tests/release-preflight-tests.sh
	./scripts/release/tests/release-workflow-tests.sh
	./scripts/release/tests/release-interface-tests.sh

release:
	./scripts/release/release.sh
