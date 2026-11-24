# Game Nite

Real-world group games, starting with Sardines. Native iPhone app + Supabase backend + a temporary web dashboard for organizers.

| Folder | What's in it |
|---|---|
| `ios/` | SwiftUI app (`GameNite.xcodeproj`), bundle ID `com.jordanfitts.GameNite`, iOS 18+ |
| `supabase/migrations/` | Database schema, row-level security and game functions (apply in order) |
| `supabase/tests/` | `full_game_test.sql`: plays a whole game with fake users inside a rolled-back transaction |
| `web-legal/` | Privacy policy page (needs a public URL before public TestFlight) |
| `docs/` | Product requirements, TestFlight plan, the clickable HTML prototype |

## Setup
Supabase project: `bfilcrkwmkvrdnrbllbd` ("Game Nite IRL", Home OS organization, ca-central-1). It also holds an older, empty Home OS schema (people, chores, point_ledger, …); Game Nite's migration leaves those objects untouched.

1. Apply `supabase/migrations/*.sql` to the Supabase project.
2. Put the project URL and publishable key in `ios/GameNite/Data/Config.swift`.
3. Supabase dashboard → Authentication → Providers → **Apple**: enable, add `com.jordanfitts.GameNite` to Client IDs.
   (Email-code sign-in is built but switched off — `AppConfig.emailSignInEnabled` — until a custom SMTP sender exists.)
4. Mark organizers: `update profiles set is_organizer = true where id = '<user id>';`
5. Open `ios/GameNite.xcodeproj` in Xcode and run.

## How the server stays in charge
Clients can read what row-level security allows but can't write game tables. Every change (join, ready, open lobby, start, pause, location reports, finds, remove, terminate) is a `security definer` database function that checks who's calling and the game's state, and writes an audit log entry for organizer actions.

Positions live in tables clients can't read at all. Players only get what `visible_positions()` and `my_clue()` compute for their role, and nothing while a game is paused or over. Roles are private (`game_roles`): you see your own; organizers see everyone's unless they're playing that game.

## Tests
- App: `xcodebuild test -project ios/GameNite.xcodeproj -scheme GameNite -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- Database: run `supabase/tests/full_game_test.sql` in the SQL editor; every row should say PASS.
- Simulator UI without a server: launch with `-demoOrganizer` (Debug builds only).

## Stages
See `docs/TESTFLIGHT_PLAN.md`.
- Stage 1: sign-in, profiles, events, join by code/QR, live lobby.
- Organizer tools in the app (Organize tab), private roles.
- Stage 2: GPS sampling (foreground + background), live map by role, timeline, clues, finds, review queue, pause/emergency pause, results. Profile → GPS test.
- Stage 4 groundwork: in-app account deletion, reviewer sign-in, App Store Connect drafts (`docs/APP_STORE_CONNECT.md`).
- Not yet: Stage 3 safety alerts/incident reports/push notifications/replay viewer.
