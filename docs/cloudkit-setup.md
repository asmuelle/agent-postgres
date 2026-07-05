# CloudKit Alert Relay — one-time setup & end-to-end test

Roadmap slice 1.1: the Mac app is the always-on fleet monitor and relays
alerts to iPhone/iPad through the **user's private CloudKit database**
(container `iCloud.com.pgagent.pgagent`, custom zone `FleetAlerts`, record
type `FleetAlert`). No vendor cloud; alert data never leaves the user's
Apple ID.

The code side is already wired (entitlements in `project.yml`,
`PgAgentShared/FleetAlertRelay.swift` / `FleetAlertSubscription.swift`,
`PgAgentApp/FleetMonitorHub.swift`, `PgAgentMobile/HubAlertReceiver.swift`).
What follows is the **manual, Apple-portal work** that code cannot do.

## 1. Developer portal (once per team)

For **both** bundle ids — `com.pgagent.macos` and `com.pgagent.mobile` — in
[Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list):

1. Enable the **iCloud** capability, "Include CloudKit support", and attach
   the container `iCloud.com.pgagent.pgagent` (create the container in the
   same panel the first time; container creation can take a few minutes to
   propagate).
2. Enable the **Push Notifications** capability. CloudKit subscriptions use
   Apple's push infrastructure implicitly — no APNs key/cert to manage, but
   the capability must be on the App ID.
3. Regenerate any provisioning profiles that embed these App IDs (Xcode's
   automatic signing does this on next build; manual profiles must be
   re-downloaded).

Notes:

- The **macOS app stays Developer ID + Sparkle**. CloudKit works with
  Developer ID signing, but the build must carry a provisioning profile that
  includes the iCloud entitlements (Xcode: Signing & Capabilities →
  register the Mac's provisioning through the Developer ID profile flow).
  Ad-hoc-signed local dev builds will show "iCloud unavailable" in the hub
  status line — that is expected, not a bug.
- `aps-environment` is `development` in the repo. App Store / TestFlight
  distribution rewrites it to `production` automatically at submission.

## 2. Schema (auto-created in Development, deployed manually to Production)

CloudKit's **Development** environment auto-creates schema on first save:
the first time a signed Mac build publishes an alert, the `FleetAlerts` zone
and the `FleetAlert` record type (fields: `alertId`, `instanceId`,
`instanceName`, `severity`, `kind`, `title`, `detail`, `createdAt` — all
`String` except `createdAt: Date/Time`) appear in the
[CloudKit Console](https://icloud.developer.apple.com/) under
`iCloud.com.pgagent.pgagent`.

**Before any public release**: CloudKit Console → the container →
*Deploy Schema Changes…* from Development to **Production**. Production
never auto-creates schema; skipping this bricks the relay for App Store
users.

No custom indexes are required — the subscription uses `TRUEPREDICATE` and
records are fetched by ID.

## 2b. UserData zone / opt-in sync (roadmap 2.3)

The same container hosts a second custom zone, **`UserData`**, for the
opt-in sync of connection profiles (sans secrets) and saved queries
(`PgAgentShared/CloudSyncEngine.swift`; toggles live in macOS Settings →
Sync and the iOS settings sheet). Record types, auto-created in Development
the first time a signed build syncs:

- `SyncedProfile` — record name = profile UUID. Fields: `payload` (String —
  the sanitized profile JSON; **never** contains passwords, the encoder
  refuses secret-shaped keys), `name`, `environment`, `color`,
  `sshProfileRef` (all String), `isReadOnly`, `deleted` (Int64),
  `updatedAt`, `deletedAt` (Date/Time).
- `SyncedSavedQuery` — record name = saved-query UUID. Fields: `profileId`,
  `title`, `sql` (String), `deleted` (Int64), `createdAt`, `updatedAt`,
  `deletedAt` (Date/Time).

Sync mechanics: last-writer-wins by `updatedAt`; deletions propagate as
tombstone records (`deleted = 1`, purged after 30 days); incremental pulls
use a persisted zone change token; remote changes arrive via a silent
`CKRecordZoneSubscription` (`user-data-sync-v1`). Passwords never ride in
these records — they sync exclusively through iCloud Keychain
(`kSecAttrSynchronizable`) when "Sync password via iCloud Keychain" is
enabled on a specific connection.

**The Production schema deploy (step above) now includes these two record
types as well** — re-deploy after the first Development sync, or sync is
silently broken for TestFlight/App Store users.

## 3. End-to-end test (two signed devices, one Apple ID)

Prereqs: a Mac and an iPhone signed into the **same iCloud account**;
both apps built with real signing (`just mac-build` with a Developer ID /
development cert; `just ios-device-build`-style device install — simulator
cannot receive real APNs pushes reliably, use hardware).

1. **Mac**: Settings → Monitoring Hub → enable *"Act as monitoring hub for
   your other devices"*. Status should read "iCloud available"; the menu
   bar shows the fleet-health database icon.
2. **iPhone**: Fleet Monitor → gear → enable *"Receive alerts from your Mac
   hub"*. Accept the notification-permission prompt.
3. Open a lock in a test database from any client, e.g.:

   ```sql
   BEGIN; SELECT * FROM some_table FOR UPDATE;  -- leave open
   -- second session:
   UPDATE some_table SET id = id WHERE id = 1;  -- now blocked
   ```

4. Within one hub poll interval (default 30 s) the Mac menu bar icon turns
   red and the iPhone shows a push ("<instance>: lock contention") — with
   the app closed, screen locked, Wi-Fi off (push arrives over cellular),
   per the roadmap acceptance test.
5. Tap the notification → the app opens routed to the affected instance.
6. `ROLLBACK;` both sessions; the next poll clears the condition (the hub
   relays edge-triggered alerts only, so no "cleared" push is sent —
   by design for now).

Troubleshooting:

- Hub status "No iCloud account" → sign into iCloud on the Mac (System
  Settings) — the app itself never asks for credentials.
- Push never arrives → CloudKit Console → Development → *Subscriptions*:
  confirm `fleet-alerts-v1` exists for the device's user record; toggle the
  iPhone setting off/on to re-create it. Also confirm the `FleetAlert`
  record actually appeared under the `FleetAlerts` zone (if not, the hub
  side failed — check the hub status line).
- Double notifications with background alerts also on → expected only if
  the BGAppRefresh poll fired **before** the hub push for a brand-new
  condition (rare; the alertId dedupe covers the common order).
