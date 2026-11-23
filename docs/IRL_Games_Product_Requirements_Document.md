# IRL Games — Product Requirements Document

**Status:** Product requirements consolidated; technical implementation requires validation  
**Version:** 1.0 (draft for engineering)  
**Date:** 2026-11-13  
**Product owner / developer:** Jordan (app development); Lucas (gameplay specification and UI input)  
**Initial launch goal:** January 24, 2027 (target, not a guarantee; this date is a Sunday, while recurring Friday games are a separate event concept)  
**Initial geography:** Provo, Utah  
**Scope:** Version 1 Sardines experience, supporting up to 50 simultaneous players in a game  

## 1. Product vision

IRL Games is an **events-first social gaming platform**. The actual product experience is organized real-world game nights; the software enables discovery, joining, coordination, gameplay, safety, and results. Its initial game mode is Sardines, with an extensible game engine to allow other real-life games later.

The original conversation envisioned recurring free Friday game nights, possible food trucks and local businesses, paid Saturday individual competitions with first-, second-, and third-place prizes, and larger premium events. Those are business/event directions, not all V1 software commitments.

### Initial operating goals
- First public event: approximately 50 attendees.
- One reliable Sardines game with up to **50 concurrent active players**.
- Only officially authorized IRL Games organizers can host games in V1.
- Design for future games and more players without promising those capabilities in V1.

## 2. Scope boundaries

### Version 1 — required
1. Shared-codebase mobile gameplay for iOS and Android, with native capabilities needed for background location.
2. Organizer functionality in both mobile app and web dashboard.
3. Scheduled and instant events, discoverable in an event browser or accessible via game code / QR link.
4. Lightweight account onboarding: quick sign-in, display name, rules acknowledgment, then join. Authentication methods envisioned: Apple, Google, or phone; final provider support needs technical/platform validation.
5. Basic profiles (name/avatar, games joined, basic statistics).
6. No separate physical event check-in requirement.
7. Official-organizer role enforcement and event/game administration.
8. Configurable Sardines rules and GPS modes, with settings locked once active play begins.
9. Real-time authoritative game-state management, 50-player target, and reconnection grace behavior.
10. Background location tracking during active gameplay; role-based player visibility according to pregame rules; no player-to-player location visibility while paused or ended.
11. GPS-assisted find verification with confirmation by **any verified member of the hiding group**, plus organizer review/override when needed.
12. Player results, individual ranking, and tie handling.
13. Safety controls: out-of-bounds warnings, GPS-loss alerts, incident reporting, emergency pause and emergency termination. Manual organizer controls remain available during a safety incident.
14. Opt-in location replay recording for consenting players only; organizer-only replay access; seven-day replay retention.
15. Gameplay notifications (countdowns, clues, found confirmations, results). Emergency safety communications must remain possible independently of ordinary gameplay notification preferences.
16. Pilots staged at approximately 5, 15, 30, and 50 concurrent participants; reliability thresholds calibrated from pilot measurements.

### Version 2 — planned, not required for launch
- In-app/event ticket sales and paid attendance management.
- Automatic prize payouts, subject to contest eligibility, legal review, and payment provider support.
- Paid Saturday competitions and corresponding operational payment flows.

### Future possibilities — not committed to V1 or V2
- Fugitive, Manhunt, hide-and-seek variants, IRL Among Us, and other game modes.
- Regular-user private hosting and richer social features (friends, leaderboards, achievements).
- More sophisticated vendor, food-truck, and business-partner integrations.
- NFC or laser-tag hardware features and larger capacity tiers.

## 3. User roles and access

| Role | Can do | Restrictions |
|---|---|---|
| Visitor | Browse discoverable event information | Must sign in to participate |
| Authenticated player (18+) | Join eligible event/game, receive rules/clues, share live location during gameplay, request find verification, view own results | Cannot host public games, edit server state, or view organizer-only replays |
| Organizer (authorized staff) | Create scheduled/instant games; configure pregame rules; manage players; start/pause/resume/end; send gameplay messages; review incidents/disputes and opt-in replays | Cannot change gameplay rules during active play; must follow access audit controls |
| System/server | Enforce permissions, game state, location visibility, verification, ranking, replay expiry | Must not trust clients as authoritative source of results |

