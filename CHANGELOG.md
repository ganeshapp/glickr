# Changelog

## 1.1.2 — 2026-10-02

### Fixed

- **Videos no longer carry their location into your repo.** The video
  re-encoder keeps the source clip's metadata - the GPS fix on an Android
  recording, the location and camera keys on a Mac - while photos had theirs
  stripped. glickr now blanks the MP4's metadata boxes before upload, and
  skips a clip it cannot do that to.
- **A keychain that refuses no longer strands you on the splash screen.** On
  Linux without a Secret Service keyring, or after Deny on the macOS keychain
  prompt, the launch check now lands on the sign-in screen, which says why
  (on Linux, which keyring to install), and a sign-in that cannot be saved
  says so in plain words.

### Changed

- **One keychain item on macOS, and the old shared one is cleaned up.** The
  sign-in is now kept as a single item under `com.glickr.glickr`, so an update
  asks you to allow keychain access once rather than once per field; a session
  saved by 1.1.1 is carried over (that one update asks once per saved field
  one last time - the migration into the single item). The entries 1.1.0 left
  under the name every flutter_secure_storage app shares are deleted on first
  launch - deleted only, never read, since that slot can belong to another
  app. If you were signed in with 1.1.0, sign in again once.
- **Desktop data and cache have fixed, private, per-user homes.** On Linux
  the app's files live in `~/.local/share/com.glickr.glickr` and the media
  cache in `~/.cache/com.glickr.glickr` (or under `$XDG_DATA_HOME` /
  `$XDG_CACHE_HOME`), created mode 0700. Before, the data folder moved between
  two names depending on whether a GLib development package was installed,
  and the cache sat in `/tmp` - shared with every account on the machine and
  emptied at boot. On macOS the cache moves from the temp folder, which is
  purged after three days, to `~/Library/Caches/com.glickr.glickr`. The
  cache index now lives next to the files.
- **Linux: launching glickr while it is running raises the open window**
  instead of opening a second, blank one.
- **macOS reads HEIC.** A folder exported from Photos is mostly HEIC, which
  the pure-Dart encoder cannot decode; on a Mac each one now goes through the
  system's `sips` first. Linux still lists JPEG, PNG and WebP only and says so.
- **Mouse and keyboard equivalents on desktop.** The album list has a Refresh
  button, a right-click on an album or photo does what a long-press does,
  Enter submits the rename dialog, and the macOS share picker opens from the
  menu that asked for it.
- **Copy that is true on a laptop.** About no longer says "Android only" or
  "your phone"; the Wi-Fi-only switch is not offered on desktop, where no
  transport is metered; and the README and privacy policy name where glickr
  keeps its files on each OS and what uninstalling leaves behind.
- **macOS refuses to quit mid-upload.** Cmd+Q or closing the window while
  a batch is running now keeps the app open and says why, instead of ending
  the process with a commit in flight.
- **The Linux package recommends GNOME Keyring**, so `apt install` on a
  desktop without a Secret Service keyring brings one along.
- **macOS picks photos from a folder, like Linux.** 1.1.0 read the Photos
  library, which on most Macs is empty, so "Add photos" showed nothing. Both
  desktops now use **Choose folder**; desktop uploads are photos only. (The
  first cut of this had no macOS folder dialog behind it - CI now checks that
  every desktop build links one.)

## 1.1.1 — 2026-10-02

### Fixed

- **macOS asked for the login keychain password on first launch.** glickr
  stored its sign-in under flutter_secure_storage's default keychain service
  name, which JekyllPress uses too, so it tried to read JekyllPress's token
  item and macOS blocked it. glickr now has its own keychain service name.
  Android and Linux are unaffected.

## 1.1.0 — 2026-10-02

### Added

- **glickr runs on macOS and Linux.** Each release now carries a universal
  `.dmg` for macOS 10.15+ and a `.deb` and `.tar.gz` for 64-bit Linux
  (Ubuntu 24.04 or newer), built from the same code. On macOS it picks from
  the Photos library, videos included, just like the phone. Linux has no
  photo library, so you choose a folder and pick from its photos, in order, in
  the same grid; Linux uploads photos only, and opens videos in your default
  player. The macOS build is not notarized - the README has the one-time
  "Open Anyway" step. Grids fit more columns in a wide window, the viewer
  pages with the arrow keys, and a mouse drag pulls the album list to refresh.

### Changed

- **An album now has a summary and an optional note.** The summary is one line
  in `album.json`, shown on the album list and under the title; the note is
  markdown in `album.md`, shown only on the album page. Both can be set when
  creating an album, and are edited together in one commit. Your site must
  read `summary` from `album.json` to show it - see the README.

## 1.0.2 — 2026-08-20

Two bugs found using 1.0.1, both older than it.

### Fixed

