APP_NAME   := NotchPipe
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
CONFIG     ?= release
SWIFT_BIN   = $(shell swift build -c $(CONFIG) --arch arm64 --show-bin-path)

.PHONY: all build app run test dmg clean kill

all: app

build:
	swift build -c $(CONFIG) --arch arm64

app: build
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$(SWIFT_BIN)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	@cp Info.plist "$(APP)/Contents/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(APP)/Contents/Resources/"; fi
	@codesign --force --deep -s - "$(APP)"
	@echo "Built $(APP)"

kill:
	@pkill -x $(APP_NAME) 2>/dev/null || true

run: app kill
	@open "$(APP)"

test:
	swift test

dmg: app
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(APP)" -ov -format UDZO "$(BUILD_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf .build $(BUILD_DIR)
