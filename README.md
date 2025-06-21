![tally](tally.png)

# Tally

_Count anything._

This application is a tally counter for the GNOME desktop on Linux.

## Installing

[![Get it on Flathub](https://flathub.org/api/badge?svg&locale=en)](https://flathub.org/apps/ca.vlacroix.Tally)

## Building

Build with [Flatpak Builder](https://docs.flatpak.org/en/latest/flatpak-builder.html).

```sh
flatpak-builder .build ca.vlacroix.Tally.json --user --install --force-clean
flatpak run ca.vlacroix.Tally
```

To build and run the development version, add `.Devel` after the application's name.

```sh
flatpak-builder .build ca.vlacroix.Tally.Devel.json --user --install --force-clean
flatpak run ca.vlacroix.Tally.Devel
```

## Localization

Tally uses [gettext](https://www.gnu.org/software/gettext) for localization. These instructions assume you have it installed on your system.

To create a message file for your desired language, execute this command in a terminal from Tally's root folder:

```sh
make po/<LANG>.po
```

`<LANG>` should be replaced by the two-letter language code for the language you're translating the app to, optionally followed by an underscore `_` character and a two-letter country code in ALL-CAPS i.e. `fr` for French or `fr_CA` for Canadian French.

This command creates a file in the `po/` folder named `<LANG>.po`.

Next, edit the `<LANG>.po` file and add your translated strings. I recommend using [Translation Editor](https://flathub.org/apps/org.gnome.Gtranslator) for this.

The last strings to localize are for the `ca.vlacroix.Tally.desktop` file. Add new lines for the `Comment`, `Keywords`, and (if applicable) `Name` keys. Be sure to keep the translated lines in alphabetical order with respect to the language codes.

Once finished, try running Tally in your language using the [testing instructions](https://github.com/vtrlx/tally?tab=readme-ov-file#building) above. If all the strings appear to have been translated, commit your finished `<LANG>.po` file to Git, push the commit to a branch under your control, and submit a pull request [on GitHub](https://github.com/vtrlx/tally/pulls).

### Updating a Localization

If the application is updated and the translation needs to be changed, again run this command in the project's root folder:

```sh
make po/<LANG>.po
```

This will update the given `.po` file with the new translatable strings. The updated `.po` file for your language may then be modified, committed, and put into a pull request as usual.
