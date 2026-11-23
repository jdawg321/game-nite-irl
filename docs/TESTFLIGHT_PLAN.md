# IRL Games — TestFlight Plan

**Date:** 2026-11-23
**Goal:** A native iPhone app that real people can install from a public TestFlight link and use to play Sardines together on real phones.

## Decisions
- **Scope:** Real multiplayer. A native SwiftUI app with a Supabase backend: real sign-in, real GPS and live games shared across phones.
- **Testers:** Public TestFlight link. Every build sent to outside testers goes through Apple's Beta App Review, which usually takes about a day.
- **Organizer tools:** A separate web dashboard for now, while the rules are being fine-tuned. They move into the app later.
- **Sign-in:** Sign in with Apple, plus a one-time code by email as the backup.
- **Look:** The prototype's design: 60% dark charcoal, 30% neon blue accents, 10% white call-to-action buttons. The prototype's animated neon gradients and the GAME NIGHTS title carry over.

## How it fits together
| Piece | Technology | Where it lives |
|---|---|---|
| iPhone app | SwiftUI, MapKit, Core Location, supabase-swift | `ios/` |
| Backend | Supabase: Postgres with row-level security, database functions, Realtime, Edge Functions, scheduled jobs | `supabase/` |
| Organizer dashboard | A plain HTML and JavaScript site using supabase-js. It needs no build step, so Node isn't required. Hosted on Vercel. | `dashboard/` |
| Privacy policy and support pages | Static pages, hosted on the same Vercel site | `dashboard/legal/` |

- **One repo:** All of this goes in one GitHub repo, `irl-games`, kept at `~/Developer/IRL-Games`. It stays out of iCloud Drive, as with CA.
- **The server decides game outcomes.** Phones only send location samples and requests. Database functions handle:
  - every state change
  - find checks
  - timers
  - rankings
- **Location rules are enforced in the database.** Row-level security decides which positions each player can see, based on their role and the game state, so the rules hold no matter what the app does.

## Build stages
Each stage ends with a push to GitHub and a TestFlight build.

**Stage 1: Foundations.** You get an internal TestFlight build.
- Repo, Supabase project, and the schema with security rules for users, events, games, players and the audit log.
- App setup with the charcoal and neon theme, app icon and launch screen.
- Sign in with Apple and email code sign-in. Profile setup: display name, 18+ confirmation, rules agreement and replay consent.
- Event list with the GAME NIGHTS title. Join by code or by scanning a QR code with the camera.
- A live lobby whose roster updates in real time.
- Dashboard: organizer sign-in, create an event, open the lobby, see the roster, start the game.

**Stage 2: The live game**
- Location sampling every 20–30 seconds, including in the background during a game. Every sample records its accuracy, and stale or inaccurate fixes are flagged.
- A server timeline: PREPARING, then the head start, then ACTIVE, then FINISHED when time runs out or every seeker has been found.
- A map that shows each player only what their role is allowed to see. Clues come from the reveal mode.
- Find flow: a seeker taps "I found them", the server checks a fresh GPS fix, and a hider confirms. Finds that don't pass go to the dashboard's review queue, where approving one requires a reason.
- Final standings with tie handling. Both scoring rules from the prototype stay as organizer settings.

**Stage 3: Safety and notifications**
- Emergency pause and terminate from the dashboard. Pausing or ending a game hides every player's location immediately.
- Alerts for GPS loss and for players out of bounds. Incident reports from the app.
- Push notifications for: lobby open, game starting, head start over, you were found, find needs confirmation, game paused, game ended.
- Replays for opted-in players only. A scheduled job deletes them after 7 days.
- Audit log of organizer actions.

**Stage 4: Public TestFlight**
- Account deletion inside the app. Apple requires this for any app that creates accounts.
- Privacy policy and support pages.
- Accurate location-permission text in the app.
- A demo account for Apple's reviewers, who can't receive your sign-in emails. It uses a hidden email-and-password sign-in that works only for that one account.
- App Store Connect setup: the beta app description, a feedback email, and the "Test Information" notes explaining how to try a game alone.
- Submit to Beta App Review, then turn on the public link.

## What you need to do
**Before Stage 1 starts**
1. **GitHub:** create an empty private repo named `irl-games` under `jdawg321`, with no README. The GitHub CLI isn't installed, so this is the quickest way. Alternatively, I can install the CLI.
2. **Supabase:** approve creating a new project on the free plan. I create it through the connector, which asks you to confirm the cost first.
3. **App name and bundle ID:** confirm or change these defaults:
   - name: "IRL Games"
   - bundle ID: `com.jordanfitts.IRLGames`

   The App Store name has to be unique, so have a backup ready, such as "IRL Games: Sardines".

**During Stage 1**

4. **App Store Connect:** create the app record. Choose New App, iOS, your name, the bundle ID above, and a SKU like `irlgames`. Xcode registers the bundle ID and turns on Sign in with Apple through automatic signing on your team (J5P52CF935).
5. **Email codes:** Supabase's built-in email only sends a few messages an hour. Connect Resend as custom email sending, or another sender. Resend is the same service as the ENVI site, but it needs a domain you control.
6. **Vercel:** approve creating a project for the dashboard, connected to the repo.

**Before Stage 3**

7. **Push notifications:** in the Apple Developer portal, create an APNs key (.p8) and add it to Supabase as a secret. I'll walk you through it.

**Before Stage 4**

8. **Public testing details:** a support email and a feedback email.
9. **App Store Connect forms:** confirm the age rating answers (18+ only) and fill in the privacy "nutrition label." I'll draft the answers.

## Out of scope for TestFlight
- Organizer tools inside the app. They come later, after the rules settle.
- Ticketed events and payments (V2).
- Android.
- Google sign-in and phone-number sign-in.

## Risks
- **Background location:** this is the biggest unknown. Apple checks closely how apps use location in the background. The app only tracks location during an active game, shows the system's location indicator while it does, and explains why in the permission text. Stage 2 includes a real-world battery and accuracy test before anything goes to outside testers.
- **Beta App Review** can reject a build for missing account deletion, a missing demo account or vague location wording. Stage 4 covers all three.
