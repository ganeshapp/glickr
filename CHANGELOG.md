# Changelog

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
