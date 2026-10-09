<!-- almeng-guide-source-sha256: 4f7b03d978ca41fadb62eaff2b64ead2894b54094cbd6c79ebfb8dfe0d317334 -->

<a name="top"></a>

# 알맹Re User Guide

[한국어](ko.md) · [English](en.md) · [日本語](ja.md) · [简体中文](zh-Hans.md) · [Français](fr.md) · [Español](es.md) · [Tiếng Việt](vi.md)

[← 알맹Re](../../README.md) · [PDF](pdf/AlmaengRe-User-Guide-en.pdf)

**Browse, compare, tag, and edit images; play videos and save frames or clips**

A practical guide to the current 0.13.1 development version. Start with a folder of images, then use the chapters as a reference for the task in front of you. Menu names in this guide follow the app's English interface.

Version 0.13.1 · As of 2026-10-10

> Screenshots show the real app with a Korean interface and synthetic demonstration media. Numbered annotations and explanations are translated into this guide's language; the screenshot pixels remain unchanged. No personal photo or video collection is used.

## Contents

- [1. Open images, videos, folders, and ZIP archives](#open)
- [2. Browse and focus on your images](#viewer)
- [3. Find and select images in All at Once](#overview)
- [4. Compare two image collections](#compare)
- [5. Tag photos and videos](#tags)
- [6. Set tag names, colors, and tracking expectations](#tag-editor)
- [7. Find photos by location](#map)
- [8. Inspect image information and metadata](#information)
- [9. Edit an image and export a copy](#editing)
- [10. Batch rename, convert, resize and share](#batch)
- [11. Add text, EXIF and logo watermarks](#watermark)
- [12. Play videos and save frames or clips](#video)
- [13. Extract and resize animated images](#animation)
- [14. Zoom in and compare AI upscaling results](#ai-upscaling)
- [15. Understand display quality, HDR, and loading](#quality)
- [16. Play a Photo Album or set wallpaper](#slideshow)
- [17. Make the app work your way](#settings)
- [18. Shortcuts and quick troubleshooting](#shortcuts)
- [Shortcuts at a glance](#shortcut-reference)

---

<a name="open"></a>

## 1. Open images, videos, folders, and ZIP archives

Use Open… for photos, videos, folders, and ZIP images. Photos and supported videos appear together by default; ZIP viewing supports images only.

![Home brings together the app logo, Open button, and recently viewed photos.](figures/home.png)

**Screen 01.** Home brings together the app logo, Open button, and recently viewed photos.

1. **Open or continue** — Use Open… for a new collection or Continue Previous Session to return to your saved workspace.
2. **Seven recent photos** — Up to seven photos viewed in Viewer or Image Comparison appear newest first; click to reopen. Regular images, GIFs, and photos inside ZIP archives are included; videos are excluded.
3. **Clear recent history** — Remove from List for one photo or Clear List removes history only, preserving original files. Viewing a photo again can add it back to the list.

### How to

1. Launch 알맹Re on macOS 14 or later to see Home. Use Open… (⌘O) or click a recent photo. Open… is also available in the toolbar and File menu.
2. Choose a folder to browse it. Opening one photo continues through the same folder; selecting several files opens only those files. Show Videos is on by default and remembers your choice. Opening a video directly turns it on.
3. Choose a ZIP archive to view its supported images, including images in nested archive paths. You can also open files from Finder or drag images and folders into the app.

### Folders and favorites

Folder Tree expands folders as needed. Click a folder name to open it, use the upward arrow to go up, and refresh after changes in Finder. Pin a folder above the tree for quick access. Opening a normal folder does not automatically include all its subfolders.

### ZIP is read-only

Images are extracted into a temporary folder while the archive is open. Export a copy before renaming or editing source metadata. The app does not rewrite the ZIP. Stored/Deflate archives are supported; encrypted archives and other compression methods are rejected. Limits include a 2 GiB archive, 10,000 entries, 256 MiB per extracted entry, and 1 GiB total extracted data. ZIP videos are not supported, even when Show Videos is on.

### Home and your previous workspace

A normal launch starts at Home. Continue Previous Session restores the last collection, selection, view mode, and search settings when possible. Home in the toolbar or menu returns there while keeping the current workspace. Opening a file from Finder or another app goes straight to that file. If connections or permissions change, use Open… again. Editing adjustments and unsaved AI results are not restored after relaunch.

### Good to know

- Selecting folders and individual images together collects them without duplicates. In Image Comparison, Open… changes the active unlocked A or B pane. Help → Basic Usage opens a short guide inside the app. Help → Detailed User Guide (GitHub) opens the full guide for your language on GitHub in your default browser.

[Back to top](#top)

---

<a name="viewer"></a>

## 2. Browse and focus on your images

Viewer can show one to ten images at a time. Zoom in to inspect details or hide the surrounding controls for a focused view. In multi-item views, videos start as still previews and play muted when you hover over them.

![Viewer shows several photos and videos together. Hover over a video for a muted preview.](figures/viewer.png)

**Screen 02.** Viewer shows several photos and videos together. Hover over a video for a muted preview.

1. **View modes** — Switch between Viewer, All at Once, Map View, and Image Comparison.
2. **Search, filters, and videos** — Adjust search, format, tags, sorting, and Show Videos for the current list.
3. **Viewing controls** — Move through items and change the number displayed. Set photo zoom and the pan method.

### How to

1. Choose Viewer at the top. Use ← and → to move. Set the number of images per screen with the count control or \[ and \]; the grid adapts to the window's shape.
2. Pinch the trackpad or use = and − to zoom. Press 0 for Fit to Window and 1 for Actual Size. Choose a pan method from the lower controls or Settings → General.
3. Press F, double-click a photo, or briefly tap Space to toggle focus mode. Press Esc to return. Full Screen is a separate command: ⌃⌘F.

### Moving through several images

In Viewer, ←/→ moves the configured number of items per page with Tagging ON or OFF. With multiple items displayed, ↑/↓ selects the row above or below within the current page and stops at its first and last rows. A short last row selects the nearest available card. ⌥←/⌥→ moves a full page, including while tagging.

### Pan controls

Choose left drag, Space + left drag, right drag, middle drag, or two-finger trackpad movement. The ⌃⌥1–5 shortcuts select a pan method; they do not move the photo by themselves. Horizontal swipes navigate when the gesture is not being used to pan. Panning allows only a small margin at the image edges, including during a drag, so photos cannot be pushed into a large empty space. Any axis smaller than its viewing pane stays centered; resizing the window or changing zoom readjusts the limits. The same rules apply to multiple-image viewing and zoom-quality comparison.

### Focus controls

The lower × hides only the floating control bar. Reopen it from the button beside the filename. The upper × exits focus mode. These buttons remain available even if filename display is hidden. A short Space tap does not change focus while typing or when Space has a custom shortcut.

### Good to know

- Thumbnails can appear on the left, right, top, or bottom, or be hidden. Esc closes the current temporary viewing mode before returning from Viewer to All at Once.

[Back to top](#top)

---

<a name="overview"></a>

## 3. Find and select images in All at Once

All at Once spreads the current collection into a thumbnail grid. Use it to scan a folder, narrow a selection, and prepare a batch operation. Videos appear as static previews without playback.

![All at Once combines the thumbnail grid with search, selection, and size controls.](figures/overview.png)

**Screen 03.** All at Once combines the thumbnail grid with search, selection, and size controls.

1. **Thumbnail grid** — Click, range-select, or drag to select cards. Videos show still previews; double-click opens them in full screen.
2. **Search, filters, and videos** — Adjust search, sorting, format, tags, and Show Videos for the current list.
3. **Size and selection** — Adjust preview size and use the selected-image actions for batch work.

### How to

1. Choose All at Once (G) and adjust the thumbnail size. Double-click to open a photo in Viewer or a video in full screen.
2. Type in Search Filenames. Search ignores letter case; every space-separated term must appear in the filename. Choose one or more formats, or All Formats to clear that filter.
3. Click to select, ⌘-click to add or remove, and ⇧-click to select a range. Drag a rectangle from a card or empty space to select intersecting cards. ←/→ moves one card; ↑/↓ moves one grid row with Tagging ON or OFF. Movement stops at the first and last rows; a short last row selects the nearest available card. This also works in map-filtered lists. Custom shortcuts take priority with Tagging OFF.

### Selection shortcuts

Hold Shift when starting a selection rectangle to add to the existing selection. Hold ⌘ to toggle the images in the rectangle. Esc restores the selection from before that drag. ⌘A selects all images in the current visible list.

### Sort the current list

Sort groups are Name & File, Dimensions & Capture Time, Camera & Color, and Location. Alongside existing options, use width, height, capture date, type, shutter speed, manufacturer, model, aperture and color space. Names use natural numbers, shutter speed uses exposure duration and aperture uses f-number. Missing values stay last in either direction. Type uses extensions, grouping equivalent JPEG/TIFF spellings. Files remain unchanged.

### Numbers and preview size

The # control shows or hides thumbnail numbers. Large badges move outside small photos to keep the image visible. The thumbnail-size setting is remembered; its range is 44.8–665.6 points, with individual cells constrained by the window width.

### Capture metadata sorting limits

Width and height are original pixel dimensions with file orientation applied, before viewer edits. Capture date uses EXIF or embedded video dates, never filesystem creation date. EXIF without a timezone is treated as UTC for ordering. Videos use available dimensions, dates, make, model and color information; shutter/aperture remain unknown. Metadata is read only for relevant sorts and reused, so the first sort may take time.

### Good to know

- Search uses filenames, not image content or OCR. With no matches, controls stay at the top; use Reset Search and Filters. Files remain intact. Untagged Photos off with no tags selected means no tag restriction.

[Back to top](#top)

---

<a name="compare"></a>

## 4. Compare two image collections

Image Comparison keeps independent A and B collections side by side or above and below. It is useful for comparing versions or checking two folders.

![Two collections in Image Comparison.](figures/compare.png)

**Screen 04.** Two collections in Image Comparison.

1. **A and B panes** — Below each pane’s name, check the selected tag keys, conditions, and photo count. With Untagged Photos off and no tags selected, all photos are shown; A/B may overlap. For empty results, check tags and shared search, format, and map filters. Clear removes only that pane’s tag filter.
2. **Comparison behavior** — Choose matching, the navigation target, shorter-side looping, and linked zoom.
3. **Apply Tags** — With ON, choose A Only, B Only, or Both for tag keys and bottom buttons, independently of navigation. A − means only some photos are tagged.

### How to

1. Compare Current Photos by Tag opens the current source list in A/B, keeping search, format, and map filters. Only A inherits the regular tag filter; B starts with all photos. For other folders, use Image Comparison (⌃⌥C), Choose Folders to Compare… or each pane’s Open….
2. Use the tag button below each pane’s name to select several of the existing 12 tags, such as 1·F for A and 3·Q·S for B. Any selected tag (OR) is the default; All selected tags (AND) and Untagged Photos are also available.
3. Under Image Navigation, choose one side by its displayed name or Both. Use the common arrows or pane thumbnails to move. Turn Link Zoom and Pan on to inspect corresponding relative positions. Each pane also limits panning to a small edge margin, centers any axis smaller than the pane, and readjusts the limits when zoom or window size changes.

### Navigation and looping

Browse filtered results in List Order or pair them with Matching Names: 001.jpg matches 001.png, and missing partners leave an empty side. Choosing one navigation target switches to List Order; Matching Names moves pairs. Under Both, Loop Shorter Side repeats the shorter list from the start; when off, it stays on its last image. Looping uses List Order.

### Tagging targets and locks

With Tagging ON, Apply Tags chooses A Only, B Only, or Both for keys and bottom buttons. It is independent of the active pane and navigation, starts at A Only, and keeps your choice during the session. Both shows − for mixed marks: press to add to both, or remove from both if both are marked. The same photo is processed once. All target photos must be displayed; Both is unavailable if either side is empty or loading. Locked photos can still be tagged. Lock fixes the image, zoom, position, and tag filter. Lock B to navigate A, or A to navigate B. Unlock both to restore Both navigation; lock both to stop it. Locked thumbnails remain viewable and scrollable.

### Originals and saved state

Comparison shows unedited originals and excludes videos. Exit for editing, batch work or wallpaper; Esc returns to the previous view. Layout, linking, navigation, last A/B inputs, positions, and pane tag filters are restored. Filters remain when opening other inputs. Comparison Names… sets aliases up to 80 characters. Blank fields or Use Automatic Names use folder/ZIP names; Save applies, Cancel keeps current names. The same folder/ZIP or mixed locations use A/B; distinct folders with matching names add (A)/(B). Aliases do not rename folders, survive restart and reopening the same inputs, and reset only for new inputs in that pane. Hover over shortened names to read them fully.

### Good to know

- ⌥←/⌥→ navigates A only; ⇧⌥←/⇧⌥→ navigates B only. Matching Names ignores extension, letter case, and equivalent Unicode spelling.

[Back to top](#top)

---

<a name="tags"></a>

## 5. Tag photos and videos

Apply several personal labels while browsing photos and videos. Tags can change only with Tagging ON; they are marks in the app, not actions on original files.

![Tagging ON with current-item keys and bottom buttons, plus each card’s Tags menu.](figures/tags.png)

**Screen 05.** Tagging ON with current-item keys and bottom buttons, plus each card’s Tags menu.

1. **Tagging ON/OFF** — Turn ON to change tags. OFF restores ordinary viewing shortcuts.
2. **Keys and bottom buttons** — Toggle marks on the current item. Multiple tags can coexist.
3. **Each card’s Tags menu** — Change only that photo or video, without changing the current or multiple selection.

### How to

1. Use Tagging ON/OFF, the Photo Tags menu, or ⌘⇧M. Turning ON ends search entry. Keys affect the current item; in comparison, they follow A Only, B Only, or Both under Apply Tags.
2. With ON, toggle tags with the physical 1–4, QWER, ASDF keys or bottom buttons. Each card’s Tags menu in Viewer or All at Once changes only its photo or video; it neither changes selection nor tags a multiple selection.
3. In ordinary viewing, turn OFF with ⌘⇧M, Esc, or the panel close button. The Tags filter shows Any selected tag, All selected tags, or Untagged Photos. In Image Comparison, set each filter below its pane’s name.

### Keep a steady browsing rhythm

Tagging never advances automatically. While ON, the list stays stable and Viewer ←/→ keys move a full page at a time. Turning OFF refreshes results. Comparison also defers automatic updates, but explicit filter changes apply immediately. In Viewer, tagging waits until the requested photo or video preview is displayed.

### What the keys mean

Default names are 1–4: One star, Two stars, Three stars, Four stars; Q Upload, W Retouch, E Delete, R Hold; A Landscape, S People, D Objects, F Animals. These are editable labels only; the keys never upload, retouch, delete, or move files. Previously saved names are kept.

### Stored locally

Photo marks, classification names and colors, and tracking history are stored in ~/Library/Application Support/org.openimageviewer.ImageViewer/PhotoMarks.sqlite. They are separate from EXIF/XMP and do not sync to the cloud. Development/demo bundles may use another folder; the report displays the actual storage path.

### Good to know

- With OFF, 1 and F resume Actual Size and focus mode. Full-screen video has a tagging switch and menu; its tag keys affect that video. There, ←/→ still seek and Esc closes full screen first.

[Back to top](#top)

---

<a name="tag-editor"></a>

## 6. Set tag names, colors, and tracking expectations

Give the twelve tag keys names that fit your work. The same assignments apply across folders, and existing memberships remain attached when a name changes.

![The shared editor for tag names and colors.](figures/tag-editor.png)

**Screen 06.** The shared editor for tag names and colors.

1. **Names by key** — Each fixed key gets an editable name; the names are shared by every folder.
2. **Colors** — Choose a consistent visual cue from the ten-color palette.
3. **Preview and save** — Check the assignments, then save the changes to keep them for the next session.

### How to

1. Open Settings → Photo Tags, or choose Photo Tags → Edit Tag Names & Colors…. You can edit assignments before opening photos.
2. Enter a name for each key and choose one of ten colors. The Key Assignments preview shows the result as you type.
3. Click Save to apply names and colors everywhere. Revert Changes in Settings restores the last saved assignments; Cancel closes the separate editor without saving.

### Consistent visual marks

Colors appear in the tag panel, menus, filters, and thumbnail badges. A checkmark and selected background also indicate membership, so color is not the only cue. Changing a name or color does not clear tags already applied to photos.

### Renames and moves

Saved macOS bookmarks and file identity follow name/location changes on the same volume. In-app renames preserve classifications. External changes are checked at launch, when opening Classification File Report… or refreshing it; there is no continuous watcher. The report retains relocated, unavailable and recovered observations, including classifications, paths and observation time. ZIP photos use the archive identity and internal path. Reopen or refresh the affected folder to update the photo list after an external move.

### Limits of tracking

Unavailable does not confirm deletion: a disk may be disconnected or access denied, so marks and history remain. Copies and different files at the same path do not inherit marks. Cross-volume moves or replacement by a newly created file may not reconnect automatically. Open older path-based marks at their original location once before moving.

### Good to know

- The app does not search the whole disk for missing photos or analyze their contents. Keep important originals and the app's local data backed up as part of your normal Mac backup.

[Back to top](#top)

---

<a name="map"></a>

## 7. Find photos by location

Map View places photos with GPS metadata on a map. Combine up to three areas to browse images from several places together.

![Map View with selectable areas and a matching-photo summary.](figures/map.png)

**Screen 07.** Map View with selectable areas and a matching-photo summary.

1. **Area tools** — Add a radius, rectangle, freehand boundary, or the current map extent.
2. **Area handles** — Move and resize an active area; combine at most three areas.
3. **Browse the results** — Open matching photos in Viewer or All at Once while keeping the area filter. On the map, area and pin actions also offer rename, conversion and sharing directly.

### How to

1. Open a collection and choose Map View. Nearby photos are grouped into stacked thumbnails with a count. Click a location to preview its images and use View Photo to open one.
2. Choose Radius or Rectangle to add an area at the current map center. Drag its numbered handle to move it and the small size handle to resize it. A radius can also be entered in kilometers.
3. Choose Freehand Area and draw a boundary, or add Current Map Area. Add up to three areas, then use Open in viewer or Open in overview to browse the matching photos; the latter opens All at Once. On the map, area and pin actions also offer rename, conversion and sharing directly.

### Combine and edit areas

A photo in any selected area is included once, even where areas overlap. Select Area 1, 2, or 3 to edit it, use its × to remove it, or clear all areas. Esc cancels a freehand drawing or reverts a move or resize in progress.

### Keep the selected collection

A blue “Showing only photos selected on the map” banner above Viewer and All at Once shows the area and displayed-photo counts. It remains in focus mode and when the results are empty. Opening the selection in Viewer or All at Once keeps the map restriction active. Filename, format, and tag filters also apply. Clear Map Area returns to the non-geographic filtered list, including images without GPS. Opening a map photo outside the selection clears only the geographic restriction.

### Loading and saved state

After switching viewing modes, Back to map or Map View returns to the last map position and zoom. After relaunch, the map fits the restored selection instead of restoring the exact position. Opening a new folder resets the areas and map position. Map backgrounds need internet access. Photos without GPS are absent; reading locations in large collections may take time. Video GPS is not read.

### Good to know

- If no photos match, enlarge or move the area and check other filters. The buttons for opening a selection are unavailable while results are loading or empty.

[Back to top](#top)

---

<a name="information"></a>

## 8. Inspect image information and metadata

The circular i button remains Image Information. It shows details of the current photo; the app's own story is under Help → About.

### How to

1. Select a photo and click the circular i button, or use Navigate → Image Information Panel.
2. Inspect file size, dimensions, color information, and available camera/EXIF data. If GPS is present, the panel shows an Apple map; Google Maps opens the same coordinates externally.
3. To change supported file or embedded fields, open Edit Image Information, revise the values, and review them before Save.

### Metadata saving changes the file

Unlike visual adjustments, metadata edits are written back to the source file. Editable fields include filename, modification date, description, rights, DPI, camera details, and GPS when the format supports them. The editor prepares a temporary file before replacing the source path. Unsupported embedded fields are disabled; ZIP members are read-only.

### Removing or correcting values

Emptying an editable text value removes that tag when saved. Turning off GPS removes standard EXIF/XMP location tags. Coordinates need both latitude and longitude. Changing an extension does not convert an image; use Export or Batch Format, Resize & Compress for that.

### Read the histogram correctly

RGB and luminance histograms describe an SDR preview, weighted by transparency, and follow editing adjustments. Black and white percentages count preview pixels with all RGB channels at 0 or 255. This is not a RAW sensor histogram or a measurement of the original HDR brightness range.

### Good to know

- Keep a copy before making metadata changes you may want to undo. The i icon is for the photo; Help → About opens the app introduction and license information.

[Back to top](#top)

---

<a name="editing"></a>

## 9. Edit an image and export a copy

Image Editing previews changes without overwriting the original. Export the result before quitting: visual adjustments are kept only for the current app session.

![The editing panel beside a preview of the current image.](figures/editing.png)

**Screen 08.** The editing panel beside a preview of the current image.

1. **Presence and Film Looks** — Expand Presence to adjust the image, or choose a film look and its strength.
2. **Image preview** — Inspect the current result; use Actual Size for detail adjustments.
3. **Save copies and add watermarks** — Choose format and quality to export a copy. Add Watermark… targets only the current photo.

### How to

1. Select a photo and click the slider-shaped Image Editing button. Opening it from All at Once switches to Viewer for that photo.
2. Crop by dragging a rectangle on the image. Move it from inside, resize its corners, or enter a ratio and dimensions. Apply the crop; canceling the crop sheet keeps previous edits. Rotate in 90° steps or use Flip Horizontal / Flip Vertical.
3. Adjust light, color, and detail controls. Choose an available output format and quality in the editing panel, then click Export… or press ⌘E to save a new file.

### Adjustments

Use exposure, brightness, contrast, highlights, shadows, black point, and whites for tone; hue, temperature, vibrance, and saturation for color. Tone curves offer RGB or individual channels with five points. The eight-color mixer adjusts hue, saturation, and lightness for each color. Texture, clarity, dehaze, and film looks provide further control.

### Reset and inspect

Reset removes every visual adjustment on the current photo. Remove Crop keeps other edits. Clicking the same flip button again reverses that flip. Check sharpening and noise reduction at Actual Size and in the exported result.

### Save before exit

Each photo keeps its adjustments while the app remains open. The next launch does not restore them. Export defaults to a name ending in -edited, and saving over the source is blocked. Available formats depend on the encoders supplied by macOS.

### Good to know

- Image Comparison shows originals and does not bring in these adjustments. AI Upscaling also uses the source image without the viewer's edits; export an edited copy first if you want to upscale that result.

[Back to top](#top)

---

<a name="batch"></a>

## 10. Batch rename, convert, resize and share

Select photos in the viewer, overview or a classification-filtered list, then use selection actions, the context menu or Image menu. Map actions target an area or a pin. Renaming changes originals; conversion and resizing create copies.

![The batch dialog converts selected photos and resizes them proportionally.](figures/batch.png)

**Screen 09.** The batch dialog converts selected photos and resizes them proportionally.

1. **Format and size** — Choose the output format and proportional size. Lossy formats offer quality settings; a compression preset is also available.
2. **Watermark and destination** — Open watermark settings or choose the folder for copies.
3. **Save preview** — Compare current and output names before converting. Originals stay intact.

### How to

1. Use ⌘-click, ⇧-click or ⌘A in thumbnails; the overview also supports rectangle selection. Filter by classification and select all, or use Area Photo Actions, This Photo or All Photos at This Location on the map.
2. Open Batch Rename… and choose to keep, replace or find and replace names, or Use a classification name. Explicitly choose the classification to use, then review the matching count and before/after filenames before applying.
3. Open Batch Format, Resize & Compress… and set the format, quality, size and destination folder. Review and convert. Share Files… passes selected originals to the native macOS sharing menu; the result sharing button passes only successfully exported copies.

### Classification names and sequence numbers

Only selected files carrying the chosen classification are renamed, in current list order: Upload01, Upload02. At 100 targets, numbering starts at Upload001 and expands further as needed. For photos with several classifications, the one you explicitly choose is used. Ordinary numbering defaults to two digits, with configurable start, increment, padding and separator. Empty classification names, duplicate or invalid destinations block applying. ZIP members cannot be renamed in place.

### Real format conversion and proportional resizing

Rename extension options change casing or equivalent spellings such as .jpg/.jpeg; use batch conversion for another encoding. Resize by longest edge or 1–100% after existing crop, rotation and adjustments, preserving aspect ratio. Smaller images are never enlarged. The compression preset chooses JPEG, 1920px longest edge and 75% quality. Smaller files or a specific byte count are not guaranteed.

### Saving copies and macOS sharing

Original files and classifications remain intact; new copies do not inherit classifications. Output collisions get a numeric suffix. Batch image conversion saves only the first frame of animated or multipage inputs and is unavailable when a video is selected. Use Frames & Clips… to keep an animation or save a video clip. Completed batch files remain after cancellation; the result shows saved, failed and unprocessed counts. Share Files… uses native macOS sharing. Export copies first to share current edits.

### Good to know

- Select All applies to the current search, format, classification and map filters. Map actions target the area or pin named by the menu. Check the count and preview before renaming originals.

[Back to top](#top)

---

<a name="watermark"></a>

## 11. Add text, EXIF and logo watermarks

Place text, a signature, selected capture information and a logo on copies of one or more selected photos. Original files and their classifications stay intact.

![Combine text, EXIF and a logo, drag the preview watermark and choose whether to extend the canvas.](figures/watermark.png)

**Screen 10.** Combine text, EXIF and a logo, drag the preview watermark and choose whether to extend the canvas.

1. **Text, font and EXIF** — Choose text, font and per-photo EXIF. Adding fields keeps the text size.
2. **Logo and placement** — Choose a logo and adjust size, margin and opacity with sliders or numbers.
3. **First photo preview** — Drag the watermark; its outline is not saved. Moving outside the photo asks about canvas extension.

### How to

1. Select photos and choose Add Watermark… from the Image, selection actions or context menu. Map actions target the named area or pin. The editing panel’s Add Watermark… targets only the current photo.
2. Enter text or a signature and click the font name to choose a font in the macOS font panel. Select EXIF fields to draw on the photo. Choose Image… adds a logo or signature image, such as a transparent PNG.
3. Choose one of nine positions or drag the watermark in the preview. Set size, margin and opacity with sliders or percentages such as 25.5; choose white/black text and shadow/background. Placement outside the photo asks about extending the canvas. Apply Settings, then choose format, quality, resizing and folder to start conversion.

### Capture information and stable text size

EXIF draws each original’s capture date, manufacturer, model, lens, shutter speed, aperture, ISO, focal length and filename. Missing or unreadable capture values are omitted. Adding EXIF adds rows or wrapping without shrinking the text. To change embedded metadata, use the metadata editor in Image Information.

### Drag placement and canvas extension

Text and logo size follow photo width before expansion; logo proportions stay intact. Margins use the short edge only at preset positions; dragging sets a custom center. Relative position, size and expansion consent apply to the selection, adding only each photo’s necessary edges without scaling it. Extra space is transparent with alpha, white in JPEG. Keep inside image only moves outside placement inward. Oversized content offers Extend canvas, Shrink watermark to fit or Cancel. Cancel keeps current settings. Without canvas extension, content that does not fit prevents saving until resolved. Returning to the original canvas also checks for oversized content.

### Copies, preview and remembered settings

Watermarks follow edits, crop, rotation and output resizing. The first photo’s scaled preview may differ slightly in final placement due to pixel rounding; other photos may differ in size and EXIF. Originals and classifications stay intact; share completed copies through macOS. Design and custom placement are remembered, but enable the watermark for each new conversion. Canvas consent resets for each new batch; drag outside again to confirm it. Keep the logo source at the same path; unreadable files show an error. Videos are excluded; animated or multipage images save their first frame as a still.

### Good to know

- Text allows 2,000 characters and 20 lines; logos use the first frame of an ImageIO-readable image. Size is 2–90%, margin 0–20%, opacity 0–100%. Out-of-range numbers are clamped; invalid input keeps the last valid value. Expanded final output is limited to 64 MP and 32,768 px per side; move inward or reduce size if exceeded. Watermarks do not appear on originals in the viewer.

[Back to top](#top)

---

<a name="video"></a>

## 12. Play videos and save frames or clips

Photos and videos appear together by default. All At Once shows static video previews; a single video opens paused. Use Frames & Clips… to extract a PNG or save a clip copy while preserving the original.

![Frames & Clips provides video playback, frame inspection, and clip export.](figures/video.png)

**Screen 11.** Frames & Clips provides video playback, frame inspection, and clip export.

1. **Video player** — Playback starts paused. Play, pause, and listen to available audio using the player.
2. **Frame and time controls** — Step through supported frames or seek by time, then extract the current frame as PNG.
3. **Range and quality** — Set start and end times, choose MP4/MOV and quality, or use the 720p size-reduction preset.

### How to

1. In a multi-item view, hover over a video for muted playback; use Turn Sound On to listen. Leaving the tile stops playback and mutes it again. Double-click a video in All At Once or Viewer to open it alone in full screen, playing from its current time with the same mute setting. Use the controls for playback, seeking, and sound; Esc or Close Full Screen returns to the original layout. Show Videos in the list, menu, or settings can hide videos; GIFs are unaffected.
2. Open a video in Viewer and choose Frames & Clips…. Use Previous Frame and Next Frame where the file supports stepping, or seek with Playback Position. Choose Extract Current Frame as PNG… to save the displayed moment.
3. Under Range to Save, use Set Start Here / Set End Here or enter Start (s) and End (s). Choose MP4 or MOV and Export Quality, then Save Clip Copy…. Full Range selects the entire video; Reduce Size Preset selects MP4 and Up to 720p.

### Built-in macOS support

MP4, M4V, MOV, MPG/MPEG/M2V, AVI, 3GP/3G2, and MTS/M2TS/TS are candidates. Playback and export depend on the actual codecs and macOS support, checked when the file is opened. No external codec package is required. WebM, MKV, and videos inside ZIP archives are excluded. DRM-protected videos cannot be exported.

### Frames, ranges, and quality

Stepping uses real media frames where available. Variable-frame-rate video has no guessed exact frame count. Clip ranges include the start and exclude the end; saved boundaries follow media samples. MP4/MOV copies use H.264 video and AAC for available audio. Quality presets preserve proportions without enlarging smaller sources. A smaller file or a particular byte count is not guaranteed. PNG extraction saves the source frame at its original resolution; Export Quality affects clip copies only.

### Video and photo tools

Photo adjustments, AI Upscaling, wallpaper, and batch image export do not apply to videos. Photo Album is disabled while the visible list includes a video; hiding videos allows an eligible photo list to play. Image Comparison stays image-only, and video GPS is not read. Tags, renaming, and sharing selected originals remain available.

### Good to know

- Choose a new output name: the original and existing output files are protected. Cancel removes incomplete output. After a successful save, use Show in Finder or Share Files… to share the completed copy through macOS.

[Back to top](#top)

---

<a name="animation"></a>

## 13. Extract and resize animated images

Frames & Clips… works with animated GIF, APNG, and WebP that macOS ImageIO can decode. Extract one frame as PNG or save a selected frame range as a GIF or APNG copy.

![Frames & Clips previews an animation and saves a frame or a resized animated copy.](figures/animation.png)

**Screen 12.** Frames & Clips previews an animation and saves a frame or a resized animated copy.

1. **Animation preview** — Inspect the source animation; photo-editing adjustments are not included.
2. **Frame controls** — Play or step through frames, read the frame number, and extract a PNG.
3. **Range and resize** — Choose inclusive frame numbers, output format, proportional size, and how many frames to keep.

### How to

1. Open an animated GIF, APNG, or WebP and choose Frames & Clips…. Use Play / Pause, Previous Frame, Next Frame, or Playback Position to inspect the animation. Show Videos does not hide GIFs.
2. Choose Extract Current Frame as PNG… for a still image. To save an animation, enter First Frame and Last Frame under Range to Save, or use Set Start Here / Set End Here. Frame numbers start at 1 and both ends are included; Full Range selects every frame.
3. Choose GIF or APNG in Format. Set Image Size to Original Size, Longest Edge (px), or Percentage (%), then choose Keep Frames. Review the range and use Save Clip Copy… to save a separate file.

### Size and frame selection

Resize proportionally by longest edge or 1–100%; smaller sources are not enlarged. Under Keep Frames, choose All Frames, 1 in 2 Frames, 1 in 3 Frames, or 1 in 4 Frames. Dropped frames add their time to retained frames so the selected range keeps its duration. Reduce Size Preset selects 50% size and 1 in 2 Frames.

### Formats and image appearance

GIF, APNG, and WebP input support depends on ImageIO in macOS. Animation copies use an available GIF or APNG encoder; WebP is an input format here. GIF has limited colors and transparency, so it can change the result. Photo-editing adjustments are not applied. Size reduction does not guarantee fewer bytes or a target file size. PNG extraction saves the source frame at its original resolution; Image Size and Keep Frames affect animated copies only.

### Save and share a copy

The source and existing output files cannot be overwritten. Choose a new name for each result. Cancel removes incomplete output. After saving, Show in Finder reveals the file and Share Files… opens native macOS sharing for the completed copy. New copies do not inherit the source classifications.

### Good to know

- Batch Format, Resize & Compress… saves only the first frame of animated inputs. Use Frames & Clips… when the output should stay animated, and check playback, colors, and transparency in the saved copy.

[Back to top](#top)

---

<a name="ai-upscaling"></a>

## 14. Zoom in and compare AI upscaling results

AI Upscaling creates a new image with twice the width and height. Inspect its details and compare the same area with the original before saving a PNG copy.

![The preview lets you adjust zoom and move a divider to compare the same area of the original and AI upscaling result.](figures/ai-upscaling.png)

**Screen 13.** The preview lets you adjust zoom and move a divider to compare the same area of the original and AI upscaling result.

1. **View and zoom** — Choose AI Upscaling Result or Compare with Original. Inspect details with +/−, the zoom percentage, Fit to Window, and 100% · Actual Pixels.
2. **Original and AI divider** — Move the divider between the original on the left and the AI result on the right. Drag the image or scroll to pan both sides together.
3. **Save a PNG copy** — Save the completed 2× result as a PNG copy, independently of the preview zoom.

### How to

1. Select a photo, open AI Upscaling…, and click Start AI Upscaling. When processing finishes, the preview shows the AI Upscaling Result.
2. Use the +/− buttons or pinch the trackpad to zoom. Drag the image or scroll to pan to a detail; Fit to Window shows the whole image again.
3. Select Compare with Original and drag the divider left or right. The original is on the left and the AI result on the right, at the same zoom and position. After checking the result, click Save PNG Copy….

### What 100% · Actual Pixels means

At 100%, one AI output pixel maps to one physical screen pixel. This accounts for Retina scaling, so the window’s size in points need not equal the image’s pixel dimensions. The percentage refers to the AI output, not the original. Fit to Window chooses a zoom that shows the entire image. These controls change only the preview: they do not resize the file, change the saved output, or run AI processing again.

### Compare the same detail

The original on the left is displayed at 2× using ordinary interpolation to match the AI output’s width and height. Both sides share zoom and pan, so moving the divider reveals the same edges and textures. Drag the divider to change the comparison boundary; drag elsewhere on the image to pan. AI-generated detail is an estimate and is not guaranteed to recover real information missing from the original.

### AI output and limits

The bundled model runs locally through Core ML; photos are not uploaded and no model download is needed during use. Width and height are doubled. Output is 8-bit SDR sRGB PNG, with separately interpolated transparency. Animated input uses the first frame and viewer edits are not included. The output limit is at most 64 million pixels and can be lower on low-memory Macs. Save before closing; AI detail is an estimate.

### Good to know

- AI 4×, HDR AI output, and batch AI upscaling are not provided. Save a PNG copy before closing. The original file is unchanged.

[Back to top](#top)

---

<a name="quality"></a>

## 15. Understand display quality, HDR, and loading

High-Quality Zoom changes display interpolation. AI Upscaling creates a larger image you can save. HDR output is a display preference, not a label that proves a photo is HDR.

### How to

1. For smoother display, turn on High-Quality Zoom. Its side-by-side or top-and-bottom comparison shows the same photo with linked zoom and pan; Esc closes that comparison.
2. Use HDR ON / HDR OFF to allow or disable extended-range display. In Settings → General → Image Loading, choose Priority, Comfortable, Normal, or Slow for your workload.

### Formats and performance

Reading and writing support depend on the running macOS. The app adds QOI and common PCX decoding, plus an SVG/SVGZ fallback. BPG and .clip are not included. Comfortable is the default loading mode. Every mode slows down for memory pressure, heat, low power, other apps, or slower storage.

### Good to know

- During rapid navigation, a small preview or the previous photo can remain visible until the final image is ready.

[Back to top](#top)

---

<a name="slideshow"></a>

## 16. Play a Photo Album or set wallpaper

Photo Album automatically advances through the current list in a focused single-image view. Wallpaper uses a separate copy prepared for the chosen displays.

### How to

1. Open a list with at least two photos and no videos. If videos are included, turn off Show Videos first. Choose Navigate → Photo Album → Play Photo Album or press ⌃⌥P.
2. Use the playback controls to pause. Choose an interval of 1–300 seconds and whether to repeat, either from the time control or Settings → General → Photo Album.
3. To set wallpaper, return to the regular viewer and choose Image → Set Current Image as Wallpaper… or press ⌃⌥W. Select the current or all connected displays, Fill or Fit, and whether to apply current adjustments; then apply.

### Playback behavior

The default interval is five seconds with repeat on. Timing starts after a preview or image is displayed, so loading time does not consume the viewing interval. Manual navigation or an interval change restarts the timer. With repeat off, playback stops on the final image.

### Automatic pauses

Playback pauses when leaving focus mode, switching to another app, sleeping, or starting file work. The display is kept awake only during playback. Relaunch restores settings but never starts the album automatically.

### Wallpaper copies

The app creates a PNG without altering the source. Animated input uses the first frame and HDR is prepared as SDR. Copies exclude EXIF/GPS, are sized for the display up to 8192 pixels, and remain in the app's Application Support/Wallpapers folder. Other desktop Spaces follow macOS behavior. Previous copies are not automatically deleted because another Space may still use them. Videos cannot be set as wallpaper.

### Good to know

- If playback is unavailable, check that the current filtered list contains at least two photos and no videos, and that Tagging, Image Comparison, or another operation is not active. Hiding videos makes an otherwise eligible photo list available again.

[Back to top](#top)

---

<a name="settings"></a>

## 17. Make the app work your way

Settings groups everyday viewing choices, custom shortcuts, tag assignments, and default file associations. Many viewing choices return automatically at the next launch.

![Settings keeps the main preferences in four tabs.](figures/settings.png)

**Screen 14.** Settings keeps the main preferences in four tabs.

1. **Settings tabs** — General, Shortcuts, Photo Tags, and File Associations each cover a different task.
2. **Viewing preferences** — Set display, thumbnail, filename, navigation, and loading choices.
3. **Inline explanations** — Read the text below a control or hover over it for details about its behavior.

### How to

1. Open 알맹Re → Settings…. In General, choose HDR/EDR output, thumbnail position, filename size, high-quality zoom, folder-tree visibility, whether navigation wraps, and Show Videos.
2. Use Photo Tags to save shared names and colors, and Shortcuts to choose keys and modifier combinations. Hover over controls for explanations.
3. For Finder to open selected formats with this app, place 알맹Re.app in a stable location such as Applications, open File Associations, select only the desired format groups, and apply.

### Language

The interface follows the language assigned to the app by macOS. Change it in System Settings → General → Language & Region → Applications, then relaunch the app. Supported languages are Korean, English, Japanese, Simplified Chinese, Vietnamese, Spanish, French, German, Russian and Arabic. Basic Usage follows the app language. Detailed guides cover seven languages; German, Russian and Arabic open the English guide.

### Remembered preferences

Thumbnail size, high-quality zoom, filename display, loading preferences, favorites, tag settings, and custom keys are retained. Show Videos is on by default and remembers your choice; GIF visibility is unchanged. Continue Previous Session on Home restores the last collection and viewing position if files remain accessible. Magnification-quality comparison starts off after relaunch. Visual editing adjustments and AI results must be exported separately.

### File associations

Only the checked format groups are changed. macOS may ask for confirmation. Moving the app later or keeping older copies can cause Finder to open the wrong version; reapply associations from the version you intend to use.

### Good to know

- General lists the native formats available on your Mac and offers Clear Image Cache. Video playback uses built-in macOS codecs and checks each file when opened; no external codec installation is required. Choose a slower loading mode for less background work. RAW thumbnails use embedded previews when available; thumbnails large enough for the current view are reused across viewing modes. Initial display speed depends on the file and your Mac.

[Back to top](#top)

---

<a name="shortcuts"></a>

## 18. Shortcuts and quick troubleshooting

The reference that follows lists the app's default action keys and fixed contextual keys. ⌘ means Command, ⌥ Option, ⌃ Control, and ⇧ Shift.

![The Shortcuts tab shows configurable actions and conflict feedback.](figures/shortcuts.png)

**Screen 15.** The Shortcuts tab shows configurable actions and conflict feedback.

1. **Actions** — Hover over an action name to learn where and how it works.
2. **Keys and modifiers** — Choose the key, then toggle Control, Option, Shift, or Command.
3. **Conflicts and defaults** — Resolve duplicate combinations or use Restore Defaults to start over.

### How to

1. Open Settings → Shortcuts to change an action's key and modifiers. Changes are saved and current assignments appear in menus.
2. Check conflict indicators when assigning the same combination to more than one action. Hover over the action, key picker, modifier, or conflict icon for help. Restore Defaults resets the configurable action keys.
3. If a key behaves unexpectedly, leave a text field and check the current mode. Tagging uses its twelve keys for tags; Image Comparison gives Option arrows their A/B navigation meaning.

### No images or no matches

Clear search, format, tag, and map filters. Check that the input format is readable on this macOS. An empty folder can still be opened so you can navigate its subfolders. Reopen a disconnected drive or moved collection with Open….

### A command is disabled

Finish or cancel the current file operation first. Exit Image Comparison for editing, batch conversion, or wallpaper. ZIP members cannot be renamed or have source metadata rewritten. Map result buttons wait for a nonempty, fully calculated selection.

### Space, Esc, and Option arrows

Space is a focus gesture only when no custom action uses plain Space and you are not typing. Esc unwinds the active mode or cancels a selection gesture. Viewer Option-arrow page navigation is fixed but yields to a custom regular-viewer action assigned to that combination.

### Good to know

- The circular i and slider buttons open photo information and editing. Use the buttons or Navigate menu; I and E are not default panel-toggle shortcuts in this version.

[Back to top](#top)

---

<a name="shortcut-reference"></a>

## Shortcuts at a glance

| Keys | Action | When it applies |
| --- | --- | --- |
| ← / → | Previous / next image or page | Configurable. With Tagging ON or OFF, Viewer moves a full page and All at Once moves one item. Comparison follows A Only / Both / B Only. |
| ↑ / ↓ | Select the row above / below | Works in All at Once and multiple-item Viewer with Tagging ON or OFF. Viewer stays within the current page. Stops at row boundaries; custom shortcuts take priority with Tagging OFF. |
| ⌥← / ⌥→ | Previous / next viewer page | Fixed contextual keys when Viewer shows multiple images, including during Tagging; custom viewer assignments take priority. |
| = / − | Zoom in / out | Configurable; applies to the regular viewer or active comparison view. |
| 0 / 1 | Fit to Window / Actual Size | Configurable. Plain 1 is a tag key while Tagging is active. |
| G | Toggle All at Once | Configurable viewing action. |
| F | Toggle focus mode | Configurable. Plain F is a tag key while Tagging is active. |
| Space (tap) | Toggle focus mode | Viewer gesture; inactive while typing or when a custom action uses Space. Holding Space for a pan gesture does not toggle focus. |
| ⌃⌘F | Toggle Full Screen | Fixed app-menu shortcut; separate from focus mode. |
| \[ / \] | Show fewer / more images per screen | Configurable; range 1–10 in Viewer. |
| ⌘O | Open images, folders, or ZIP archives | Configurable; in comparison, opens in the active unlocked pane. |
| ⌘E | Export current image | Configurable; regular viewer workflow, unavailable in Image Comparison. |
| ⌃⌥1 | Select left-drag panning | Configurable; selects a pan method rather than moving the image. |
| ⌃⌥2 | Select Space + left-drag panning | Configurable pan-method selection. |
| ⌃⌥3 | Select right-button panning | Configurable pan-method selection. |
| ⌃⌥4 | Select middle-button panning | Configurable pan-method selection. |
| ⌃⌥5 | Select two-finger trackpad panning | Configurable pan-method selection. |
| ⌃⌥A | Toggle High-Quality Zoom | Configurable display setting; does not alter exported files. |
| ⌃⌥6 / ⌃⌥7 | Compare zoom quality side by side / top and bottom | Configurable; two renderings of the same image in Viewer. |
| ⌃⌥0 | End zoom-quality comparison | Configurable; Esc also closes this comparison. |
| ⌃⌥P | Play / pause Photo Album | Configurable; needs at least two photos and an available regular-viewer workflow. |
| ⌃⌥W | Set current image as wallpaper | Configurable; opens wallpaper options outside Image Comparison. |
| ⌃⌥C | Enter / leave Image Comparison | Configurable; keeps the preceding regular-viewer collection. |
| ⌥← / ⌥→ | Previous / next in A only | Configurable comparison action; A is left or top. A locked pane stays fixed. |
| ⇧⌥← / ⇧⌥→ | Previous / next in B only | Configurable comparison action; B is right or bottom. A locked pane stays fixed. |
| ⌘⇧M | Toggle Tagging mode | Fixed app-menu shortcut. |
| 1 2 3 4 · Q W E R · A S D F | Toggle twelve tags on photos and videos | Fixed physical keys with Tagging ON. Affect the current item, the Apply Tags target in comparison, or that video in full screen. Never delete or upload files. |
| ← / → · ↑ / ↓ | Move between pages / items / rows while tagging | ←/→ moves a full page in Viewer or one item in All at Once; grid ↑/↓ moves one row. In single-item Viewer and Image Comparison, ↑/↓ moves to the previous or next item. Comparison follows navigation settings independently of Apply Tags. |
| ⌘A | Select all images in the current list | Fixed selection shortcut outside Image Comparison; text fields retain normal text selection. |
| Esc | Cancel the current gesture or leave the active mode | Fixed. Exits Tagging, comparison, zoom-quality comparison, or focus; regular Viewer returns to All at Once. Also cancels area-selection gestures. |

[Back to top](#top)
