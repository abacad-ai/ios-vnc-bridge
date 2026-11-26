.PHONY: test engine app dmg run clean

VERSION ?= 0.1.0

test:
	go test ./...
	swift build -c release --package-path app

engine:
	mkdir -p build
	go build -trimpath -ldflags "-s -w" -o build/engine ./cmd/engine

# Build the menu-bar app (ad-hoc signed). CODESIGN_ID=... signs for distribution.
app:
	VERSION=$(VERSION) ./scripts/build-app.sh

dmg:
	VERSION=$(VERSION) DMG=1 ./scripts/build-app.sh

# Run from the checkout: the app finds the engine in build/ and the bridge in bridge/.
run: engine
	IOSVNC_BRIDGE_ROOT=$(CURDIR) swift run --package-path app

clean:
	rm -rf build app/.build
