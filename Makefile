APP        := Xem
BUNDLE_ID  := com.barkbarkgoose.xem
VERSION    := 0.1.0
BIN        := xem
BUILD_DIR  := build
APP_DIR    := $(BUILD_DIR)/$(APP).app
CONTENTS   := $(APP_DIR)/Contents
SWIFT_FLAGS :=
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all build bundle sign install install-cli set-default uninstall clean

all: install install-cli

build:
	swift build -c release $(SWIFT_FLAGS)

bundle: build
	rm -rf $(APP_DIR)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp .build/release/$(BIN) $(CONTENTS)/MacOS/$(BIN)
	cp -R Resources/web $(CONTENTS)/Resources/web
	printf '%s' 'APPL????' > $(CONTENTS)/PkgInfo
	./scripts/make-plist.sh "$(APP)" "$(BUNDLE_ID)" "$(VERSION)" "$(BIN)" > $(CONTENTS)/Info.plist
	plutil -lint $(CONTENTS)/Info.plist

# Ad-hoc signature. Not for distribution -- LaunchServices wants a stable
# identity, and an unsigned bundle's .md association tends not to survive a
# rebuild.
sign: bundle
	codesign --force --sign - --timestamp=none $(APP_DIR)
	codesign --verify --verbose=1 $(APP_DIR)

install: sign
	rm -rf /Applications/$(APP).app
	cp -R $(APP_DIR) /Applications/
	$(LSREGISTER) -f /Applications/$(APP).app
	@echo
	@echo "Installed /Applications/$(APP).app"
	@echo "To make it the default: right-click any .md -> Get Info -> Open With -> $(APP) -> Change All."

install-cli:
	mkdir -p $$HOME/.local/bin
	ln -sf $(CURDIR)/scripts/xem $$HOME/.local/bin/xem
	@echo "Linked xem -> ~/.local/bin/xem"

# Opt-in: takes the system-wide .md association away from whatever holds it now.
set-default:
	swift scripts/set-default.swift

# `lsregister -kill` was removed by Apple; unregister the bundle explicitly
# instead, before deleting it.
uninstall:
	-$(LSREGISTER) -u /Applications/$(APP).app
	rm -rf /Applications/$(APP).app
	rm -f $$HOME/.local/bin/xem
	@echo "Uninstalled $(APP)."


clean:
	rm -rf .build $(BUILD_DIR)