**Decision:** Only official organizers host in Version 1. **Engineering recommendation:** Support distinct account roles and event-scoped permissions, enforce them server-side, and log privileged changes.

## 4. Player journey

1. Browse scheduled public events without needing to complete a profile (whether browsing requires sign-in is not a blocking decision; user chose quick sign-in before joining).
2. Select event in-app or open a direct game code / QR link.
3. Sign in quickly via a supported method, provide a display name, confirm age eligibility (18+), and accept event/game rules.
4. Join lobby without mandatory physical check-in.
5. View lobby, countdown, role assignment, permissions status, and boundary/rule information.
6. Participate in Sardines: receive role-appropriate map/location information and clues; seek or hide; complete verified find interactions.
7. Receive active-state notifications and safety instructions.
8. View end-of-game standings and basic profile statistics.

**Open implementation detail:** Final authentication provider combinations and platform-specific app-store requirements.

## 5. Organizer journey and controls

### Before activation
- Create a scheduled event or instant game.
- Select Sardines and configure rules using supported controls:
  - Number of initial hiders (customizable).
  - Hider selection method: manual, random, or volunteer with organizer approval.
  - Hider head start: on/off and configurable duration.
  - Game start method: organizer-selectable (e.g., manual, scheduled, or ready-state); exact supported modes documented in UI.
  - Game duration/end behavior: all seekers joining the hiding group **or** the timer expiring, whichever occurs first.
  - GPS presentation/reveal modes: continuous, periodic, approximate proximity clues; role-specific visibility and configurable supported thresholds.
  - Find verification method: configurable in the platform, with V1 verified GPS proximity plus hider confirmation and organizer override as the defined Sardines flow.
  - Boundary and player-capacity settings.
- Open the lobby, publish a joining code/QR link, and manage participants.

### During activation
- Start, pause, resume, and end a game.
- Manage problematic or disconnected players, review disputed finds, send announcements and safety notices.
- **Rule configuration is immutable while a game is active.** Safety commands and necessary player-management operations remain permitted and auditable.
- Provide both emergency pause and emergency termination; immediately stop sharing other players' locations on emergency pause/stop.

### After completion
- Publish results and standings, access eligible replay information, and review incident information.

## 6. Game-state model (proposed technical structure)

`DRAFT -> LOBBY -> PREPARING -> ACTIVE <-> PAUSED -> FINISHED`

Emergency pause is a priority transition from active play. Emergency termination transitions to `TERMINATED`, disables player-to-player sharing, and cannot automatically resume without a new explicit organizer action or new game. Technical design must define which states permit normal resume and how paused game clocks behave.

### Invariants
- No location visibility to other players unless the game is `ACTIVE` and the role/visibility rules authorize it.
- No player may move into the hiding group without a verified find or documented organizer override.
- One authoritative server-controlled clock and event sequence for find order and game results.
- Rule settings are versioned and locked when active play starts.
- Reconnecting clients must receive an authoritative state snapshot rather than replaying their own assumed transitions.

## 7. Sardines mechanics and results

1. Organizer selects initial hider count and the selection method.
2. Optional configurable hider head start.
3. Remaining participants are seekers.
4. On a find attempt, system evaluates a recent, accurate-enough GPS proximity observation against the organizer-selected supported threshold.
5. Any verified member of the current hiding group can confirm the find.
6. If location evidence is inaccurate or a find is disputed, organizer manually reviews and may override with an audited reason.
7. Once verified, the seeker joins the hiding group.
8. Game ends as soon as all eligible seekers have joined or timer expires.
9. **Completed seekers:** rank by verified finding order, earliest first.
10. **Unfinished seekers:** rank below completed seekers by their **closest valid recorded distance** to the hiding group during the game; where distances are indistinguishable, the earliest timestamp at which the closest valid distance was attained breaks the tie; if still unresolved, award a **shared placement**.

### Unresolved engineering parameters (not product questions)
- Supported minimum/maximum GPS proximity thresholds, GPS accuracy filtering, freshness limits, and confidence/tie tolerance.
- Exact time-source semantics (prefer server timestamps) and how to handle delayed/offline find events.
- How to calculate distance to a multi-person hiding group, especially after found seekers join and the group grows (use a documented immutable reference or role-based calculation; do not invent a rule silently).
- Whether earliest valid records based on nonconsenting player's location can be temporarily held for scoring without creating replay trails; enforce data minimization and consent boundary.
- Handling volunteer/initial hider rankings and no-finder outcomes; specify before implementing leaderboard prizes.

