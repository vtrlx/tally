PREFIX = /app

BIN = tally
CSRCS = tally.c
OBJS = tally_bytecode.o
LSRCS = tally.lua
LIBS = -llua -ldl -lm -Wl,-E
CFLAGS = -L$(PREFIX)/lib $(LIBS)

APPID = ca.vlacroix.Tally
ifdef DEVEL
CFLAGS += -DDEVEL
APPID = ca.vlacroix.Tally.Devel
endif

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
