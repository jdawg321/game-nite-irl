# Game Nite: App Store Connect answers (drafts)

These are draft answers to paste into App Store Connect. Anything in [brackets] needs your input first.

## App record (My Apps → +)
| Field | Answer |
|---|---|
| Platform | iOS |
| Name | Game Nite (if taken: Game Nite IRL) |
| Primary language | English (U.S.) |
| Bundle ID | com.jordanfitts.GameNite (registered, with Sign in with Apple) |
| SKU | gamenite |
| Primary category | Games › Adventure |
| Secondary category | Social Networking |

## TestFlight › Test Information
**Beta App Description** (outside testers see this):
> Game Nite runs real-world group games around your city, starting with Sardines. One player hides, and everyone else searches. When a seeker finds the hiding spot, they quietly join it, until the last seeker finds the packed group. The app handles roles, timers, clues and find checks, so the organizer can focus on running a safe, fun night. You must be 18 or older.

**What to Test** (update for each build):
> Build 0.1.x: sign in with Apple, set up your profile, join a game with a code or QR, and wait in the lobby. Organizers: create a game, set the start point, open the lobby and start. During a game, check that the timer, the map, the clue, and "I found them" all work, and that hiders get the confirmation prompt. Please report anything confusing, and anything about location accuracy or battery.

**Feedback email:** [your feedback email]

**Marketing URL:** leave blank. **Privacy Policy URL:** [public URL of web-legal/privacy.html; see Open items]

## Beta App Review Information
**Contact:** [first name, last name, phone, email]

**Sign-in required:** Yes.
- Username: [reviewer account email, e.g. review@your-domain]
- Password: [create a strong password; see Open items]

**Review Notes:**
> Game Nite is a real-world group game (Sardines) played outdoors by adults (18+). Players sign in with Apple. Because reviewers can't always use Sign in with Apple on review devices, we provide a password demo account. On the sign-in screen, tap the line "Game Nite is for players 18 and older" five times to show Reviewer sign-in, then use the credentials above.
>
> The demo account is an organizer. To try it, open the Organize tab and tap New game, then Create. Set "Use my location as the start point", then Open lobby, then Join as player. A real game needs at least two players on separate phones, so a second demo account is provided in the next note [optional second account email/password]. Profile → GPS test shows how location sampling works without starting a game.
>
> Location: during an active game only, the app samples location about every 25 seconds, including in the background, to verify finds, warn players who leave the game area, and rank players. The system location indicator is shown while it runs, and tracking stops when the game ends, is paused, or is terminated. Location is never collected outside a game.
>
> Accounts can be deleted at any time from Profile → Delete account.

## Background location (UIBackgroundModes: location)
If Apple asks why the app uses background location:
> Sardines is played with the phone in a pocket. Seekers walk the game area while hiders stay hidden, often with the screen off. The server needs a location sample about every 25 seconds to check that a find is real (the seeker is within the find radius of the hiding group), warn players who wander out of the game area, and rank seekers who don't finish. Background updates only start when the player is in a game that has begun, show the blue location indicator, and stop when the game ends.

## Export compliance
- The app uses only standard HTTPS encryption.
- `ITSAppUsesNonExemptEncryption` is already set to NO in the app, so builds skip the export compliance question.

## Age rating
Answer **None** to every content question: no violence, mature themes, gambling, unrestricted web access or user-generated content beyond display names. Then use **Override to Higher Age Rating** and choose **18+**, because events are adults-only for safety.

## App Privacy ("nutrition label")
Tracking: **No.** The app doesn't track users across other companies' apps or websites.

| Data type | Collected | Linked to user | Purpose |
|---|---|---|---|
| Precise Location | Yes | Yes | App Functionality |
| Email Address | Yes (from Sign in with Apple; may be a private relay address) | Yes | App Functionality (account) |
| User ID | Yes | Yes | App Functionality |
| Other User Content (display name, incident reports) | Yes | Yes | App Functionality |
| Gameplay Content (roles, finds, results) | Yes | Yes | App Functionality |

Not collected: contacts, photos, health, financial info, browsing history, diagnostics, advertising data.

## Open items (need you)
1. **Privacy policy hosting.** App Store Connect needs a public URL for the privacy policy. The app currently links to GitHub Pages (`https://jdawg321.github.io/game-nite-irl/privacy.html`). That only works if the repo is public, or on a paid GitHub plan. Alternatives: a one-page Vercel site, or any domain you own. Tell me which, and I'll set it up and update the link in the app.
2. **Support and feedback email.** Put it in the policy and in TestFlight.
3. **Reviewer account.** Once Supabase is back:
   - I create a password user and mark it as an organizer.
   - You pick the password and paste it into App Store Connect only. Don't put it in the repo.
   - A second reviewer account is optional.
4. **Name check.** If "Game Nite" is taken in App Store Connect, try "Game Nite IRL".
