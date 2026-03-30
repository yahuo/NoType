APP_NAME := NoType.app
DIST_APP := dist/$(APP_NAME)
INSTALL_APP := /Applications/$(APP_NAME)

.PHONY: build run install clean

build:
	./scripts/build_app.sh

run: build
	open -n "$(DIST_APP)"

install: build
	rm -rf "$(INSTALL_APP)"
	cp -R "$(DIST_APP)" "$(INSTALL_APP)"
	codesign --force --deep --sign - "$(INSTALL_APP)"

clean:
	rm -rf .build dist
