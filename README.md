<div align="center">

<img src="assets/brand/glickr_icon_1024.png" width="112" alt="glickr">

# glickr

**albums, versioned.**

A mobile app for managing photo albums that live in a GitHub repo.

</div>

---

glickr is a Flutter app for the case where your photo albums are just folders in a git repository -
the layout a static site generator can render directly. You pick photos on your phone, glickr
compresses them, converts them, names them, and writes them to your repo through GitHub's API.
Your phone never clones anything.

It was built for [gapp.in](https://gapp.in), whose albums live in `assets/albums` inside its Jekyll
site repo, but it works with any repo that follows the same convention - and it will happily set one
up for you.

## What it does

- **Sign in with GitHub** via the OAuth Device Flow. No password ever reaches the app, and no
  client secret ships in it.
- **Browse your albums** offline-first. The grid renders from a local cache before any network call,
  so opening the app is instant and works on a plane.
- **Pick from your gallery** in an in-app grid that shows selection *order* - because that order
  becomes the filenames, which is the order your website will display.
- **Compress and convert** everything to JPEG or MP4 at Low / Medium / High, stripping EXIF
  (including GPS) on the way.
- **Upload as one commit**, resumable. Thirty photos is one commit, not thirty.
- **Manage albums**: rename, re-cover, edit summaries, notes and captions, delete photos or whole
  albums - each as a single atomic commit.

## How albums are stored

Flat. One folder per album, inside whichever folder you point glickr at - the repo root for a
dedicated album repo, or something like `assets/albums` inside a site repo:

```
assets/albums/
  cycling_trip/
    0001.jpg        <- the first photo, and therefore the album's cover
    0002.jpg
    0003.mp4
    album.json      <- one-line "summary" and per-item captions
    album.md        <- optional long note, markdown, album page only
  barcamp-days/
    ...
```

The rules glickr follows, all of them ported from the site's own generator and covered by tests in
[`test/album_conventions_test.dart`](test/album_conventions_test.dart):

| Rule | Why |
|---|---|
| Only `<folder>/<file>` paths count | The site ignores anything nested deeper |
| The cover is the *first image* | There is no separate cover file. Images only - a video can't be a cover |
| Files sort lexicographically | Filename order *is* display order |
| New files are `0001.jpg`, `0002.mp4`, … | One number space, so photos and videos interleave correctly |
| Four digits, not three | `"1000.jpg" < "999.jpg"` as strings - at three digits the 1000th photo jumps to the front |
| `cycling_trip` renders as "Cycling Trip" | Underscores and hyphens become spaces, each word capitalized |
| …but its URL is `/albums/cycling-trip/` | Jekyll slugifies underscores to hyphens |

A number is never reused. `album.json` carries a monotonic `next` counter that deleting a photo
never lowers, so a future upload cannot inherit a deleted photo's caption.

## Getting started

### 1. Sign in

Tap **Sign in with GitHub**, approve the code on github.com, done. glickr ships with its own OAuth
App client id, so there is nothing to register. A device-flow client id is public by design - there
is no client secret, and getting a token still requires you to approve a code while signed in - so
shipping it is safe.

Fork builds can substitute their own:

```bash
flutter build apk --release --dart-define=GITHUB_CLIENT_ID=Ov23li...
```

glickr requests the `public_repo` scope - the narrowest one that can write files. It deliberately
does *not* ask for `repo`, which would grant a photo app read/write access to every private
repository you own.

### 2. Point it at a repo and a folder

Pick a repo, then pick the folder inside it that albums go in. Two shapes both work:

- **A dedicated album repo** - pick the repo, leave the folder at the root.
- **Your site repo** - pick e.g. `ganeshapp.github.io`, then browse to `assets/albums`. glickr only
  ever touches paths under that folder, so the rest of your site is untouched.

The repo must be **public**: photos are fetched over `raw.githubusercontent.com`, which serves
public repositories only.

### 3. Build and run

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

Requires Flutter 3.29.3. Newer SDKs currently break `hive_generator` / `riverpod_generator`
codegen, so the version is pinned in CI too.

## Showing captions on your site

Captions go into `album.json`, which most Jekyll album generators don't read - so they stay
invisible on the website until you teach it to.
[`extras/album-captions-jekyll.md`](extras/album-captions-jekyll.md) has the exact change: about ten
lines of Ruby plus a Liquid tweak to render them under each photo and in the lightbox.

## Design notes

A few decisions that are load-bearing and non-obvious:

**The Git Data API, not the Contents API.** The Contents API is one commit per file. Thirty photos
would be thirty commits, thirty cache generations (so every *other* album's thumbnails miss cache
thirty times), and thirty chances to leave an album half-written. glickr creates blobs, then
one tree, then one commit, then moves the ref - so any number of files lands atomically, and
renaming an album moves zero bytes because blob shas are content addresses.

**Uploads resume because filenames are assigned late.** Each blob sha is persisted the instant it
returns. If the branch moves while you're uploading, glickr rebuilds the tree against the new head
and *renumbers* - it never re-uploads.

**The byte cache is keyed on blob sha, not URL.** Media URLs are pinned to the head commit, which
changes on every push to any album. Keying on the URL would re-download an entire album's
thumbnails because one photo was added to a different one.

**Photos are fetched from `raw.githubusercontent.com`, not a CDN.** jsDelivr is faster, but it
refuses any GitHub "package" over 50 MB - and that limit is measured across the *whole repository*,
which a site repo blows past quickly. The failure mode is a 403 and a blank grid with nothing to
explain it. raw has no size limit and is fresh the instant a commit lands, so a just-uploaded photo
is viewable immediately. jsDelivr is still selectable for a small dedicated album repo.

**Albums are home, not your camera roll.** The concept sketch had the device gallery as the main
screen. That makes the app a picker with a backend: it needs a permission dialog before it can draw
a single pixel, it inverts the common flow (which is "add today's photos to yesterday's album"),
and it gives a returning user a screen identical to their photo app.

## Cutting a release

Bump `version:` in `pubspec.yaml`, add a `CHANGELOG.md` entry, then:

```bash
tool/release.sh --upload
```

That builds all four APKs a release ships - `arm64-v8a` for essentially every phone since 2017,
`armeabi-v7a` for older 32-bit ones, `x86_64` for Intel emulators, and a `universal` catch-all -
names them from `pubspec.yaml`, and prints the ABIs each one actually contains. Run it without
`--upload` to stage them in `build/release/<version>/` without touching the tag.

Do not publish `flutter build apk --release` output on its own: that is a single universal APK, and
1.0.1 first shipped with only that, dropping the per-ABI downloads 1.0.0 had.

## Limitations

- Android only.
- Album repos must be public, so anything you upload is readable by anyone with the link.
- GitHub Pages publishes at most 1 GB per site. glickr shows a live meter and blocks uploads before
  you cross it. Note git keeps every version of every photo forever, so deleting an album does not
  give the space back.
- Photos appear in upload order. There's no manual reordering, because the site sorts by filename.
- Adding photos to an album with older, differently-named files puts the new ones *first*.
- Renaming an album changes its web address and breaks old links.
- Videos are re-encoded to H.264 MP4 and capped at 40 MB each. AVI can't be converted on Android.
- Keep glickr open while uploading. If it's interrupted it resumes next launch.

## Privacy

EXIF - including GPS coordinates - is stripped from every photo before upload. glickr talks only to
`github.com`. It has no server of its own, no analytics, and no account. Your token lives in the
Android keystore.

Worth saying plainly: a public repo is public forever. Git history keeps a photo even after you
delete it.

## License

MIT. See [LICENSE](LICENSE).
