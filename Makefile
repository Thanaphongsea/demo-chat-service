DESTINATION := platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5
XCODEBUILD = xcodebuild -project ChatCall.xcodeproj -scheme ChatCall -destination '$(DESTINATION)' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
SWIFT_PATHS = ChatCall ChatCallTests ChatCallUITests

.PHONY: generate build test-unit test-ui format-check lint

generate:
	xcodegen generate --spec project.yml

build:
	$(XCODEBUILD) build

test-unit:
	$(XCODEBUILD) test -only-testing:ChatCallTests -parallel-testing-enabled NO

test-ui:
	$(XCODEBUILD) test -only-testing:ChatCallUITests -parallel-testing-enabled NO

format-check:
	xcrun swift-format lint --strict --recursive $(SWIFT_PATHS)

lint:
	swiftlint lint --strict $(SWIFT_PATHS)
