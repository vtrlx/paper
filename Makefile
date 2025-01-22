PREFIX = /app

BIN = parchment
CSRCS = parchment.c
OBJS = parchment_bytecode.o
LIBS = -llua -ldl -lm
CFLAGS = $(LIBS) -Wl,-E

APPID = ca.vlacroix.Parchment
ifdef DEVEL
CFLAGS += -DDEVEL
APPID = ca.vlacroix.Parchment.Devel
endif

DESKTOP_FILE = $(APPID).desktop
ICON = $(APPID).svg
SYMBOLIC = $(APPID)-symbolic.svg

all: $(BIN)

$(BIN): $(CSRCS) $(OBJS)
	cc -o $@ $^ -L/app/lib $(CFLAGS)

%_bytecode.o: %.bytecode
	ld -r -b binary -o $@ $<

%.bytecode: %.lua
	luac -o $@ -- $<

.PHONY: clean install

clean:
	rm -f $(BIN) $(OBJS) *.bytecode

install: $(BIN) $(DESKTOP_FILE) $(ICON_FILE) $(SYMICON)
	install -D -m 0755 -t $(PREFIX)/bin $<
	install -D -m 0644 -t $(PREFIX)/share/applications $(DESKTOP_FILE)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/128x128/apps icons/$(ICON)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/symbolic/apps icons/$(SYMBOLIC)
