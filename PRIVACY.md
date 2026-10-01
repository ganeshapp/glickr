# glickr Privacy Policy

_Last updated: 2026-10-02 (v1.1.0)_

glickr is an open-source app for Android, macOS and Linux that manages photo
albums stored as folders in **your own GitHub repository**, so a Jekyll site
can render them. Nothing you upload passes through a glickr server, because
there is no glickr server.

## The short version

- There is **no glickr server, no analytics, no crash reporting and no account**.
- Your photos go from your device to **your own GitHub repository** and nowhere
  else.
- **EXIF metadata, including GPS coordinates, is stripped from every photo
  before upload.**
- **A public repository is public forever, and git history keeps a photo even
  after you delete it.** See "What you should know before uploading" below.

## What you should know before uploading

This is the part that matters most, so it comes first.

- **Album repos have to be public.** Media in your albums is fetched over
  `raw.githubusercontent.com`, which will not serve a private repository
  without a token, and GitHub Pages publishes your site from that repository.
  So anything you put in an album is readable by anyone who has - or guesses -
  the URL, whether or not your site links to it.
- **Deleting a photo does not remove it from the repository's history.** Git
  keeps every version of every file. When glickr deletes a photo it commits the
  removal, so the file stops appearing on your site and stops being served at
  its old URL - but the blob is still in the repo's history, and anyone can
  fetch it from an older commit. Genuinely erasing it means rewriting history
  with a tool like `git filter-repo` and force-pushing, which glickr cannot do
  for you.
- **EXIF is stripped, but faces, street signs and house numbers are not.** The
  app removes the metadata; it cannot remove what is in the picture.

Do not put photos in an album repo that you would mind a stranger seeing.

## What leaves your device

The app talks **only to GitHub**:

- `api.github.com` - reading and writing the repository you configured
  (listing trees, creating blobs, commits and refs), listing the repositories
  and branches you can write to, and checking your sign-in (`GET /user`).
- `github.com` - the Device Flow sign-in endpoints (`/login/device/code`,
  `/login/oauth/access_token`) when you use "Sign in with GitHub".
- `raw.githubusercontent.com` - loading your albums' photos and videos for
  display in the app.

Nothing is sent anywhere else. There is no telemetry of any kind, and the
developer never receives your photos, your token, or anything about your
account.

## What the app does to your media before uploading

- Photos are re-encoded as JPEG at the size the quality preset you picked
  implies, and **EXIF metadata - including GPS location, camera model and
  timestamps - is stripped**. The EXIF orientation tag is baked into the pixels
  first, so a rotated photo still appears the right way up.
- Videos are re-encoded to MP4 and capped at 40 MB each.
- Files are renamed to a four-digit sequence number in the order you selected
  them (`0001.jpg`, `0002.mp4`, and so on). The original filename is not
  uploaded.
- Captions and album summaries you write are stored in `album.json` inside the
  album folder, and album notes in `album.md`. Both are committed to your
  repository like any other file.

## What the app stores on your device

| Data | Where | Why |
|------|-------|-----|
| GitHub access token (PAT or Device Flow token; also a refresh token and expiry when the sign-in returns them) | Android Keystore-backed encrypted storage (`EncryptedSharedPreferences` via `flutter_secure_storage`) | Authenticating GitHub API calls |
| The Client ID the Device Flow sign-in used | Same encrypted storage | Signing back in without asking again |
| Cached album metadata: folder names, filenames, captions, descriptions and blob shas | Local Hive database | Showing albums offline and syncing only what changed |
| The upload queue and its staged, already-compressed files | Local Hive database and app-private storage | Resuming an interrupted upload |
| Caption edits you have not saved yet | Local Hive database | Batching a whole album's captions into one commit |
| Repository configuration (owner, repo, branch, albums folder, site URL, quality preset, cache budget) | Local Hive database | Knowing where to read and write |
| Downloaded photos and videos | Disk cache, bounded by the budget you set in Settings | Not re-downloading the same photo every time |

Device backups are disabled for the app (`android:allowBackup="false"`), so none
of this is copied into Android or cloud backups.

**On macOS and Linux** the token is kept in the login keychain (macOS) or the
desktop's Secret Service keyring (Linux) instead, and the rest in the app's own
data folder. The picker reads only what you choose: the Photos library on
macOS, once you allow it, and on Linux the photos in a folder you pick.

## Your GitHub token

- **"Sign in with GitHub"** (Device Flow) uses the Client ID of glickr's OAuth
  App, which is compiled into the app. A Client ID is a public identifier, not a
  secret - no client secret is involved, and no token can be issued without you
  approving a device code on github.com.
- The token carries the **`public_repo` scope**: read and write access to your
  public repositories only. It cannot read your private repositories. That is
  not a compromise here - an album repo has to be public for your site to serve
  it.
- A **Personal Access Token** you paste in yourself is stored as-is in the same
  encrypted storage. A fine-grained token scoped to your album repository grants
  the least access.
- The token is only ever sent to GitHub over HTTPS, and it is never logged.

## What logout deletes

Logging out removes from the device your access token, refresh token and auth
session data. The Client ID is kept (it is not a secret) so signing back in
stays one tap. Cached albums, the upload queue and the media cache are cleared
when you switch to a different repository or clear the cache from Settings.

**Logging out is local only - it does not revoke the token on GitHub.** To end
the authorization itself, go to github.com → **Settings** → **Applications** →
**Authorized OAuth Apps** and revoke glickr (or delete the Personal Access Token
under **Settings** → **Developer settings**).

Anything already committed to your repository is untouched by any of this.

## Permissions the app requests

- **Internet / network state** - GitHub API access and offline detection.
- **Photos and videos** (`READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`,
  `READ_MEDIA_VISUAL_USER_SELECTED`) - reading the gallery so you can pick what
  to upload. Only the items you select are read, and Android's "selected photos"
  mode is supported, so you can grant access to individual photos rather than
  the whole library.

The app does not request camera, location or contacts access.

## Changes and contact

This policy may change as the app evolves; the current version always lives at
[github.com/ganeshapp/glickr/blob/main/PRIVACY.md](https://github.com/ganeshapp/glickr/blob/main/PRIVACY.md).
Questions or concerns: [open an issue](https://github.com/ganeshapp/glickr/issues).
