BIN = cheveret
CSRCS = cheveret.c linotify.c cheveret_lua.o
LSRCS = cheveret.lua
CFLAGS = -llua -ldl -lm -Wl,-E

APPID = ca.vlacroix.Cheveret
ifdef DEVEL
CFLAGS += -DDEVEL
APPID = ca.vlacroix.Cheveret.Devel
endif

DESKTOP_FILE = $(APPID).desktop
ICON = $(APPID).png
SYMBOLIC = $(APPID)-symbolic.svg

PREFIX ?= ~/.local

all: $(BIN)

$(BIN): $(CSRCS)
	cc -o $@ $(CSRCS) -L/app/lib $(CFLAGS)

cheveret_lua.o: $(LSRCS)
	luac -o cheveret.lc -- $<
	ld -r -b binary -o $@ cheveret.lc

.PHONY: clean install

clean:
	rm -f cheveret cheveret_lua.o cheveret.lc

install: $(BIN) $(DESKTOP_FILE) $(ICON_FILE) $(SYMICON)
	install -D -m 0755 -t $(PREFIX)/bin $<
	install -D -m 0644 -t $(PREFIX)/share/applications $(DESKTOP_FILE)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/128x128/apps icons/$(ICON)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/symbolic/apps icons/$(SYMBOLIC)
