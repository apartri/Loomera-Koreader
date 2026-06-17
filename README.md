# Loomera KOReader plugin

A [KOReader](https://koreader.rocks/) plugin that syncs your **reading stats and highlights** to a self-hosted [Loomera / Life Calendar](https://github.com/apartri/Life-Enterprise) server — and lets you browse + download your books over OPDS. A privacy-friendly replacement for Syncthing/cloud sync: every network call is opt-in, guarded, and can never crash KOReader.

- Pushes `statistics.sqlite3` (per-page reading time) → `POST /nightly/reading`
- Pushes each book's highlight sidecar (`metadata.epub.lua`) → `POST /nightly/highlights`
- One-tap OPDS browse of your Loomera/Calibre library (auto-registered into KOReader's catalog list)
- Opportunistic auto-sync on book close + a 5-minute timer (never forces Wi-Fi)
- Both POSTs are `Authorization: Bearer <SYNC_TOKEN>` guarded

Works with the [Loomera Obsidian plugin](https://github.com/apartri/Loomera-Obsidian), which turns the highlights you push here into Markdown notes.

## Install

### The easy way (Loomera users)
Open the Loomera setup wizard → **Books & e-reader** → **Download Loomera plugin**. The zip already has your server URL and sync token baked in. Unzip `loomera.koplugin` into your e-reader's `koreader/plugins/` folder.

### Manual
1. Copy the [`loomera.koplugin/`](loomera.koplugin) folder into your device's KOReader plugins folder:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle/PocketBook/etc.: `koreader/plugins/`
2. Edit `loomera.koplugin/loomera_config.lua` and set your `server_url` and `sync_token` — **or** leave them blank and fill them in on-device via **Menu → Loomera → Settings / About**.
3. Restart KOReader. Use **Tools → Loomera → Sync**.

## Config

`loomera_config.lua` is a template (blank by default):

```lua
return {
  server_url = "",   -- e.g. "https://loomera.example.com" (no trailing slash)
  sync_token = "",   -- your SYNC_TOKEN
}
```

## License

MIT
