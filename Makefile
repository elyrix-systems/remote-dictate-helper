.PHONY: build test install install-local setup-local-signing privacy-scan icon package
build:
	./scripts/build-menubar-app.zsh

test:
	python3 -m unittest discover -s scripts/tests
	./scripts/test.zsh

install-local:
	./scripts/install-local.zsh

install:
	./scripts/install.zsh

package:
	./scripts/package-dmg.zsh

setup-local-signing:
	./scripts/setup-local-signing.zsh

privacy-scan:
	./scripts/privacy-scan.zsh

icon:
	./scripts/generate-app-icon.zsh assets/RemoteDictateHelper.icns
