.PHONY: help get gen analyze test e2e apk apk-release release-publish

MOBILE = mobile
APK_RELEASE = $(MOBILE)/build/app/outputs/flutter-apk/app-release.apk
DIST = dist
REPO ?= kamrul1157024/get-on-it
VERSION ?=
DEVICE ?=

help:
	@grep -E '^## ' Makefile | sed 's/^## //'

## get            Install Flutter packages
get:
	cd $(MOBILE) && flutter pub get

## gen            Regenerate drift code after a schema change
gen:
	cd $(MOBILE) && dart run build_runner build

## analyze        Static analysis (infos do not fail)
analyze:
	cd $(MOBILE) && flutter analyze --no-fatal-infos

## test           Unit, widget and host flow tests
test:
	cd $(MOBILE) && flutter test

## e2e            End-to-end tests on a running emulator or device (DEVICE=emulator-5554)
e2e:
	cd $(MOBILE) && flutter test integration_test $(if $(DEVICE),-d $(DEVICE),)

## apk            Debug APK (installs beside the release app as app.getonit.dev)
apk:
	cd $(MOBILE) && flutter build apk --debug

## apk-release    Signed release APK: VERSION=x.y.z, plus KEYSTORE_PATH and passwords in the environment
apk-release:
	@printf '%s' "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$' || \
		(echo "Error: apk-release needs VERSION=x.y.z — try VERSION=\`./scripts/next-version.sh patch\`" >&2 && exit 1)
	cd $(MOBILE) && flutter build apk --release \
		--build-name=$(VERSION) \
		--build-number=$(shell git rev-list --count HEAD) \
		--dart-define=APP_VERSION=$(VERSION) \
		--dart-define=GOOGLE_SERVER_CLIENT_ID=$(GOOGLE_SERVER_CLIENT_ID)

## release-publish  Create the GitHub release v$(VERSION) from what is staged in dist/
release-publish:
	@printf '%s' "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$' || \
		(echo "Error: VERSION is \"$(VERSION)\", not a plain x.y.z" >&2 && exit 1)
	@ls $(DIST)/* > /dev/null 2>&1 || (echo "Error: nothing staged in $(DIST)/" >&2 && exit 1)
	@if gh release view v$(VERSION) --repo $(REPO) > /dev/null 2>&1; then \
		echo "Error: release v$(VERSION) already exists" >&2; exit 1; \
	fi
	gh release create v$(VERSION) \
		--repo $(REPO) \
		--title "Get On It v$(VERSION)" \
		--generate-notes \
		$(DIST)/*
