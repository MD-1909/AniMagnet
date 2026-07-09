<p align="center">
  <img src="logo.png?v=2" width="120" alt="AniMagnet icon"/>
</p>

# AniMagnet

A Flutter Android app for tracking and downloading anime torrent releases from [nyaa.si](https://nyaa.si).

<img src="screenshots/preview.jpg?v=3" width="320" alt="AniMagnet home screen"/>

---

## About

This app was born out of necessity after [AnimeTosho](https://animetosho.org) — my primary torrent aggregator for anime — shut down. AnimeTosho made it incredibly easy to find, filter, and grab releases in one place. Without it, using nyaa.si directly felt clunky, especially on mobile. Scrolling through nyaa in a browser, manually searching for each show, and juggling which releases I had and hadn't grabbed was a pain.

I wanted a proper mobile app built around my workflow: a watchlist of ongoing anime that surfaces new releases the moment they're up, with one tap to open the magnet link in my torrent app. Since I have no background in Android development, this app was **built entirely by Claude Opus 4.8**. I described what I wanted, Claude wrote every line of Dart/Flutter code, and the result is exactly the app I was looking for.

---

## Features

- **Watchlist** — track ongoing anime by release group and quality; the card title is always the clean AniList display name, not the raw search string
- **Auto-add** — search a title, pick the release version you want from episode 1 results; the episode-1 release title is parsed to extract the exact nyaa search string (strips group tag, episode marker, quality token) so future RSS queries find the right season reliably
- **Group & quality pickers** — the edit screen offers one-tap chips for the common release groups (ASW, DKB, Judas, ToonsHub) plus an "Other" text field; picking any group triggers a live nyaa check to confirm that group actually carries this anime, with a count of matching releases and per-quality availability greying in the quality picker
- **Release feed** — on launch and pull-to-refresh, queries each entry's nyaa RSS, filters to matching releases (newest first), shows size and publish date
- **Seen/unseen tracking** — only unseen releases shown by default; tap to expand watched ones. Opened releases lose the NEW dot automatically
- **One-tap magnet** — tap a release to open the magnet link directly in your torrent app
- **Predictive notifications** — schedules a local notification timed to when the episode is expected on nyaa: uses AniList's broadcast schedule (airing time + ~2 h upload delay) when available, falling back to median-interval cadence prediction from past releases
- **Cover art & airing schedule** — pulled from AniList by title and cached; the edit screen includes a live AniList search picker so you can find and set the exact season without leaving the app
- **Sorting** — sort your watchlist by title, last episode release, or last added; sort mode and direction are persisted across restarts; manually drag-reordering an entry clears the active sort
- **Per-anime notification toggle** — enable or disable release alerts on a per-show basis
- **Debug log export** — ⋮ → Export debug log writes a timestamped `.txt` of all AniList, notification, and nyaa events and opens the share sheet
- **AMOLED black UI** with blue accents

---

## Download

Grab the latest APK from the [Releases](../../releases) page and sideload it onto your device.

---

## Build from Source

### Requirements

- **Flutter SDK** (stable channel) — [install guide](https://docs.flutter.dev/get-started/install/windows)
- **JDK 17** — must be exactly 17 or 21. JDK 22+ breaks the Android build pipeline. [Temurin 17](https://adoptium.net) recommended
- **Android SDK** — Command-line tools only (no Android Studio needed). [Download here](https://developer.android.com/studio#command-line-tools-only)

After installing, point Flutter at them:
```powershell
flutter config --jdk-dir "C:\path\to\jdk17"
flutter config --android-sdk "C:\Android"
flutter doctor
```

### Build

```powershell
git clone https://github.com/MD-1909/AniMagnet.git
cd AniMagnet
flutter pub get
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

Install on a connected device:
```powershell
adb install build/app/outputs/flutter-apk/app-release.apk
```

---

## Project Structure

```
lib/
  main.dart                    app entry + AMOLED dark theme + service wiring
  models/
    release.dart               one parsed nyaa torrent
    watch_entry.dart           tracked anime (title/group/quality, match + searchTitle)
  services/
    nyaa_service.dart          RSS fetch/parse, magnet construction, version search
    anilist_service.dart       GraphQL cover art + airing schedule lookup
    storage_service.dart       shared_preferences (watchlist + seen GUIDs)
    posting_predictor.dart     median-interval prediction of next episode post time (fallback)
    notification_service.dart  schedules episode alerts via exact AlarmManager alarms
    log_service.dart           in-memory event log (ANIME/ANILIST/NOTIFY/NYAA), export as .txt
  screens/
    home_screen.dart           anime cards: art left, unseen releases right, expand watched
    add_entry_screen.dart      search → pick version → save pattern
    edit_entry_screen.dart     manual add/edit
  widgets/
    release_tile.dart          compact release row: NEW dot + size/date/seeders + magnet
```

### How Notifications Work

Notifications use AniList's broadcast schedule as the primary signal. When AniList has a `nextAiringEpisode` date for a show, the alert is scheduled at `airing time + 2 hours` — enough time for most groups to process and upload the episode. Quick remux groups (SubsPlease, Erai-raws) typically post within an hour; encode groups take 2–4 hours. The 2-hour default works well for most actively tracked series.

If AniList has no upcoming schedule (completed series, or before the first refresh resolves a match), the app falls back to `PostingPredictor`: it collects past nyaa release timestamps, collapses near-duplicate re-uploads within 12 hours, and uses the **median interval** between posts to predict the next one. Requires at least 2 past releases.

Alerts use exact alarms (`SCHEDULE_EXACT_ALARM` permission, granted via the system Settings prompt on first launch). On Samsung One UI the app also requests battery optimization exemption — without it, Samsung silently blocks the `AlarmManager` broadcast receiver even when exact alarm permission is granted. Notifications are re-armed on every refresh and skipped for entries with per-show alerts disabled.

**Episode window guard** — when an episode airs, AniList immediately advances `nextAiringEpisode` to the following week. Opening the app during the 2-hour upload window (e.g. 5 minutes after broadcast) would normally cause the notification to jump to next week's episode. Instead, the app holds the current episode's airing time until the +2 h window has closed, then fetches the next episode's schedule on the following refresh. For entries added mid-window, a reverse-calculation checks whether the previous episode's upload window (next airing − 7 days + 2 hours) falls within the next 2 hours — if so, the previous episode just aired and the notification fires at the right time. Shows with non-weekly gaps (e.g. a 34-day break) are unaffected because their calculated previous window lands days in the future, not within the 2-hour threshold.

### AniList Lookup

Cover art, the display name, and the airing schedule are fetched from AniList by searching the anime title. **For anime with multiple seasons, auto-detection may resolve to the wrong season** (typically the first, most popular one) — which means no airing schedule and no notification.

To fix this, open the entry's edit screen (⋮ → Edit). The **"Resolved:"** line below the AniList ID field shows which entry was matched. If it's wrong, use the **Search by title** field — it queries AniList live and shows up to 8 results with year and airing status so you can pick the exact season. Selecting a result fills the AniList ID automatically.

The next refresh will fetch the correct season's schedule and wire up the notification.

---

## Notes

- nyaa RSS doesn't include magnet links — they're constructed from `<nyaa:infoHash>` plus public trackers
- Episode-1 detection in the add flow is heuristic; all distinct group/quality combos found are offered, preferring an episode-1 sample
- AniList lookup is best-effort and never blocks a refresh
