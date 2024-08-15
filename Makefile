BIN = tally
CSRCS = tally.c tally_lua.o
LSRCS = tally.lua
CFLAGS = -llua -ldl -lm -Wl,-E

APPID = ca.vlacroix.Tally
ifdef DEVEL
CFLAGS += -DDEVEL
APPID = ca.vlacroix.Tally.Devel
endif

PREFIX ?= ~/.local

all: $(BIN)

$(BIN): $(CSRCS)
	cc -o $@ $(CSRCS) -L/app/lib $(CFLAGS)

cheveret_lua.o: $(LSRCS)
	luac -o tally.lc -- $<
	ld -r -b binary -o $@ tally.lc

.PHONY: clean install

clean:
	rm -f tally tally_lua.o tally.lc

install: $(BIN) $(DESKTOP_FILE) $(ICON_FILE) $(SYMICON)
	install -D -m 0755 -t $(PREFIX)/bin $<