## 8. Location pipeline and visibility

### Confirmed behavior
- Location acquisition must continue in the background during active play, including while screen is locked or another app is foregrounded, to the extent permitted by OS/permissions.
- Initial location collection cadence: approximately **20–30 seconds**, distinct from how often information is revealed to other players.
- Organizer configures continuous, periodic, and proximity-based reveal modes and role visibility before the game.
- Player-to-player sharing occurs **only during active play**. Pausing, finishing, or emergency stopping suppresses it immediately.
- Location permission was requested as **always** for gameplay; actual iOS/Android permission prompts should be staged and limited to the minimum allowed and needed, with clear disclosure, denial states, and recoverable failure behavior.
- Grace period after location or connectivity loss; mark location observations stale and avoid treating stale coordinates as proof of proximity.

### Technical recommendations
- Separate raw location collection, server-side validation, game-state processing, and player-visible transforms.
- Server determines permitted visibility based on game/role/state; client never receives coordinates it is not allowed to display.
- Account for GPS drift, spoofing, poor downtown signal, battery saver, device sleep, and background permission revocation.
- Monitor update latency, age/accuracy, battery use, connection drop rate, find-verification failure rate.
- Do not promise truly uninterrupted background GPS: mobile operating systems can throttle or terminate collection.

## 9. Privacy, replay consent, and retention

- Age eligibility: 18+ in initial release.
- Player chooses whether historical movement is included in full game replay recording; **opt-out does not block participation**.
- Players opting out are **entirely excluded from replay movement history**, not merely anonymized.
- Only authorized organizers may view consenting players' recorded replay tracks.
- Replay movement history deleted after **7 days**.
- Live location is transient and retained only for necessary gameplay processing; player-facing location sharing stops whenever game not active.
- Persistent records may include outcome, participation, and **non-location** statistics.
- Technical design must prevent replay opt-outs from being circumvented via event logs, third-party telemetry, exports, and backups; define backup deletion lifecycle and access auditing.
- Secure transport and storage, privacy notice, ability to revoke consent, data-access/deletion request pathway, and security incident procedures must be defined before production launch.

**Tradeoff to explicitly document:** Without retaining location histories for opted-out players, any score requiring their **closest recorded distance during the entire game** must be derived and maintained as a minimal, non-replay scoring aggregate during play, rather than storing a recoverable movement trail.

## 10. Safety and incident handling

### V1 required
- Show event rules and safety acknowledgment before play.
- Geofence/out-of-bounds alerts.
- Alerts to players/organizers about loss of GPS or connectivity.
- In-app incident reporting and organizer review.
- Emergency **pause** and **terminate** actions; notify affected players and shut off player-to-player location sharing.
- Graceful reconnect experience with stale-location treatment.

### Operational dependencies, not built-in app requirements
- Confirm downtown Provo access/event permission and an approved start/boundary location.
- Define walking versus running rules, street crossings, business/private property entry, and no physical confrontations or weapon-like props for first event.
- Establish an organizer staffing/emergency response plan and ensure that automated safety functions are not represented as a substitute for human oversight.

## 11. Notifications

**Confirmed V1 preference:** Gameplay notifications, including countdowns, clue releases, find confirmations, and game results. Safety messages are required for operational safety. Promotional campaigns and generalized marketing pushes are not committed to V1.

Delivery details (push, in-app, fallbacks for permissions disabled) to be specified technically.

## 12. Proposed logical data entities

The following is a **suggested schema outline, not a confirmed database design**:

- `users`: id, account provider ids, age eligibility status, display name, avatar, account status.
- `roles`, `organizer_memberships`: authorized staff and scoped privileges.
- `events`: id, type scheduled/instant, title, description, visibility, schedule, location, status.
- `game_sessions`: event id, game mode/version, locked configuration snapshot, state, clock, organizer id.
- `game_participants`: user id, session id, role, joined/active/found/left state.
- `game_invitations`: human-friendly code, QR token, expiry, redemption restrictions.
- `game_events`: server timestamped transitions, find requests/confirms, controls, incident linkage; **never use this as an undisclosed raw movement replay store**.
- `live_positions`: short-lived encrypted state with per-position freshness and reported accuracy.
- `replay_consents`: session-scoped opt-in status and change records.
- `replay_positions`: only consenting participants, expiring at 7 days.
- `find_verifications`: requester, verifier, state, proximity-quality metadata, audit override.
- `results`: standings, outcomes, rank, tie groups, non-location statistics, closest-distance **aggregate** for active ranking where appropriate.
- `incidents`, `organizer_audit`: safety and privilege-control records.

