# Screenshots

## Invariants

- Screenshots ships off. Enabling it authorizes local OCR of the selected folder; the switch is
  excluded from backups and `settings.json`. Disabling cancels capture, scanning and OCR, clears
  resident library state, removes all four commands and silences their hotkeys.
- Screen Recording is requested only by a capture command, never by enabling or searching.
- A screenshot copies image bytes, never its path or recognized text. Copy works with Clipboard
  History off; with history on, `ClipboardManager.copyImage` marks the write and inserts one image.
- The current folder is the library. Changing it moves nothing and cannot publish an old folder's
  scan or recognition result. Only visible, regular, top-level ImageIO-supported image files appear.
- OCR runs one file at a time in `TextRecognitionHelper`, never in the app process. Derived text is
  kept in a disposable cache, excluded from backups, and never copied to the pasteboard.

## Capture

`ScreenshotCoordinator` owns the command lifecycle and one `ScreenshotSelectionController`.
Capture Area selects a drag rectangle; Capture Window highlights the topmost eligible window beneath
its pointer, ordered by Core Graphics window metadata and resolved to `SCWindow` values. Both use
Tinycast's own borderless selector, and Escape cancels without writing. Capture Screen takes the
`NSScreen.underCursor` snapshot recorded before the palette hides.

`ScreenshotCaptureService` uses macOS 26's async `SCScreenshotManager` with SDR PNG output, no cursor,
and window shadows. AppKit rectangles convert to global display coordinates through
`ScreenshotGeometry`; area captures use the highest intersecting display scale. Selectors and the
palette order out before capture.

The captured PNG goes to the clipboard before saving. A save failure therefore reports the partial
success rather than losing the image. `ScreenshotRepository` writes a hidden staging file, then moves
it to a unique timestamp-and-UUID filename without replacing an existing file. It creates a missing
save folder only for a capture.

## Folder and browser

The default is `~/Pictures/Tinycast Screenshots` on stable and
`~/Pictures/Tinycast Dev Screenshots` on Debug; other channels include their bundle ID. A custom folder
is stored as an absolute or tilde-relative path in `screenshotsFolder`, exposed as
`screenshots.folder` in `settings.json`, and excluded from settings backups like the Notes folder.

`ScreenshotStore` refreshes on enable, capture completion and browser opening. While Search
Screenshots is visible its coordinator requests a refresh every two seconds. Scans and image encoding
run off-main. A missing folder is empty; an unreadable folder reports an unavailable state.

The palette screen shows a lazy thumbnail list and a larger preview, filename, date, dimensions and
file size. Hover and arrows choose the preview. Single-click or Return copies and closes; Command-Return
reveals in Finder. Search terms may independently match the filename, formatted date or recognized
text. Results stay newest first, capped at 1000 visible matches, and preserve selection by file identity as
scans and OCR arrive. Creation date falls back to modification date.

Thumbnail cache keys include each file's revision, so replacing an image at the same path refreshes
its pixels. Hidden palette views release their preview references. Existing PNGs copy directly;
other formats convert at full resolution with their orientation applied. Conversion is capped at
32 MiB of decoded pixels, and PNG reads at 64 MiB, before changing the clipboard.

## Text recognition

The shared worker, extractor and bundled helper live in `Platform/TextRecognition`. Clipboard uses
`ClipboardTextIndexer.extractText` to resolve its own item shapes into the shared URL-based worker.
The helper retains its existing size, image, text-output, timeout and cancellation limits.

`ScreenshotTextCache` stores revision and retry state in SQLite and recognized text in trigram FTS,
under `~/Library/Caches/<bundle-id>/screenshots.sqlite3`. Folder reconciliation removes missing or
changed-file text. Each operation opens its own connection off-main, including search, and corrupt
cache files rebuild automatically. Short queries use a substring lookup. Recognition waits for two seconds of system
idle, retries failures after 30 seconds, and remains serialized when changing folders. Every scan and
recognition result checks the active generation before publishing.

`AppCore` owns the store and coordinator. Both palette and Settings hosting trees inject the
coordinator through `@Environment`. `SettingsTab.screenshots.ownedCommands` is the ownership source
for the four built-in `.command` entries, independent of Settings → Commands.
