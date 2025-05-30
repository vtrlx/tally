PACKAGE = ca.vlacroix.Tally
VERSION = 0.5

APPID = $(PACKAGE)
ifdef DEVEL
CFLAGS += -DDEVEL
APPID = $(PACKAGE).Devel
endif

PREFIX = /app

CSRCS = tally.c
LSRCS = tally.lua
POTFILE = po/MESSAGES.pot
MSGS = po/fr.po
MSGDEST = $(patsubst po/%.po, $(PREFIX)/share/locale/%/LC_MESSAGES/messages.mo, $(MSGS))

BIN = tally
OBJS = $(patsubst %.lua, %_bytecode.o, $(LSRCS))
LIBS = -llua -ldl -lm -Wl,-E
CFLAGS = -L$(PREFIX)/lib $(LIBS) -DPACKAGE="$(APPID)" -DVERSION="$(VERSION)"

DESKTOP_FILE = $(APPID).desktop
ICON = $(APPID).svg
SYMBOLIC = $(APPID)-symbolic.svg
METAINFO = $(APPID).metainfo.xml

all: $(BIN)

$(BIN): $(CSRCS) $(OBJS)
	cc -o $@ $^ -L/app/lib $(CFLAGS)

%_bytecode.o: %.bytecode
	ld -r -b binary -o $@ $^

%.bytecode: %.lua
	luac -o $@ -- $^

$(PREFIX)/share/locale/%/LC_MESSAGES/messages.mo: po/%.mo
	@mkdir -p `dirname $@`
	cp $< $@

po/%.mo: po/%.po
	msgfmt $< -o $@

po/%.po: $(POTFILE)
	msgmerge -U $@ $<

po/MESSAGES.pot: $(LSRCS) $(CSRCS)
	xgettext --from-code utf-8 -o $@ $^

.PHONY: clean genmsgs install

clean:
	rm -f tally tally_bytecode.o tally.bytecode

# Updates the .po files with new messages, and should update the .pot file beforehand as well.
genmsgs: $(MSGS)

install: $(BIN) $(MSGDEST)
	install -D -m 0755 -t $(PREFIX)/bin $<
	install -D -m 0644 -t $(PREFIX)/share/applications $(DESKTOP_FILE)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/scalable/apps icons/$(ICON)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/symbolic/apps icons/$(SYMBOLIC)
	install -D -m 0644 -t $(PREFIX)/share/metainfo $(METAINFO)
