# Trail — build, test, install.
#   make app TEAM=ABCDE12345   sign with your Apple Development certificate (enables the widget)
#   make app                    ad-hoc signed build (everything but the widget)

CONFIG ?= Release
DERIVED := build
APP := $(DERIVED)/Build/Products/$(CONFIG)/Trail.app
VERSION := $(shell grep MARKETING_VERSION App/project.yml | head -1 | sed 's/.*"\(.*\)"/\1/')

.PHONY: help setup all app cli test project install install-cli dmg demo run clean
.DEFAULT_GOAL := help

help:
	@echo "Trail $(VERSION)"
	@echo ""
	@echo "  make setup          check Xcode and install XcodeGen"
	@echo "  make install        build the app and put it in /Applications"
	@echo "  make install TEAM=X same, signed with your Apple Development team (adds the widget)"
	@echo "  make install-cli    build the trail command into ~/.local/bin"
	@echo "  make test           run the engine tests"
	@echo "  make run            debug build, launched"
	@echo "  make demo           re-record the README GIFs against made-up files"
	@echo "  make dmg            package dist/Trail-$(VERSION).dmg"
	@echo "  make clean          remove build output"

setup:
	@xcodebuild -version 2>/dev/null | head -1 | grep -qE "Xcode (2[6-9]|[3-9][0-9])" \
		|| { echo "Needs Xcode 26 or later (App Store), then: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
	@command -v xcodegen >/dev/null || brew install xcodegen
	@echo "Ready. Next: make install"

all: app cli

project:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
ifdef TEAM
	@printf 'DEVELOPMENT_TEAM = $(TEAM)\nCODE_SIGN_IDENTITY = Apple Development\nTRAIL_APP_GROUP = $$(DEVELOPMENT_TEAM).trail\nTRAIL_APP_ENTITLEMENTS = Trail/Trail.entitlements\nTRAIL_WIDGET_ENTITLEMENTS = TrailWidget/TrailWidget.entitlements\n' > App/Config/Local.xcconfig
endif
	cd App && xcodegen generate --quiet

app: project
	xcodebuild -project App/Trail.xcodeproj -scheme Trail -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build | grep -E "error|warning: .*Trail|BUILD" || true
	@test -d "$(APP)" && echo "Built $(APP)"

cli:
	swift build -c release
	@echo "Built .build/release/trail"

test:
	swift test

install: app
	@pkill -x Trail || true
	rm -rf /Applications/Trail.app
	cp -R "$(APP)" /Applications/
	open /Applications/Trail.app
	@echo "Installed. Press ⌥Space to search."

install-cli: cli
	mkdir -p $(HOME)/.local/bin
	cp .build/release/trail $(HOME)/.local/bin/trail
	@echo "Installed ~/.local/bin/trail (make sure it's on your PATH)"

demo: app
	scripts/demo/record.sh

dmg: app
	scripts/make-dmg.sh "$(APP)" "dist/Trail-$(VERSION).dmg"

run: CONFIG = Debug
run: app
	@pkill -x Trail || true
	open "$(APP)"

clean:
	rm -rf $(DERIVED) .build dist App/Trail.xcodeproj
