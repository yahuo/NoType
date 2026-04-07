APP_NAME := NoType.app
DIST_APP := dist/$(APP_NAME)
INSTALL_APP := /Applications/$(APP_NAME)

.PHONY: build run install package notarize site-serve clean

build:
	./scripts/build_app.sh

run: build
	open -n "$(DIST_APP)"

install: build
	rm -rf "$(INSTALL_APP)"
	ditto "$(DIST_APP)" "$(INSTALL_APP)"

package:
	./scripts/package_release.sh

notarize:
	./scripts/notarize_release.sh

site-serve:
	python3 -m http.server 4173 -d site

clean:
	rm -rf .build dist
