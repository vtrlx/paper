# Parchment

A text editor for GNOME that is as simple as writing on parchment.

## Features

-	write and edit text files
-	search and replace in current file

## Building

Parchment compiles with [Flatpak Builder](https://docs.flatpak.org/en/latest/flatpak-builder.html).

```sh
flatpak-builder .build ca.vlacroix.Parchment.json --user --install --force-clean
flatpak run ca.vlacroix.Parchment
```

To build and run the development version, add `.Devel` after the application's name.

```sh
flatpak-builder .build ca.vlacroix.Parchment.Devel.json --user --install --force-clean
flatpak run ca.vlacroix.Parchment.Devel
```