Server-side security policies must block regular players from reading privileged raw GPS and replay data. Final entity fields/relations depend on selected backend.

## 13. Suggested API / event contracts

Not a technology commitment. Define versioned events or endpoints for:

- Authentication and profile setup.
- Browse, create, update, register/join events.
- Issue/redeem game codes and QR joins.
- Create/configure/open/prepare/start/pause/resume/end/terminate games.
- Submit location observations with timestamp, accuracy, and permission state.
- Subscribe to sanitized, role-permitted game state and GPS reveals.
- Request/confirm/dispute/override a find.
- Send safety or gameplay notifications.
- Fetch standings and session results.
- Give/revoke replay consent; view replay only as authorized organizer; enforce expiry.
- Create/manage incident reports.

Include idempotency keys, event sequence numbers, server timestamps, authorization checks, and connection recovery semantics.

## 14. Acceptance criteria for V1

### Functional
- A verified official organizer can create a scheduled event and instant Sardines game, configure supported rules, and generate an event page and join code/QR.
- An eligible adult can quick-sign-in, acknowledge rules, join a game, and view assigned role without physical check-in.
- Organizer can choose hiders, start mode, head start, GPS visibility/reveal modes, supported proximity thresholds, and countdown/end conditions before activation.
- Gameplay rules cannot be changed while game active; organizer can still pause, resume, manage participants, and terminate for safety.
- Players only receive the other-player location information authorized by their role and active game state.
- Background location updates are attempted while authorized; permission denial/loss is handled explicitly without silently fabricating coordinates.
- GPS-assisted find requests require a proximity quality check and confirmation by an eligible hiding-group member, or an audited manual organizer resolution.
- Verified finds add seekers to hiding group and affect server-authoritative ranks.
- Game finishes when everyone found or time expires, displays correct ordered/shared standings.
- A disconnected player can recover within a defined grace policy without corrupting game results.
- Emergency pause/termination ends player-to-player GPS visibility and informs participants.
- Replay opt-out players leave no recoverable movement trail; opted-in tracks are organizer-only and automatically expire after seven days.
- Safety boundary warnings, GPS-loss notices, and incident reporting function during testing.

### Nonfunctional and performance
- Final numerical latency, GPS freshness/accuracy and reconnection thresholds are **TBD by pilot measurement** rather than assumed.
- Test at **5, 15, 30 and 50 concurrent players**, including different phones and weak network/GPS conditions.
- No critical server-game-state errors (lost role changes, inconsistent find order, duplicate finds, leaked location data, incorrect game state) in final 50-player pilot.
- Record measurable load, location freshness, battery impact, incident response, permission failures, and find disputes. Establish release go/no-go gates using these measurements.
- Privacy/access-control tests and replay expiry/deletion verification must pass before public launch.

## 15. Pilot/test matrix

| Stage | Target | Primary validation |
|---|---:|---|
| Prototype | 5 players | Complete game loop, organizer controls, role/GPS permissions |
| Small pilot | 15 players | Location performance, find verification, reconnect, rule lock |
| Medium pilot | 30 players | Simultaneous state updates, GPS reveal correctness, alerts |
| Launch-scale pilot | 50 players | Full-duration reliability, safety response, privacy, load, results |

At each stage, explicitly test iOS and Android, background/locked-phone behavior, revoked permissions, GPS drift, duplicate confirmation, network dropout, emergency pause/terminate, tie handling, and consent/retention enforcement.

## 16. Architecture options and selection criteria

**Confirmed:** Hybrid/mobile client plus web and mobile organizer experiences; backend choice remains open.

**Recommended candidate architecture (uncommitted):** React Native/Expo for cross-platform mobile, responsive web dashboard (e.g., Next.js), and a centralized server-authoritative backend with a relational data model, realtime event delivery, secure access control, short-lived live positions, and separate replay storage. Supabase and Firebase are candidate providers, **not** a settled choice. Compare them through a prototype using:

