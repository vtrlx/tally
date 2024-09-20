PREFIX = /app

CSRCS = tally.c
LSRCS = tally.lua

BIN = tally
OBJS = $(patsubst %.lua, %_bytecode.o, $(LSRCS))
LIBS = -llua -ldl -lm -Wl,-E
CFLAGS = -L$(PREFIX)/lib $(LIBS)

APPID = ca.vlacroix.Tally
ifdef DEVEL
CFLAGS += -DDEVEL
APPID = ca.vlacroix.Tally.Devel
endif

DESKTOP_FILE = $(APPID).desktop
ICON = $(APPID).svg
SYMBOLIC = $(APPID)-symbolic.svg

all: $(BIN)

$(BIN): $(CSRCS) $(OBJS)
	cc -o $@ $^ -L/app/lib $(CFLAGS)

%_bytecode.o: %.bytecode
	ld -r -b binary -o $@ $^

%.bytecode: %.lua
	luac -o $@ -- $^

.PHONY: clean install

clean:
	rm -f tally tally_bytecode.o tally.bytecode

install: $(BIN) $(DESKTOP_FILE) $(ICON_FILE) $(SYMICON)
	install -D -m 0755 -t $(PREFIX)/bin $<
	install -D -m 0644 -t $(PREFIX)/share/applications $(DESKTOP_FILE)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/symbolic/apps icons/$(ICON)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/symbolic/apps icons/$(SYMBOLIC)