- **You couldn't swipe between photos.** You also couldn't drag down to
  dismiss, or tap to hide the controls — but the back button and the menu
  worked, which is why it looked like only swiping was broken. The top bar's
  gradient had no height limit, so it sized itself to the whole screen, and a
  rectangular decoration answers a hit test anywhere inside itself. It was a
  full-screen trap that caught every touch aimed at the photo before the pager
  could see it. Measured: the pager was reachable from *no pixel of the
  screen*. Present in 1.0.0 and 1.0.1.
  Photos are also visibly brighter now — that gradient was laying roughly 27%
  black over the entire image, not just the strip behind the controls.
- **Captions still committed one at a time**, despite 1.0.1 saying otherwise.
  The saving half shipped and the staging half did not: the album screen got
  the "N unsaved" banner and the Save button, while the viewer — the only place
  a caption can actually be typed — went on committing each one immediately.
  Editing a caption now stages it on the device, every view of that caption
  shows what you typed straight away, and the viewer carries its own unsaved
  count so you can save without going back. Each commit was starting a site
  build that cancelled the one before it.

### Also

- Deleting, renaming or changing the cover of an album now keeps its unsaved
  captions consistent no matter which screen you did it from, and switching
  repositories no longer carries one repo's unsaved captions into another's.
- The full-screen viewer had no tests at all, which is how both bugs shipped
  twice. It has 31 now; 25 of them fail against 1.0.1.

## 1.0.1 — 2026-08-20

Everything here came from using 1.0.0 against a real repo.

### Fixed

- **The cover was published twice.** An album's cover was written both as
  `0.jpg` and under its number, so a 23-photo album committed 24 files, the
  cover appeared in its own album twice, and a caption typed on it attached to
  only one of the two copies. There is no separate cover file any more — the
  cover is simply the album's first image, which is where it already sorted.
- **Videos showed as blank tiles.** The tile was handing an `.mp4` to an image
  decoder. Videos now render a poster frame, cached against the blob sha.
- **The play button in the viewer did nothing.** Before a clip finished
  initializing the badge was drawn with no play handler attached at all, so the
  tap only toggled the chrome. The button now works in every state; tapping
  before the clip is ready starts it the moment it arrives.
- **Every caption was its own commit**, so captioning an album triggered a site
  rebuild per photo. Caption edits now stage on the device and commit together.
  The album screen shows how many are unsaved, and going back warns you first.
  **This claim was wrong — see 1.0.2.** Only the saving half shipped; nothing
  ever staged, so captions kept committing one at a time.
- **The keyboard covered the Advanced fields** in repo setup, along with the
  confirm button, with no way to scroll them into view.
- **About linked to the wrong repo.** It opened whichever album repo was
  configured, as though that were the app's source, and credited no one.
  Rebuilt, attributed, and joined by a `PRIVACY.md` that leads with the two
  things actually worth knowing: an album repo is public, and deleting a photo
  leaves it in git history.

## 1.0.0 — 2026-08-20

First release.

### Albums

- Browse albums offline-first. The grid renders from a local cache before any
  network call, so opening the app is instant and works on a plane.
- Create albums, rename them, edit descriptions, set any photo as the cover,
  delete photos or whole albums — each as a single atomic commit.
- Per-photo captions, written to `album.json`.
- Full-screen viewer with pinch-zoom, swipe, drag-down-to-dismiss and video
  playback.
- Live repo-size meter, because the host's size limit is measured across the
  whole repository and the failure mode is a broken website rather than an
  error message.

### Uploading

- In-app gallery picker showing selection **order**, because that order becomes
  the filenames, which is the order the website displays. That is why there is
  no manual reordering — the numbers you see when picking are the answer.
- Low / Medium / High presets. Everything is converted to JPEG or MP4, and EXIF
  — including GPS — is stripped before anything leaves the device.
- A whole album uploads as **one commit**, not one per file.
- Uploads resume. Every blob sha is persisted the moment it returns, so an
  interrupted upload picks up where it stopped rather than starting over, and a
  batch whose commit already landed commits nothing the second time.
- Uploads survive navigation: the progress tray is mounted above the navigator,
  so it stays visible wherever you go in the app.

### Setup

- Sign in with GitHub device flow. Nothing to register — glickr ships its own
  OAuth App client id. A device-flow client id is public by design: there is no
  client secret, and getting a token still requires approving a code while
  signed in.
- Requests `public_repo` only, not `repo`. A photo app has no business holding
  read/write on every private repository you own.
- Pick a repo **and** the folder inside it. Albums can live at the root of a
  dedicated album repo, or under something like `assets/albums` in a site repo,
  in which case nothing outside that folder is ever touched.

### Known limitations

- Android only.
- Repos must be public — photos are fetched over `raw.githubusercontent.com`,
  which serves public repositories only.
- Adding photos to an album that already contains older, differently-named
  files places the new ones *first*, because the site sorts by filename.
- AVI cannot be converted on Android and is rejected up front rather than
  failing silently mid-upload.
- Keep glickr open while an upload runs. If it is interrupted it resumes on the
  next launch.

### Signing

This release is signed with a debug key, so it cannot be updated in place by a
future release signed with a real one — you would need to uninstall first,
which costs you the local cache and a re-login, nothing on GitHub.
`android/app/build.gradle.kts` documents how to set up a release keystore; the
build picks it up automatically once `android/key.properties` exists.
