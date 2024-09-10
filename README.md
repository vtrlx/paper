# Paper

A text editor for GNOME that is as simple as writing on plain paper.

## Features

-	write and edit text files
-	search and replace in current file

## Building

Paper compiles with [Flatpak Builder](https://docs.flatpak.org/en/latest/flatpak-builder.html).

```sh
flatpak-builder .build ca.vlacroix.Paper.json --user --install --force-clean
flatpak run ca.vlacroix.Paper
```

To build and run the development version, add `.Devel` after the application's name.

```sh
flatpak-builder .build ca.vlacroix.Paper.Devel.json --user --install --force-clean
flatpak run ca.vlacroix.Paper.Devel
```
