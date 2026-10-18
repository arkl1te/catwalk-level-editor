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

$(BIN): VERSION deps.lock $(wildcard tools/*.sh) $(wildcard patches/*.patch) $(wildcard src/*.nim) assets/fonts/IBMPlexSans-Regular.ttf assets/catwalk.svg
	@./tools/build.sh $(NIM) c $(NIMFLAGS) -o:$(BIN) $(SRC)

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
