---
title: Screenshots
description: Capture an area, window or screen, save it automatically, and search screenshots by their text.
---

Turn on **Settings → Screenshots → Enable Screenshots** to capture and browse screenshots.

## Taking a screenshot

| Command | What it captures |
| --- | --- |
| Capture Area | Drag an area of the screen. |
| Capture Window | Click a highlighted window, including its shadow. |
| Capture Screen | The display under your pointer. |
| Search Screenshots | Browse the images in your chosen save folder. |

Each capture copies the image to your clipboard and saves a full-resolution PNG. Press Escape while
selecting an area or window to cancel. Assign aliases and global hotkeys in **Settings → Screenshots**;
none are assigned by default.

The first capture asks for **Screen Recording** access. Searching existing images needs no Screen
Recording permission. **Settings → Permissions** shows its status and opens System Settings.

## Where images are saved

The default folder is **Pictures → Tinycast Screenshots**. In **Settings → Screenshots → Save Location**,
use **Choose…** to select another folder, **Use Default** to reset it, or **Open Folder** to open it in
Finder. Changing folders leaves your existing screenshots where they are and switches the browser to
the new folder.

If saving fails, the screenshot still reaches your clipboard and Tinycast reports that it couldn't
save the file. Tinycast never automatically deletes your screenshots.

## Finding and copying screenshots

**Search Screenshots** shows the selected folder's images, newest first, with thumbnails and a larger
preview. Existing PNG, JPEG, HEIC and other images supported by macOS appear too. Subfolders aren't
searched.

Type to search filenames, dates, or text inside images. Recognition runs locally in the background
while your Mac is idle; text matches become available as indexing finishes. Images are never uploaded.

Move the pointer over a row or use the arrow keys to preview it. **Click once** or press **Return** to
copy the image and close the palette. **Command-Return** reveals it in Finder. Copying works even when
Clipboard History is off; when history is on, the copied image also appears there.

Turning Screenshots off stops capture commands, browsing and recognition. The setting stays on this
Mac and is excluded from backups and `settings.json`. The save folder can be configured in
`settings.json` as `screenshots.folder`; backups don't carry the folder, images or recognition cache.
