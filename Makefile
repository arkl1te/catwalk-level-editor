# Catwalk — build with `make`, run with `make run`.
# Requires: nim >= 2.2, git, mesa/libGL, libX11, libXrandr, mono (for OniSplit).

NIM      ?= nim
BIN      := catwalk
SRC      := src/catwalk.nim
NIMFLAGS ?= -d:release

.PHONY: all deps run debug clean install uninstall

all: $(BIN)

deps:
	./tools/fetch_deps.sh
	touch vendor/.stamp

$(BIN): VERSION config.nims deps.lock $(wildcard tools/*.sh) $(wildcard patches/*.patch) $(wildcard src/*.nim) assets/fonts/IBMPlexSans-Regular.ttf assets/fonts/IBMPlexMono-Regular.ttf assets/catwalk.svg assets/logo-paths.svg
	@./tools/build.sh $(NIM) c $(NIMFLAGS) -o:$(BIN) $(SRC)

# Pixie can't render <text> and only takes whole-pixel sizes, so the logo is built
# with its text as paths and its width/height/viewBox rounded up (needs Inkscape and the Dirga font).
assets/logo-paths.svg: assets/logo.svg
	inkscape $< --export-text-to-path --export-plain-svg --export-area-drawing --export-filename=$@
	perl -0777 -pi -e 's{<svg\b[^>]*>}{$$& =~ s/\b(width|height|viewBox)="([^"]*)"/qq{$$1="} . join(" ", map { int($$_ + 0.999) } split " ", $$2) . q{"}/ger}e' $@

debug:
	@./tools/build.sh $(NIM) c -d:debug -o:$(BIN) $(SRC)

run: $(BIN)
	./$(BIN)

clean:
	rm -f $(BIN)

PREFIX ?= $(HOME)/.local
install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(PREFIX)/bin/$(BIN)
	install -Dm644 assets/catwalk.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/$(BIN).svg
	install -Dm644 assets/catwalk.desktop $(DESTDIR)$(PREFIX)/share/applications/$(BIN).desktop

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(BIN)
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/$(BIN).svg
	rm -f $(DESTDIR)$(PREFIX)/share/applications/$(BIN).desktop
