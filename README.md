# Game Nite

Real-world group games, starting with Sardines. Native iPhone app + Supabase backend + a temporary web dashboard for organizers.

| Folder | What's in it |
|---|---|
| `ios/` | SwiftUI app (`GameNite.xcodeproj`), bundle ID `com.jordanfitts.GameNite`, iOS 18+ |
| `supabase/migrations/` | Database schema, row-level security and game functions |
| `dashboard/` | Organizer dashboard: plain HTML + JS (supabase-js from a CDN), no build step. Also hosts `legal/privacy.html`. |
| `docs/` | Product requirements, TestFlight plan, the clickable HTML prototype |

## Setup
1. Apply `supabase/migrations/*.sql` to the Supabase project.
2. Put the project URL and publishable key in `ios/GameNite/Data/Config.swift` and `dashboard/config.js`.
3. Supabase dashboard → Authentication:
   - **Providers → Apple:** enable, add `com.jordanfitts.GameNite` to Client IDs.
   - **Email templates → Magic Link:** include `{{ .Token }}` so emails carry a 6-digit code.
   - **SMTP:** connect a custom sender (built-in email is rate-limited to a few per hour).
4. Mark organizers: `update profiles set is_organizer = true where id = '<user id>';`
5. Open `ios/GameNite.xcodeproj` in Xcode and run.

## How the server stays in charge
Clients can read what row-level security allows but can't write game tables. Every change (join, ready, open lobby, start, remove, terminate) is a `security definer` database function that checks who's calling and the game's state, and writes an audit log entry for organizer actions.

## Stages
See `docs/TESTFLIGHT_PLAN.md`. Stage 1 (this commit): sign-in, profiles, events, join by code/QR, live lobby, organizer dashboard.
