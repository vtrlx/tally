PACKAGE = ca.vlacroix.Tally
VERSION = 0.7.1

APPID = $(PACKAGE)
ifdef DEVEL
CFLAGS = -DDEVEL
APPID = $(PACKAGE).Devel
endif

PREFIX = /app

CSRCS = $(wildcard *.c)
LSRCS = $(wildcard *.lua)
POTFILE = po/MESSAGES.pot
POFILES = $(wildcard po/*.po)
MOFILES = \
	$(patsubst po/%.po, \
	locale/%/LC_MESSAGES/messages.mo, \
	$(POFILES))

BIN = tally
BYTECODE = $(patsubst %.lua, %.bytecode, $(LSRCS))
LIBS = -llua -ldl -lm -Wl,-E
CFLAGS += -L$(PREFIX)/lib $(LIBS) -DPACKAGE="$(APPID)" -DVERSION="$(VERSION)"

DESKTOP_FILE = $(APPID).desktop
ICON = $(APPID).svg
SYMBOLIC = $(APPID)-symbolic.svg
METAINFO = $(APPID).metainfo.xml

all: $(BIN)

$(BIN): $(CSRCS) $(BYTECODE)
	cc -o $@ $(CSRCS) -L/app/lib $(CFLAGS)

%.bytecode: %.lua
	luac -o $@ -- $^

locale/%/LC_MESSAGES/messages.mo: po/%.po
	@mkdir -p `dirname $@`
	msgfmt $< -o $@

po/%.po: $(POTFILE)
	[ -f $@ ] || msginit -i $< -o $@ -l $(patsubst po/%.po,%,$@)
	msgmerge -U $@ $<

po/MESSAGES.pot: $(LSRCS) $(CSRCS)
	xgettext --from-code utf-8 -o $@ $^

.PHONY: clean install

clean:
	rm -rf locale
	rm -f tally tally_bytecode.o tally.bytecode

install: $(BIN) $(MOFILES)
	install -D -m 0755 -t $(PREFIX)/bin $<
	cp -r locale $(PREFIX)/share
	install -D -m 0644 -t $(PREFIX)/share/applications $(DESKTOP_FILE)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/scalable/apps icons/$(ICON)
	install -D -m 0644 -t $(PREFIX)/share/icons/hicolor/symbolic/apps icons/$(SYMBOLIC)
	install -D -m 0644 -t $(PREFIX)/share/metainfo $(METAINFO)
