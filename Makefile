APP := OpenKlack
BUILD := .build/release
BUNDLE := dist/$(APP).app

.PHONY: all build bundle test sounds clean run

all: bundle

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(APP) $(BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(BUNDLE)/Contents/
	cp -R Resources/Sounds $(BUNDLE)/Contents/Resources/Sounds
	codesign --force --sign - $(BUNDLE)
	@du -sh $(BUNDLE)

# Rebuild the sound catalog from upstream sources (requires uv + network).
sounds:
	uv run --with soundfile,numpy scripts/build_sounds.py

# Headless audio smoke test: decodes and plays every pack.
test: bundle
	$(BUNDLE)/Contents/MacOS/$(APP) --test-audio

run: bundle
	open $(BUNDLE)

clean:
	rm -rf .build dist/$(APP).app
