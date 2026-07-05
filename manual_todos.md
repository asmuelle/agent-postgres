# Manual TODOs — human-only steps (Apple account required)

Status as of 2026-07-05: Phases 0–1 of `docs/roadmap.md` are code-complete and
committed. The three items below are the only things the codebase cannot do for
itself — they all need your Apple Developer account. Delete each section (or
the file) as you complete it. Detailed CloudKit background lives in
`docs/cloudkit-setup.md`; this file is the actionable checklist.

---

## TODO 1 — Developer portal: capabilities + CloudKit container (~15 min)

Where: <https://developer.apple.com/account/resources/identifiers/list>

For **each** of the two App IDs — `com.pgagent.macos` and `com.pgagent.mobile`:

1. Open the identifier → **Capabilities** tab.
2. Enable **iCloud**, tick *Include CloudKit support*, click *Configure* and
   attach the container **`iCloud.com.pgagent.pgagent`**.
   - The first time through, create that container in the same panel
     (*Register an iCloud Container*). Propagation can take a few minutes —
     if it doesn't appear in the picker immediately, refresh and retry.
3. Enable **Push Notifications**. Nothing else to configure — CloudKit
   subscriptions ride Apple's push infrastructure implicitly; you do NOT need
   to create an APNs key or certificate.
4. Save. If you use manually-managed provisioning profiles anywhere,
   regenerate and re-download them now (Xcode automatic signing repairs
   itself on the next build; `-allowProvisioningUpdates` is already passed by
   the `just` recipes).

Gotchas:

- The Mac app ships **Developer ID + Sparkle** (not Mac App Store). CloudKit
  works with Developer ID, but the build must carry a provisioning profile
  containing the iCloud entitlements. Local ad-hoc builds will show
  "iCloud unavailable" in Settings → Monitoring Hub — expected, not a bug.
- The entitlements in the repo say `aps-environment: development`. TestFlight
  and App Store submission rewrite this to `production` automatically —
  do not hand-edit.

Done when: both App IDs list iCloud (with the container) and Push
Notifications as enabled capabilities.

---

## TODO 2 — CloudKit schema: create in Development, deploy to Production (~10 min + one release-blocking step)

Where: <https://icloud.developer.apple.com/> → container
`iCloud.com.pgagent.pgagent`

Part A — Development (automatic, you just trigger + verify):

1. Build and run a **signed** Mac app (`APPLE_DEVELOPMENT_TEAM=<team> just
   mac-build`, or any dev-cert build), sign into iCloud on that Mac, enable
   Settings → Monitoring Hub → *"Act as monitoring hub for your other
   devices"*.
2. Provoke any alert once (easiest: point a profile at a test DB and take a
   lock — the SQL recipe is in `docs/cloudkit-setup.md` §3). The first
   successful publish auto-creates, in the **Development** environment:
   - custom zone `FleetAlerts`
   - record type `FleetAlert` with fields `alertId`, `instanceId`,
     `instanceName`, `severity`, `kind`, `title`, `detail` (String),
     `blockerPid` (Int64, optional), `createdAt` (Date/Time)
3. Also trigger the **user-data sync** schema once (roadmap 2.3): on the same
   signed build, enable Settings → Sync → *"Sync via iCloud"* and let it run
   a sync ("Up to date"). That auto-creates, in **Development**:
   - custom zone `UserData`
   - record type `SyncedProfile` with fields `payload`, `name`,
     `environment`, `color`, `sshProfileRef` (String), `isReadOnly`,
     `deleted` (Int64), `updatedAt`, `deletedAt` (Date/Time)
   - record type `SyncedSavedQuery` with fields `profileId`, `title`, `sql`
     (String), `deleted` (Int64), `createdAt`, `updatedAt`, `deletedAt`
     (Date/Time)

   (Saving at least one connection profile before enabling sync guarantees
   both record types are exercised — add a saved query too for
   `SyncedSavedQuery`.)
4. Verify in CloudKit Console → Data → Development that the record types and
   zones exist. No custom indexes are needed (the alert subscription is
   TRUEPREDICATE, the sync subscription is a zone subscription; records are
   fetched by ID / zone change token).

Part B — Production (**manual, release-blocking**):

5. CloudKit Console → *Deploy Schema Changes…* → Development → **Production**.
   Production NEVER auto-creates schema. Skipping this bricks the alert relay
   AND profile/saved-query sync for every TestFlight/App Store user while
   working fine on your own dev devices — the most deceptive failure mode
   there is. Make this a hard item on the release checklist for ANY build
   that leaves your machines.

Done when: `FleetAlert`/`FleetAlerts` **and**
`SyncedProfile`/`SyncedSavedQuery`/`UserData` appear in the **Production**
schema view.

---

## TODO 3 — App Store Connect app record + first TestFlight upload (~20 min)

Where: <https://appstoreconnect.apple.com/> → My Apps → ➕ → *New App*

1. Create the app record:
   - Platform: **iOS** · Bundle ID: **`com.pgagent.mobile`** (pick the
     registered App ID from TODO 1) · SKU: anything stable, e.g.
     `pgagent-mobile` · Name: your call ("pgAgent" may be taken; have a
     fallback like "pgAgent — Postgres Cockpit") · Primary language, access:
     defaults are fine.
2. First upload from the repo root:

   ```sh
   just ios-testflight        # = ios-archive (Release, arm64) + ios-upload
   ```

   Auth options for the upload step (`just ios-upload`):
   - Interactive: being signed into Xcode with your Apple ID is enough.
   - Headless/CI: create an App Store Connect **API key** (Users and Access →
     Integrations → App Store Connect API, role App Manager), download the
     `.p8` once, then:

     ```sh
     ASC_KEY_ID=<KeyID> ASC_KEY_ISSUER_ID=<IssuerID> just ios-upload
     # .p8 expected at ~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8
     # (or point ASC_KEY_PATH at it)
     ```

   The export options (`scripts/export_options_appstore.plist`) upload
   directly with symbol upload and auto-managed build numbers — no .ipa is
   left on disk.
3. In App Store Connect → TestFlight: wait for processing (~5–30 min), answer
   the export-compliance question (the app uses only standard TLS/ATS →
   "standard encryption, exempt"), then create an **Internal Testing** group
   and add yourself.
4. Install via the TestFlight app on your iPhone. This is a real-signed
   device build — the CloudKit end-to-end test (`docs/cloudkit-setup.md` §3:
   Mac takes the lock, iPhone gets the push, Face ID → terminate → chain
   cleared) works from exactly this build. Record that flow: it is the App
   Store preview video per the roadmap's Phase 1 exit criterion.

Done when: the build shows "Ready to Test" and the push round-trip works on
hardware.
