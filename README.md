# LocalSend Lite for KOReader

[简体中文](README.zh-CN.md)

Send and receive books and other files over your local network using [LocalSend v2.2](https://github.com/localsend/protocol).

**About 24 KB to download.** The v0.1.0 ZIP contains a Lua plugin that runs entirely inside KOReader and reuses its bundled networking libraries. The network service starts on demand when you send or receive files.

## Install

1. Download the ZIP from [GitHub Releases](https://github.com/bbsteel/koreader-localsend-lite/releases/latest).
2. Extract the `localsend-lite.koplugin` directory into KOReader's `plugins/` directory. On Kindle, the resulting path on the USB drive is `koreader/plugins/localsend-lite.koplugin/main.lua`.
3. Eject the Kindle and restart KOReader. Open **Tools → LocalSend Lite**. The entry appears first in the default Tools menu.

If you're upgrading from the pre-Lite development build of this project, move its `localsend.koplugin` directory out of `plugins/` before installing Lite. Lite has its own settings and creates its own device identity on first use. Run one LocalSend receiver at a time when two plugins use the default port.

## Send and receive

- **Send files** opens KOReader's file chooser. Long-press a file, confirm your choice, then select a discovered device. For a batch, select the files in the file browser's selection mode before opening **Send files**.
- **Receive files** displays your device nickname and save folder. Leave the screen open, select the nickname on the sending device, then accept on your reader. The default destination is the current library folder. New files receive a numeric suffix if the name is already taken.
- **Stop** closes the receiver. On Kindle, the plugin allows the LocalSend ports on Wi-Fi while in use and removes its firewall rules when it stops.

Nicknames follow the KOReader interface language and stay stable for the same device identity and language. The plugin includes 22 nickname word lists and falls back to English. File bodies stream in 32 KiB chunks. Transfers support up to 128 files per batch and files smaller than 4 GiB. Plain `.txt` files transfer normally. The plugin's discovery uses IPv4 multicast at `224.0.0.167:53317` and its receiver uses HTTPS on TCP port `53317` by default.

## Verification

Run the tests against KOReader v2026.07.1 on Linux. Each runner defaults to the installed KOReader Flatpak, or accepts a path to a KOReader directory containing `luajit` and `setupkoenv.lua`. Temporary test files are created under `~/tmp` and removed at exit.

| Command | Coverage |
| --- | --- |
| `bash tests/run-koreader-ui.sh` | Plugin loading, Tools menu placement, receiver lifecycle and localized nicknames |
| `bash tests/run-loopback.sh` | Discovery, file transfer, TLS fingerprints, checksum handling, cancellation and mocked Kindle firewall cleanup |
| `bash tests/run-official-cli.sh` | Discovery by Chinese nickname and byte-for-byte HTTPS transfers in both directions with the official LocalSend CLI 1.18.2 |

An earlier build was installed on a Kindle Paperwhite 2. Hotspot discovery with this release still needs a device test.