1. Reliable, affordable 50-player state synchronization.
2. Fine-grained server-controlled GPS authorization and history separation.
3. Low latency find confirmation and auditability.
4. Easy deletion of time-limited replays.
5. Authentication and organizer privileges.
6. Deployment, operational complexity and expected per-event cost.
7. Native background location and push behavior on target OS versions.

Payments and payouts will require separate V2 design and compliance review.

## 17. Major risks and dependencies

- **Platform limits:** Background GPS is not guaranteed even in native apps; app review and permission expectations may shape onboarding.
- **Privacy:** Historical geolocation is sensitive; opt-in consent, limited access, deletion, security and handling of nonconsenting score aggregates require deliberate design.
- **Gameplay fairness:** GPS drift can distort proximity and closest-distance ranks; confirmation and organizer overrides are necessary.
- **Safety:** Downtown location-based games involve roads, businesses, bystanders, and emergency procedures; city approval and clear rules are outside the app but essential to operation.
- **Scope:** 50 simultaneous players and dual organizer interfaces expand V1 engineering effort; stage development and prioritize a robust core game loop.
- **Business:** Free Fridays, paid Saturdays, vendors, ticket pricing, cash/gift-card prizes are event/business goals; revenue and payments are not V1 software dependencies.
- **Payout legality:** Automated prize payouts are a V2 goal that requires payment and contest-law feasibility checks, identity/age verification, tax considerations, and provider rules.

## 18. Engineering backlog (suggested implementation order)

1. Create requirements traceability matrix and establish V1 acceptance tests.
2. Prototype iOS/Android background location, permission UX, and power usage.
3. Prototype live 50-player session with server-authoritative roles/state and scoped location visibility.
4. Choose backend and formalize security rules/schema.
5. Implement lightweight auth, official-organizer roles and event discovery/join.
6. Implement locked game configuration, Sardines hider selection/head start, state transitions, and role-aware map.
7. Implement verified finds, timed finish, ranking/tie logic, and organizer override audit.
8. Implement safety, incident reports, reconnection grace policy and emergency controls.
9. Implement optional replay consent, separate expiring replay storage, and deletion verification.
10. Implement both organizer interfaces, player results/basic profiles, and gameplay notifications.
11. Run staged 5/15/30/50-player pilots, calibrate numerical performance gates, and resolve blocking defects.
12. Complete operating/location permissions, store compliance, privacy documentation and release readiness.

## 19. Decision register: confirmed vs open

### Confirmed product decisions
- Events-first platform; Sardines first; 50-player initial target; official organizers only.
- Hybrid mobile app, web/mobile organizer interfaces; backend open.
- Scheduled and instant events; public discovery and join code/QR; quick login; basic profiles; no physical check-in.
- Configurable hiders, selection, head start, start mode, GPS visibility/reveal, finding verification and supported threshold; rules locked in active game.
- Background GPS during active game, initial collection at 20–30 second interval, player-to-player visibility only when active, grace reconnect.
- GPS proximity plus any hiding-group member confirmation; organizer manual review/override on inaccurate/disputed cases.
- First verified finder wins; unfinished players ranked by closest valid distance, then earliest time, then shared placement.
- Full organizer-only replays for opted-in players; opt-outs excluded; seven-day history expiry; separate temporary live and persistent non-location results.
- Boundary/GPS alerts, incidents, emergency pause and termination; gameplay alerts; staged pilots, performance thresholds measured in tests.
- Ticketing and automated payouts postponed to V2; initial players 18+.

### Engineering parameters still TBD
- Exact geospatial threshold ranges, accuracy/timestamp policies, multi-hider distance target, permission denial fallback, replay storage enforcement and backup deletion, reconnection duration, tie tolerance, supported auth provider releases, organizer audit events, game clock semantics, load/performance thresholds, and selected backend/vendors.

### Product-level detail that should be explicit in implementation notes
- How scoring treats *initial hiders*, a final seeker who finds nobody, and multiple original hiders; recommended to specify a game-specific results display instead of assuming an individual ranking rule beyond what was explicitly chosen.

---

**Source/authority note:** This document consolidates product choices confirmed in the conversation. Sections labeled *recommended*, *proposed*, *suggested*, or *TBD* are engineering proposals, not extra user decisions. It does not assert city permit approval, legal compliance, or production readiness.
