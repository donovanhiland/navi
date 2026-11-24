# Navi for iPhone: TestFlight

Paste these into App Store Connect → Navi → TestFlight. Internal testers (people
on the team) need none of the review fields; external testers need all of them.

## Test information

**Beta app description**

Navi is talk to type for iPhone. Keep Apple's keyboard for typing; when you
want to talk, tap the globe key and the Navi pad opens already listening. Your
words show as you speak. Tap Done and Navi removes filler words, fixes
capitals and punctuation, and types the text where your cursor is. Speech
recognition (Parakeet, about 500 MB, downloaded once) and cleanup run on the
iPhone. Nothing is sent to a server.

**Feedback email:** the team's support address (set in App Store Connect).

**Marketing URL:** https://github.com/donovanhiland/navi

**Privacy policy URL:** https://github.com/donovanhiland/navi/blob/main/docs/privacy.md

## What to test (build notes)

First TestFlight build of Navi for iPhone.

1. Open Navi. Allow the microphone, then tap Download for the speech model and
   keep Navi open until it says Parakeet is ready (Apple speech works until then).
2. Settings → General → Keyboard → Keyboards → Add New Keyboard → Navi, then
   tap Navi and turn on Allow Full Access.
3. In any app, tap a text field, then tap the globe key (or hold it and pick
   Navi). The first time, the pad opens Navi to turn the mic on; swipe back.
4. Talk, then tap Done. Check the live words, the cleanup (struck filler, fixed
   capitals), and that the text lands at the cursor and Apple's keyboard comes
   back.
5. Leave it for a while and come back: the mic stays ready for 15 minutes
   after the last use, then turns off.

Please report: words that came out wrong, cleanup that changed what you meant,
apps where the Navi keyboard does not show, and anything slow.

## Beta App Review (external testers only)

- **Sign-in required:** no.
- **Review notes:** Navi is a custom keyboard that only holds a mic button. A
  keyboard extension cannot record audio, so the Navi app records while its
  mic session is on (background audio mode, 15 minutes, the orange mic
  indicator shows) and passes the text to the keyboard through an App Group.
  Allow Full Access is needed for that App Group link. To try it: open Navi,
  allow the microphone, add the Navi keyboard in Settings with Full Access,
  then tap the globe key in Notes and talk.
- **Contact:** the team's App Store Connect contact.

## App privacy (App Store Connect → App Privacy)

Data Not Collected. Audio and text stay on the device; Navi has no servers,
accounts, analytics, or ads.

## Export compliance

Answered in the build: `ITSAppUsesNonExemptEncryption` is `NO`.

## Media

`screenshots/` holds five 1320 × 2868 screenshots (6.9" iPhone) and
`preview/navi-preview-886x1920.mp4` an 18 s app preview (30 fps, silent
AAC track). TestFlight does not use them; they are ready for the App Store page.
`scripts/appstore-media.sh` rebuilds both from Simulator captures.
