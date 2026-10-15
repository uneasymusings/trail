# Trail — build, test, install.
#   make app TEAM=ABCDE12345   sign with your Apple Development certificate (enables the widget)
#   make app                    ad-hoc signed build (everything but the widget)

CONFIG ?= Release
DERIVED := build
APP := $(DERIVED)/Build/Products/$(CONFIG)/Trail.app
VERSION := $(shell grep MARKETING_VERSION App/project.yml | head -1 | sed 's/.*"\(.*\)"/\1/')

.PHONY: all app cli test project install install-cli dmg run clean

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

dmg: app
	scripts/make-dmg.sh "$(APP)" "dist/Trail-$(VERSION).dmg"

run: CONFIG = Debug
run: app
	@pkill -x Trail || true
	open "$(APP)"

clean:
	rm -rf $(DERIVED) .build dist App/Trail.xcodeproj
