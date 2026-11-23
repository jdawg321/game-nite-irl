# Organizer tools inside the iPhone app

**Date:** 2026-11-23
**Decision:** Organizer tools move into the iPhone app now instead of a web dashboard. Jordan is the only organizer during testing.

## Why this is simpler
- **One sign-in:** you sign in with Apple in the app, and I mark that account as an organizer. No emailed links or custom email sender.
- **No Vercel:** the dashboard doesn't need hosting. The privacy policy still needs a public web address before public testing (Stage 4), but that can be one static page.
- **Same rules everywhere:** the server's existing functions and security rules already check who is an organizer. Nothing in the database changes.

## What organizers get
An **Organize** tab that only organizer accounts see. Players never see it.
1. **Games list:** your games with status and join code. A **New game** button.
2. **New game:** title, scheduled or instant, start time, location, and every rule from PRD §5, including the two pilot scoring settings.
3. **Game screen:**
   - The state strip: DRAFT → LOBBY → PREPARING → ACTIVE ⇄ PAUSED → FINISHED / TERMINATED.
   - Join code, plus a QR code you can show on your phone at the start point.
   - The main action for the current state (Open lobby / Start game) as a white call-to-action button.
   - Terminate, which asks for a reason.
   - **Players:** live roster with ready dots and volunteers. Make someone a hider (manual mode), or remove someone (asks for a reason).
   - **Rules:** editable until the game starts, then locked and shown with their version number.
   - **Log:** the audit log.
4. Stage 2 adds the live map, find review and pause controls to this screen. Stage 3 adds the safety alerts.

## Open choice
Three layouts are mocked up for comparison (see the artifact). Pick one before I build.

## What happens to the web dashboard
- Its files are removed from the repo, apart from `legal/privacy.html`.
- That page gets hosted later for the App Store's privacy policy link.
