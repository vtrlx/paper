BIN = cheveret
CSRCS = cheveret.c linotify.c cheveret_lua.o
LSRCS = cheveret.lua
CFLAGS = -llua -ldl -lm -Wl,-E
DESKTOP_FILE = ca.vlacroix.Cheveret.desktop

ifdef DEVEL
CFLAGS += -DDEVEL
DESKTOP_FILE = ca.vlacroix.Cheveret.Devel.desktop
endif

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

install: $(BIN) $(DESKTOP_FILE)
	install -D -m 0755 -t $(PREFIX)/bin $<
	install -D -m 0644 -t $(PREFIX)/share/applications $(DESKTOP_FILE)
