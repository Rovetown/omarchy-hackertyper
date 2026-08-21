# Hacker Typer for Omarchy

Turn any keyboard into an implausibly productive terminal. Hacker Typer is a native Omarchy shell plugin: choose a source from the bar, launch the large centered terminal panel, and type anything to reveal convincing code.

The interface follows your active Omarchy theme and monospace font, so it looks at home beside Ghostty, Alacritty, Kitty, and Foot. It runs entirely inside `omarchy-shell`—no WebView, network access, commands, or system changes.

![Hacker Typer preview](preview.png)

## Install

```bash
omarchy plugin add https://github.com/codefriendly/omarchy-hackertyper.git --enable
```

Click the `>_` icon in the bar, choose a source, and select **Launch**.

## Controls

- **Any key** reveals the next characters.
- **Backspace** rewinds.
- Press **Alt three times** for `ACCESS GRANTED`.
- Press **Caps Lock three times** for `ACCESS DENIED`.
- **Escape** dismisses an access message, then exits the overlay.

You can also launch the selected source from the command line:

```bash
omarchy-shell codefriendly.hackertyper launch "" ""
```

## Sources

Bundled languages: **C, C++, C#, Java, TypeScript, Python, Go, Rust, Ruby, PHP, Bash, SQL, Lua, and QML**.

The **Kernel** C source and bundled language samples are project-authored MIT source. The QML option displays this plugin's own `HackerTyper.qml`; no source is copied from Linux or the original Hacker Typer repository.

## Privacy and safety

Hacker Typer is visual theater only. It does not execute the displayed source, run shell commands, contact the network, or write outside its plugin directory.

## Remove

```bash
omarchy plugin remove codefriendly.hackertyper
```

## Development

```bash
omarchy plugin validate .
node tests/hackertyper.test.js
QML_IMPORT_PATH=/usr/share/omarchy/shell qmllint \
  BarWidget.qml Panel.qml Service.qml HackerTyper.qml
```

## Credits

Inspired by [Hacker Typer](https://github.com/duiker101/Hacker-Typer) by Simone Masiero. This plugin is an independent native-QML reimplementation and does not embed or copy the original website or its bundled source text.

MIT licensed. See [LICENSE](LICENSE).
