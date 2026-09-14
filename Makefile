PROJECT := LinkGate.xcodeproj
SCHEME := LinkGate
CONFIGURATION := Debug
DERIVED_DATA_PATH := build/DerivedData
HOST_ARCH := $(shell uname -m)
MACOS_DESTINATION := platform=macOS,arch=$(HOST_ARCH)

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination '$(MACOS_DESTINATION)' -derivedDataPath $(DERIVED_DATA_PATH) -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates

.PHONY: build test verify release-tests publish-beta-tests publish-beta-check publish-beta verify-published-beta run release

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
	./scripts/release/tests/sparkle-integration-tests.sh || status=$$?; \
	./scripts/release/tests/publish-beta-tests.sh || status=$$?; \
	exit $$status

release-tests:
	./scripts/release/tests/release-support-tests.sh
	./scripts/release/tests/release-preflight-tests.sh
	./scripts/release/tests/release-workflow-tests.sh
	./scripts/release/tests/release-interface-tests.sh
	./scripts/release/tests/sparkle-integration-tests.sh
	./scripts/release/tests/publish-beta-tests.sh

publish-beta-tests:
	./scripts/release/tests/publish-beta-tests.sh

publish-beta-check:
	./scripts/release/publish-beta-check.sh

publish-beta:
	./scripts/release/publish-beta.sh

verify-published-beta:
	./scripts/release/verify-published-beta.sh

release:
	./scripts/release/release.sh
