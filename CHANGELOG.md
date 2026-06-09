# lr-immich changelog

## 0.9.1 — 2026-06-08

Tag-sync fix for keywords containing "/". Keywords like
`Summilux 35mm f/1.4 FLE` were failing tag sync on every publish with
`POST /api/tags … 400 "A tag with that name already exists"`, which
aborted `syncTags` for the whole photo.

Cause: Immich treats `/` as a tag **hierarchy separator**. That keyword
becomes a tag whose `value` is the full path `Summilux 35mm f/1.4 FLE`
(child of an auto-created `Summilux 35mm f`), but whose `name` is just the
leaf `1.4 FLE`. `fetchAllTags` and `syncTags` keyed their caches by the
JSON **`name`** field, so any "/"-containing keyword never matched an
existing tag → the plugin tried to *create* it → 400.

Fix: key the tag cache and the asset's current-tags by **`value`** (the
full path) instead of `name`. LR keywords always equal the full value, so
they now match existing tags — no spurious create, no 400, syncTags runs
to completion. Verified against the Immich DB that assets carry only their
leaf/full tags (never the structural parent), so the add/remove diff stays
correct and won't unlink a parent. Applied to both publishServiceProvider.lua
and pushSelected.lua.

## 0.9.0 — 2026-06-08

Fork-crash hardening. Stops the intermittent macOS crash where a publish
run dies mid-batch with `EXC_BAD_ACCESS` / "crashed on child side of fork
pre-exec."

Background:
The 2026-06-08 incident produced 7 crash reports in a single publish,
all fork-children segfaulting before exec — stack ending in
`fork → libSystem_atfork_child → objc_class::realizeIfNeeded`. Cause is
the well-known macOS landmine: `fork()` is not safe in a multithreaded
process with the Objective-C runtime loaded (Lightroom has CEF + ObjC
live). Every `LrTasks.execute` shell-out is such a fork, and the plugin
shelled out to `curl` for *every* JSON API call — so a large batch meant
many forks and good odds one hit the race. (That run still completed: all
33 photos uploaded once, no duplicates — the crashes were non-fatal fork
children, but they flooded logs and could drop individual calls.)

Two fixes:

1. `curlJson` now uses native `LrHttp` instead of shelling out to `curl`.
   Tag list/create, tag link/unlink, asset GET, metadata PATCH, and the
   Darkroom title push all run in-process now — no fork, no crash surface.
   This removes the large majority of forks per publish. Same return
   contract: `(httpStatusCode, responseBody)`; `(0, errText)` on transport
   failure; 4xx/5xx still return status + body for diagnostics.

2. New `execResilient()` wrapper retries `LrTasks.execute` on failure
   (default 3 tries, 0.2s·attempt backoff, logged). Applied to the three
   remaining genuine forks — the `curl` multipart PUT in `replaceExisting`
   (LrHttp can't issue PUT, see its note), `mkdir -p` for the sig sidecar,
   and the sqlite3 `photoNeedsUpdating` flag-clear. All idempotent, so a
   retry after a fork-child crash is always safe and usually succeeds
   (the race is intermittent).

Net: a publish now forks ~once per replaced photo instead of ~5–10×, and
any fork that does crash is retried instead of failing the photo.

`pushSelected.lua` (the Library → Plug-in Extras "Push Selected to Immich"
action) gets the same treatment: `LrHttp` for GET/POST/PUT, curl-only for
DELETE-with-body, and `execResilient` on the DELETE and the sqlite3
flag-clear. It does metadata-only PATCHes (no multipart upload), so after
this it forks at most on a keyword removal or the final flag-clear.

## 0.8.0 — 2026-05-26

Service-wide remoteId lookup. Fixes already-synced photos appearing as
"New Photos to Publish" (and re-uploading as duplicates) when published
through a *different* collection of the same publish service than the
one they were originally synced through.

Background:
LR tracks published-state per collection. The 2026-Digital catalog has
two collections under the Immich service: `z8-immich` (default) and
`tag-z8-immich` (keyword smart collection). All actual syncing — original,
the post-keyword re-sync, and the 2026-05-26 disaster recovery — ran
through `z8-immich`, so its ledger holds the 224 records. The plugin log
confirms `tag-z8-immich` was *never* published through: its ledger was
empty from creation, so it showed all 240 matching photos as "new" even
though 224 were already in Immich. `processRenderedPhotos` built its
`remoteIdByPhotoId` lookup solely from `publishedCollection:getPublishedPhotos()`
(the collection being published), found nothing in `tag-z8-immich`, and
would have routed all 224 already-in-Immich photos to UPLOAD-NEW →
duplicates.

Fix: the lookup now harvests `getPublishedPhotos()` from EVERY collection
in the service (walks `getService()` → `getChildCollections()` /
`getChildCollectionSets()` recursively; current collection harvested
first so it wins ties). Already-synced photos are found wherever their
record lives, route to metadata-only/replace (UUID preserved, no
duplicate), and LR records the published-state into the current
collection via `recordPublishedPhotoId` — the corruption-free way to
re-link, unlike hand-editing AgRemotePhoto/AgLibraryPublishedCollectionImage
directly (which LR rejects as a corrupt catalog; tried and reverted from
backup earlier the same day).

Verified 2026-05-26: published `tag-z8-immich` → `224 metadata · 16 new`.
Immich owner active count 3741 → 3757 (+16, no duplicates); all 224
original UUIDs still single and active; the 16 genuinely-new uploaded
clean. Tested on one photo (`_DSC2803`) via a throwaway `ztest`
collection first — log showed the service-wide harvest finding its
remoteId in `z8-immich` and routing METADATA-ONLY, Immich count unchanged.

## 0.7.0 — 2026-05-19

Title sync to Darkroom. Closes the gap left open by v0.5.0's
metadata-only PATCH path: title-only LR edits no longer get silently
dropped just because Immich's asset model has no `title` field.

Background:
v0.5.0 introduced the metadata-only PATCH path (~500ms vs ~30s full
re-upload) for caption/GPS/dateCreated edits. Title was punted on
because Immich's `PUT /api/assets/{id}` doesn't accept one. Result:
adding a title to an already-published photo flipped it into "Modified
Photos to Re-Publish", a republish ran via the cheap PATCH path, the
bezel said `✓`, but the JPEG bytes (where Darkroom reads title from)
were never updated. Title silently dropped.

Fix: parallel sidecar to a Darkroom Log server (v1.5.48+). Title rides
alongside the cheap PATCH, no re-render. Caption/GPS/date still go to
Immich; title goes to Darkroom's new `POST /api/lr-title` endpoint.

What's new:
- New publish service field **Darkroom URL** (optional). When blank,
  title sync is a no-op — plugin works exactly like v0.6.5. When set
  (e.g., `https://your-darkroom.example.com`), every publish run pushes the
  photo's current LR title to Darkroom via `POST /api/lr-title` with
  body `{"assetId": "<immich-uuid>", "title": "<lr-title>"}`.
- Auth: the Darkroom endpoint reuses the same Immich API key the plugin
  already has (sent as `x-api-key`). No new token to manage. Darkroom
  validates the key against its own Immich and caches valid keys for
  5 min.
- Wired into **all three** publish paths — metadata-only PATCH,
  REPLACE, UPLOAD-NEW — so the Darkroom title index is always current
  regardless of which path a given publish takes.
- Best-effort: if Darkroom is unreachable or the URL is wrong, the
  failure is logged to `/tmp/lr-immich.log` but the photo still
  reports `✓` to LR. Title sync should never break an Immich publish.
- New `exportPresetField` `darkroomBaseUrl` (URL only; no new
  secrets in the catalog).

How Darkroom uses it:
- Title index entries pushed via this endpoint are tagged
  `source: "lr"` and are authoritative. Darkroom's 6-hour JPEG-byte
  scanner skips them so it can't clobber a synced title with whatever
  it does (or doesn't) find in the JPEG.
- Existing JPEGs that already have title baked into IPTC bytes are
  unchanged — the byte scanner still picks those up for non-LR
  uploads.

Files: `Info.lua` (version bump to 0.7.0), `publishServiceProvider.lua`
(+`darkroomBaseUrl` field, UI row, `pushTitleToDarkroom` helper, 3
call-sites in the publish loop).

## 0.6.5 — 2026-05-13

End-of-run publish summary. LR's Publish Services panel caches its
"Modified Photos to Re-Publish" grouping and routinely lies about
state until restart (gotcha #8 — see lr-classic-plugin-sdk-gotchas.md).
That left users unsure whether a metadata-only push actually went
through.

Fix: count successes/failures per path (metadata-only, replace,
upload-new) during `processRenderedPhotos` and show an end-of-run
LR bezel like `lr-immich ✓ 5 metadata · 1 replaced · 0 new`. On any
failure, additionally pop a warning dialog pointing at `/tmp/lr-immich.log`.
Bezel is transient and non-blocking; the dialog only appears when
something actually went wrong.

The Publish Services panel still lies — this doesn't fix the SDK
view-cache bug — but at least the user has reliable confirmation
that the publish itself succeeded.

## 0.6.4 — 2026-05-12

Bug: 16-photo UPLOAD-NEW run only landed 1 tag on most assets (out of
the LR-side 16 keywords).

Root cause: Immich's IPTC parser asynchronously creates tags during
multipart uploads — so by the time `syncTags` runs immediately after
POST `/api/assets`, our `globalTagCache` (fetched at publish-start)
is stale by a couple of seconds. When `syncTags` then tries to POST
`/api/tags` for a keyword that Immich auto-imported during the upload,
Immich returns 400 "A tag with that name already exists". v0.6.3
treated that as a fatal error and aborted the entire sync for that
asset → only the tags created before the first conflict got linked.

Fix: catch the specific 400 "already exists" error. Refresh the global
tag cache from Immich (one-time per sync run, not per-conflict to avoid
N+1 GETs), look up the now-known id, and continue. Tags that get
auto-imported by Immich's parser don't need our POST; they just need
our PUT-to-link to ensure the asset is associated.

Recovery for the 16 photos already uploaded today: Mark each to
Re-publish in the Sync to Immich collection, then click Publish.
They'll take the REPLACE path (since their develop hash matches the
stored signature, but wait — signatures were saved on upload-new, so
they actually take METADATA-ONLY now). Either way, syncTags re-runs
with v0.6.4's resilient retry, and the missing 15 tags per photo get
linked properly.

## 0.6.3 — 2026-05-12

Restored `pushSelected.lua` (was removed in v0.6.2). v0.6.2's removal
was an overcorrection: we attributed the persistent "Modified Photos
to Re-Publish" UI state to pushSelected, but it turned out to be a
universal LR Publish Services view cache — regular Publish has the
same issue, we just notice less because the publish progress dialog
gives visual feedback that "something happened."

What actually happens after either path (pushSelected OR regular
Publish via metadata-only):
- Immich is correctly patched (description, GPS, dateTimeOriginal)
- Tags are mirrored (Option A: adds + removes)
- `AgRemotePhoto.photoNeedsUpdating` is set to 0
- BUT `AgRemotePhoto.metadataDigest` / `developSettingsDigest` are
  NOT updated (only the internal LR machinery behind
  `rendition:recordPublishedPhotoId` updates those, and even that
  may be lazy for migrated rows)
- So when LR's Publish Services view reads the digests, it sees a
  mismatch vs the current photo state and keeps the photo in
  "Modified" until a fresh view-load (LR restart or collection
  switch + back)

User-visible behavior:
- The photo's Immich state is current.
- The LR view is stale but harmless.
- Restart LR (or click another collection and back) to refresh.

The `pushSelected` completion dialog now explicitly tells users about
this so they don't dig into "why is my photo still Modified" again.

## 0.6.2 — 2026-05-12

Removed `pushSelected.lua` and its `LrLibraryMenuItems` wiring in
Info.lua. The menu item worked correctly (PATCH + tag sync + sqlite3
flag-clear) but **LR's "Modified Photos to Re-Publish" UI doesn't
clear** after it runs — LR compares `AgRemotePhoto.metadataDigest`
and `developSettingsDigest` to the photo's current state, and only
`rendition:recordPublishedPhotoId()` (called inside an export
session) triggers LR to recompute and store those digests. A
non-export-session code path like pushSelected can't replicate that
without significant catalog reverse-engineering.

Given the v0.6.1 METADATA-ONLY fast path is ~1 sec for the common
case (no full upload, no trashed shadow), regular Publish is already
the one-click workflow. The menu item was redundant churn.

Investigation findings (left here in case we revisit):
- `AgRemotePhoto` columns relevant to Modified detection:
  - `photoNeedsUpdating` — gets cleared by both sqlite3 hack and
    regular Publish, but LR's UI ignores this.
  - `metadataDigest` — 32-char (MD5) of the photo's metadata at
    last successful publish. Compared against current metadata.
  - `developSettingsDigest` — 32-char (MD5) of develop settings
    at last successful publish.
  - `Adobe_imageDevelopSettings.digest` — develop settings digest
    of the CURRENT photo state (recomputed on develop edit).
- LR's algorithm for these MD5s is internal; no SDK accessor.
- To fix pushSelected we'd need either (a) reverse-engineer the MD5
  input format and write the digests via sqlite3 ourselves, or
  (b) build a custom LrExportSession with `skipRender` per rendition
  so the standard recordPublishedPhotoId flow runs. Both are
  high-effort relative to the marginal benefit over regular Publish.

## 0.6.1 — 2026-05-12

Fixes the two failures that hit during v0.6.0's 67-photo run:

### Bug A — fabricated tag API endpoint

v0.6.0 called `PUT /api/tags/upsert` with `{tags: [names]}`. That
endpoint does not exist on Immich; the path validator tries to parse
`upsert` as the `:id` URL param of `PUT /api/tags/{id}`, fails the
UUID check, and returns 400 with `"id must be a UUID"`. v0.6.0 used
`curl -f` which silently discards 4xx bodies, so the log just showed
`curl exit 56` without surfacing what Immich actually said.

v0.6.1 corrections:
- **Real endpoint shape**: `GET /api/tags` (list user's tags) +
  `POST /api/tags` `{name}` to create one. Immich returns the tag
  object with its UUID on create.
- **`fetchAllTags()` once at publish start** — caches the name→id map
  in `globalTagCache`, shared across all photos in the run. Saves a
  GET per photo.
- **`createTag()` on demand** — only when LR has a keyword that
  doesn't exist in Immich yet. Updates the cache so subsequent photos
  in the same run that share the keyword skip the POST.
- **Drop `-f` flag** on all curl invocations; new `curlJson()` helper
  returns `(httpStatusCode, responseBody)` so error bodies always
  surface in the log.

### Bug B — catalog lock contention (SQLITE_BUSY_SNAPSHOT 517)

v0.5.0–v0.6.0 stored the per-photo `publishSignature` via
`setPropertyForPlugin` inside a `with[Private]WriteAccessDo` block at
end of publish. Symptom: 517 lock errors hung LR's UI, blocked
develop-setting writes (the `Adobe_imageDevelopSettings` UPDATE
dialog), and required force-quit-grade recovery.

Root cause: our prior sqlite3 batch flag-clear (BEGIN IMMEDIATE on
WAL-mode catalog) leaves LR's connection with a stale snapshot. The
subsequent `withWriteAccessDo` block tries 67 INSERT INTO
AgPhotoProperty calls inside one transaction, hits the snapshot
mismatch on the FIRST one, and the whole transaction fails. LR's own
post-publish bookkeeping (which also writes to AgPhotoProperty) then
piles up behind the failed lock state.

v0.6.1 fix: **stop writing to the catalog from plugin code entirely.**
Signatures move to a sidecar Lua file at
`~/Library/Application Support/lr-immich/signatures.lua`. Format is a
single Lua `return { [photoId] = "sig", ... }`. Loaded once on first
access (cached in module state), rewritten whole on each successful
publish run.

- `loadSignatures()` — lazy load from disk, cache.
- `getSignature(photoId)` / `setSignature(photoId, sig)` — in-memory.
- `saveSignatures()` — one `io.open(...'w')` flush at end of publish.

Side effects:
- `LrMetadataProvider` removed from Info.lua; `metadataProvider.lua`
  deleted from the plugin. The plugin no longer touches LR's metadata
  schema at all.
- Signatures don't survive a catalog backup/restore. Worst case after
  restore: fall back to REPLACE path on first publish of each photo,
  same as if upgrading from a pre-v0.5.0 install. Acceptable.
- Not portable across Macs (sidecar is in user's Library). If you
  move catalogs to a new Mac, first publish per photo re-signs.

### Diagnostic improvements (carryover from the v0.6.0 postmortem)
- `curlJson()` separates `-o body.txt -w "%{http_code}"` so we always
  have both the response body and the HTTP status, even on 4xx/5xx.
- `pushSelected.lua` uses the same helper — its tag sync now goes
  through the real Immich API too.

### First-on-wifi validation
1. Plug-in Manager → confirm version reads `0.6.1`.
2. `tail -1 /tmp/lr-immich.log` → expect `[v0.6.1] ---- plugin module loaded ----`.
3. Pick one already-published photo, add ONE keyword, publish.
4. Expected log:
   ```
   tag cache: loaded N existing Immich tags
   → METADATA-ONLY path (PUT /api/assets/...)
   ✓ metadata patch succeeded
   tag sync (metadata-only): tag sync ok, added=1 removed=0 (lr_kw_count=N)
   signatures flushed to sidecar: 0 new, ... total
   ```
   (Note: signatures from this morning's 4-photo run won't be in the
   sidecar — they were never persisted under v0.5.0/v0.6.0. So even
   already-published photos will take REPLACE the first time post-
   v0.6.1.)
5. Verify in Immich web UI: new tag appears on that asset.
6. Remove the keyword, publish again — expect `added=0 removed=1`.

If anything 400s, the log will now include the actual response body.
Paste it and we iterate.

## 0.6.0 — 2026-05-12  ⚠️ UNTESTED — wait for first-on-wifi validation

Keyword → Immich-tag sync (Option A: mirror, includes removals). Closes
the v0.5.0 gap where keyword edits forced a full JPEG re-upload because
the only path to land them in Immich was re-embedding them in EXIF.

What changed:

- **Signature is now develop-settings-only.** v0.5.0 included the sorted
  keyword list in the signature, so any keyword change → mismatch → full
  upload. v0.6.0 drops keywords from the signature. The signature is now
  the gate that asks "have the rendered JPEG bytes changed?", and only
  develop edits flip it.
- **New `syncTags(url, apiKey, remoteId, lrKeywords)` helper.** Mirrors
  the photo's LR keyword list to the Immich asset's tag set:
  - `GET /api/assets/{id}` to read current Immich tags
  - Compute diff (case-sensitive name matching)
  - `PUT /api/tags/upsert` for new names → returns tag UUIDs
  - `PUT /api/tags/{id}/assets` to link each new tag
  - `DELETE /api/tags/{id}/assets` to unlink any Immich tag that's no
    longer in the LR keyword list (Option A semantics).
  Tag names sourced via `getFormattedMetadata('keywordTagsForExport')`,
  which respects LR's per-keyword "Include on Export" flag and handles
  containing-keyword expansion automatically.
- **Wired into all three publish paths** in `processRenderedPhotos` —
  metadata-only, replace, and upload-new. Tag-sync failure is logged but
  does NOT abort the publish (the bytes/metadata still landed; the tags
  can retry on next publish).
- **`pushSelected.lua` wired up** via `LrLibraryMenuItems` in Info.lua.
  Appears as Library → Plug-in Extras → Push Selected to Immich. Uses
  the same metadata + tag-sync path. Develop-edit photos still get
  skipped (need full Publish to re-render).

What this means for your workflow:
- Caption edits, GPS fixes, dateCreated tweaks → fast PATCH (already
  was, no change).
- **Keyword add/remove → fast tag-sync** (NEW). No more full upload, no
  more trashed shadow, ~0.5s/photo over the API.
- Develop edits → full re-render+upload (unchanged — really did change
  the bytes).

⚠️ **Tradeoff baked in** (Option A choice): if you tagged photos
directly in the Immich web UI or iOS app, those tags will get unlinked
the next time LR republishes those photos. From v0.6.0 onward, **tag
only from LR**. Tags themselves remain in Immich's tag library; they
just lose their link to your assets.

Three v1 simplifications:
- Flat tag names (no hierarchy mirroring — LR's `Animals > Birds > Eagle`
  becomes three separate flat Immich tags `Animals`, `Birds`, `Eagle`,
  matching what LR exports to EXIF anyway).
- JSON parsing is pattern-based (no jq dependency). Breaks if a tag
  name contains an unescaped double quote — LR keyword UI strips most
  weird characters so this is academic.
- Multiple lr-immich publish services: pushSelected uses the FIRST one.
  Add a picker when that becomes real.

UNTESTED until Jacob is back on home wifi. Could not validate API
endpoints against a live Immich from the coffee shop. First-on-wifi
checklist:
1. Plugin Manager → confirm version reads 0.6.0.
2. Pick one already-published photo, add a keyword in LR, publish.
3. Log should show `→ METADATA-ONLY path` and
   `tag sync (metadata-only): tag sync ok, added=1 removed=0`.
4. Verify in Immich web UI that the new tag appears on that asset.
5. Remove the keyword in LR, publish, expect `added=0 removed=1`.

If any of the API endpoint names are off (Immich's REST shape varies
across major versions), the curl exit codes in the log will tell us
which call is wrong and the fix is one shellEscape() line.

## 0.5.1 — 2026-05-12

Bugfix: v0.5.0's signature-save block silently failed.

Symptom: 4-photo test run showed `batched flag-clear: 4 photos, rc=0`
but the `batched signature save: 4 photos` line never appeared in the
log. The inner `setPropertyForPlugin` call inside
`catalog:withPrivateWriteAccessDo('name', function() ... end)` either
threw or no-op'd — without the log line on the other side of the
withWriteAccess block, the cause is invisible. Result: photos got
their `photoNeedsUpdating` flag cleared (so they left the Modified
queue) but their `publishSignature` was never persisted, so next
publish they'd take REPLACE path again and re-upload.

Fix:
- Switch to `catalog:withWriteAccessDo('name', function() ... end)` —
  the named, history-visible write API that's the SDK's documented
  path for `setPropertyForPlugin`. The "private" variant works for
  some plugin properties on some SDK versions but is finicky.
- Add a pre-call log line (`signaturesToSave queued: N entries`) so
  if the next write attempt also silently fails we can see whether
  the table even had entries to begin with.

Side effect: signature saves now create a user-visible history step
("lr-immich: save publish signatures"). One step per publish run, not
per photo.

## 0.5.0 — 2026-05-12

Metadata-only routing (task #31). Caption/GPS/dateCreated edits no longer
trigger a full JPEG re-render + upload + trashed-shadow cycle. Instead
they take a fast `PUT /api/assets/{id}` JSON PATCH (~500 ms round-trip),
leaving the Immich asset's bytes — and its file path — untouched.

How it works:
- New plugin metadata field `publishSignature` per photo (declared in
  `metadataProvider.lua`, hidden from the user). Holds a serialized
  hash of develop settings + sorted keyword list — anything that, if
  changed, would alter the rendered JPEG bytes.
- On each publish, `processRenderedPhotos` computes the current
  signature and compares to the stored one:
  - **Match** → metadata-only path. Render is paid (LR doesn't expose a
    safe way to skip it inside this hook), but the curl PUT of the
    JPEG to `/api/assets/{id}/original` — the slow part — is replaced
    by a 200-byte JSON PATCH against `/api/assets/{id}`. No shadow is
    created, no path drift, no trash growth.
  - **Mismatch** (or no stored signature yet) → existing REPLACE / UPLOAD-NEW
    path runs, and the new signature is saved.
- Signatures are batch-saved in one `withPrivateWriteAccessDo` block at
  end of publish — same pattern as the batched flag-clear, to avoid
  catalog write contention.

What the metadata PATCH covers:
- LR caption → Immich `description`
- LR GPS (lat/long) → Immich `latitude` / `longitude`
- LR dateCreated → Immich `dateTimeOriginal`

What's deliberately NOT covered yet:
- **Keywords → Immich tags.** Immich tags are a separate API surface
  (`/api/tags` + asset-tag join endpoints). v0.5.0 plays it safe:
  keyword changes flip the signature, forcing a full re-upload so the
  new keywords get re-embedded in the JPEG EXIF (Immich picks them up
  from there). A follow-up task could sync keywords→tags directly and
  let keyword-only changes take the cheap path too.
- **LR title.** No clean Immich equivalent.

One-time migration cost:
- Existing 3,166 photos have no `publishSignature` recorded. The first
  time each one is flagged for republish after this upgrade, it falls
  into the REPLACE branch (signature mismatch → full upload), pays the
  full cost once, and records its signature on the way out. Every
  subsequent metadata-only edit is fast.

## 0.4.2 — 2026-05-12

Cosmetic polish.

- **Plugin icon**: `provider.small_icon = 'darkroom-icon.png'` —
  Darkroom Log's orange film-reel "DR" mark now shows next to
  "Immich (lr-immich)" in LR's Publish Services panel header.
  Copied from the Darkroom Log container's favicon (32x32 PNG).
  Requires a full LR restart to take effect; LR loads plugin icons
  at plugin-init time, not on plugin reload.
- **Progress bar**: `processRenderedPhotos` now drives
  `progressScope:setPortionComplete(i, nPhotos)` before each
  rendition and after each iteration. v0.4.1's progress bar sat
  at 0% for the entire 89-photo publish because the scope was
  created but never updated.

No behavior change.

## 0.4.1 — 2026-05-12

CRITICAL FIX. v0.4.0 (and v0.3.9 before it) shelled out to sqlite3
per-photo to clear `photoNeedsUpdating=0`. Worked fine for single-photo
testing. **Catastrophic on batches**: during a 60-photo publish, the
rapid-fire sqlite3 UPDATEs contended with LR's own writes (history
steps, AgRemotePhoto state). LR's connection eventually couldn't
acquire its write lock and threw "database is locked (error code 517)"
errors, requiring force-quit.

Fix:
- Accumulate successfully-replaced photo IDs in a Lua table during the
  rendition loop.
- AFTER the loop ends, fire ONE sqlite3 call that clears all of them
  in a single transaction (`BEGIN IMMEDIATE; UPDATE ... IN (id1,id2,...);
  COMMIT;`).
- Add `-cmd ".timeout 30000"` so sqlite3 politely waits up to 30s for
  the write lock instead of racing.

Result: one brief lock acquisition at the very end of publish, instead
of N rapid acquisitions during the busy period when LR is also writing.

## 0.4.0 — 2026-05-12

Fix immichApiKey plaintext leak into catalog SQLite (task #32).

Previous versions declared `immichApiKey` in `provider.exportPresetFields`,
which means LR persists it (along with every other declared field) as
plaintext into `AgLibraryPublishedCollectionContent`. Anyone reading the
catalog file could extract the API key. The keychain-via-LrPasswords
code in startDialog/endDialog was working, but didn't prevent LR's own
framework persistence — which writes the propertyTable BEFORE endDialog
runs.

Fix:
- `immichApiKey` removed from `exportPresetFields` entirely. LR only
  persists declared fields, so the catalog blob will no longer contain it.
- `startDialog` populates `propertyTable.immichApiKey` at runtime from
  the keychain. The UI binds to that ephemeral field. Because the field
  isn't declared in `exportPresetFields`, LR won't write it to the
  catalog on save.
- `endDialog` (on OK) stores the current value to the keychain via
  `LrPasswords` keyed by `immichBaseUrl`.
- `getApiKey()` now reads ONLY from the keychain. The previous
  propertyTable fallback was a holdover from when the field was declared
  in exportPresetFields and arrived at publish time. With the
  declaration removed, the field doesn't exist at publish time anyway.

Verified: the keychain entry is unaffected, settings UI still loads and
saves the key correctly, and the catalog content blob no longer contains
`["com.lakatua.lr-immich_immichApiKey"]`.

One-time cleanup of existing plaintext leak: see SQL migration in the
session log for 2026-05-12. New publish service installs won't leak.

## 0.3.9 — 2026-05-11

Fix collection-id lookup for the sqlite3 photoNeedsUpdating clear.

v0.3.8 tried to get the collection id from
`exportContext.publishedCollectionInfo.id`, but `.id` is nil in this
SDK version (verified in the log). Get it from
`publishedCollection.localIdentifier` instead — same value, different
source. (The `publishedCollection` SDK object is the same one we
already resolved at the top of `processRenderedPhotos` for the
fallback lookup, so no extra work needed.)

## 0.3.8 — 2026-05-11

Bake in the sqlite3 photoNeedsUpdating=0 workaround.

After successful replace, the plugin now:
1. Calls `rendition:recordPublishedPhotoId(remoteId)` + `:recordPublishedPhotoUrl(url)` (LR way)
2. **Also runs `sqlite3 UPDATE AgRemotePhoto SET photoNeedsUpdating=0`** directly against the catalog file.

Why both: for migrated rows where `rendition.publishedPhoto` is nil at publish time (LR doesn't recognize our pre-populated AgRemotePhoto rows as proper LrPublishedPhoto objects), `recordPublishedPhotoId` can't fully clear the flag. The photo bounces back to "Modified to Re-Publish" after every publish.

Why this is safe: LR catalog is in WAL journal mode (verified). Concurrent writes from other processes don't conflict with LR's reads/writes. Tested: setting photoNeedsUpdating=0 via sqlite3 with LR closed; opening LR; photo stays in Published Photos.

Catalog path comes from `LrApplication.activeCatalog():getPath()`. Collection id from `exportContext.publishedCollectionInfo.id`. Photo id from `rendition.photo.localIdentifier`.

## 0.3.7 — 2026-05-11

REPLACE path now marks the rendition fully published.

- v0.3.6 fixed the upload itself (curl PUT works, UUID preserved) but
  the photo bounced back to "Modified to Re-Publish" after publish.
  Cause: the replace branch only called `rendition:recordPublishedPhotoUrl()`
  but NOT `rendition:recordPublishedPhotoId()`. Without the latter, LR
  doesn't update the rendition's publish state and treats the publish
  as incomplete.
- Fix: call both in the replace branch. `recordPublishedPhotoId` is
  idempotent — passing the same remoteId LR already has just refreshes
  the publish state.

Known cosmetic side effect (not addressed here): every PUT-replace
creates a trashed shadow in Immich that holds the old content; the
new content gets path `<filename>+1.jpg` while the shadow keeps the
canonical name. Doesn't affect UUID stability or Darkroom Log refs.
lr-immich-sync.py has the same behavior. Could be addressed by
auto-deleting the shadow after each successful replace — TODO.

## 0.3.6 — 2026-05-11

ROOT CAUSE found and fixed.

v0.3.5's log revealed the smoking gun:
`pcall getName: ok=false result=Yielding is not allowed within a C or metamethod call`

LR Classic SDK methods (`:getName()`, `:getPublishedPhotos()`, etc.) yield
internally to wait on async catalog work. `pcall` creates a non-yieldable
boundary — methods that yield inside pcall fail with this error. So my
"defensive" `pcall(function() return obj:getMethod() end)` wrappers
DEFEATED every SDK call I tried to make on the published collection.

`processRenderedPhotos` is already running inside a yieldable LR publish
task, so SDK methods can be called directly without pcall.

Fix: drop the pcall wrappers around SDK calls. Just invoke `:getName()`
and `:getPublishedPhotos()` directly. The object at
`exportContext.publishedCollection` IS the real LrPublishedCollection
(the type check returned `table`, which is correct — SDK objects are
Lua tables with metatables).

This should unblock the entire publish-via-smart-collection flow.

## 0.3.5 — 2026-05-11

Three-path resolution for LrPublishedCollection. v0.3.4's single attempt
caught `exportContext.publishedCollection` being a table-but-not-an-SDK-
object on some SDK versions (logged "pcall failed" but swallowed the
real error). v0.3.5:

- Path A: try `exportContext.publishedCollection` as SDK object
- Path B: `LrApplication.activeCatalog():getPublishedCollectionByLocalIdentifier(pubCollInfo.id)`
- Path C: iterate `exportContext.publishService:getChildCollections()` matching by localIdentifier
- All three log full pcall results with error messages — no more swallowed errors

Also logs the `publishedCollectionInfo` dict directly (always present per
SDK docs, contains name + id) so we know which collection LR thinks we're
publishing to.

## 0.3.4 — 2026-05-11

Fallback path when `rendition.publishedPhoto` is nil.

- Some renditions in publish-via-smart-collection flow don't get
  `rendition.publishedPhoto` populated even when an AgRemotePhoto row
  exists for `(collection, photo)`. Root cause uncertain; might be SDK
  version, smart-vs-built-in path, or a row-state condition LR checks
  that we haven't yet found.
- New fallback: at the top of `processRenderedPhotos`, build a
  `photo.localIdentifier → remoteId` lookup via
  `exportContext.publishedCollection:getPublishedPhotos()`. For each
  rendition, if the primary path returns no remoteId, fall back to the
  lookup table.
- Also logs the published collection's name and the lookup table size
  so we can see what LR considers "the published photos of this
  collection" at publish time.

## 0.3.3 — 2026-05-11

Diagnostic logging only — no behavior change.

- All routing decisions in `processRenderedPhotos` now log to
  `/tmp/lr-immich.log` (append mode, survives across LR launches).
- Module-load line marks every fresh load of the plugin code so we can
  tell when LR actually reloads vs. when it serves cached bytecode.
- Per-rendition log includes: photo filename, whether `publishedPhoto`
  is non-nil, what `remoteId` came back, which branch (`REPLACE` vs
  `UPLOAD-NEW`) was taken, and success/failure of each branch.
- `tail -f /tmp/lr-immich.log` to watch live during a publish.

This will tell us definitively whether the `+1` duplicates are coming
from stale bytecode (no v0.3.3 marker = LR didn't reload) or from a
real bug in the routing logic (logs show UPLOAD-NEW when REPLACE was
expected, or replace itself failed).

## 0.3.2 — 2026-05-11

Polish on the curl-based replace path.

- Removed the brittle `Accept: application/json` header (Immich returns
  JSON anyway; the header was using an unescaped backslash-space that
  worked in `/bin/sh` but was a parsing hazard).
- `deviceAssetId` on replace now prefixes with `lr-replace-` to match
  the convention `lr-immich-sync.py` uses. Immich writes this onto the
  trashed shadow it creates during PUT-replace, so shadow rows are
  distinguishable in postgres.
- Capture curl stdout+stderr to `/tmp/lr-immich-curl.log` on failure
  and surface the contents in LR's per-photo error message — so
  diagnosing real failures (auth, DNS, timeout, HTTP body) is one
  click instead of guessing from an exit code alone.

## 0.3.1 — 2026-05-11

Critical fix to the republish path.

- **replaceExisting now uses curl for PUT** (task #33). The previous
  call `LrHttp.postMultipart(url, fields, headers, 'PUT')` was broken:
  LR SDK's 4th arg to postMultipart is `timeoutInSeconds`, not a method
  override. The `'PUT'` got silently coerced/ignored and the call still
  POSTed. Immich's `/api/assets/<id>/original` endpoint requires PUT —
  POST gets interpreted as a new upload, hits the filename collision,
  and writes `<name>+1.jpg` as a brand-new asset. UUID stability was
  the whole point of the migration; this broke it.
- Fix shells out to `curl -X PUT` via `LrTasks.execute()`. macOS always
  has curl; curl handles multipart PUT natively. `-f` makes curl exit
  non-zero on HTTP ≥ 400 so we don't need to parse the response body.
- Added a `shellEscape()` helper for safe arg interpolation (single-quote
  wrap with `'\\''` substitution for internal quotes).

## 0.3.0 — 2026-05-11

End-to-end publish flow now implemented (minimum-viable; metadata-only
routing deferred to a follow-on).

- **processRenderedPhotos (task #28)**:
  - First publish of a photo: `POST /api/assets` multipart upload,
    record returned UUID as the LR remote id, link the published URL
    to `${baseUrl}/photos/${uuid}`.
  - Republish of an existing photo: `PUT /api/assets/{id}/original`
    multipart, UUID preserved (matches the behavior of
    `lr-immich-sync.sh` so Darkroom Log `prints.json` UUIDs stay
    stable across the migration).
  - Progress scope wired up; cancel is honored mid-batch.
  - Fail-fast guard: if URL or API key missing, every rendition
    is rejected with `uploadFailed` before LR starts rendering JPEGs.
- **goToPublishedPhoto**: right-click on a published photo in LR →
  "Show in Immich" opens the asset URL in the default browser.
- **immichDeviceId** export field added (default `lr-immich`) so the
  asset's `deviceAssetId` lookup namespace is stable.

Known limitation: every republish currently does a full JPEG upload.
Metadata-only changes (keyword/caption/title bumps) re-send the whole
file even though Immich could accept a small API-only update. Task #31
adds the smarter routing once we see real-world publish times.

## 0.2.0 — 2026-05-11

Plugin is now usable for connection setup; publishing is still stubbed.

- **Trigger blob (task #27)**: declared `metadataThatTriggersRepublish`
  with `default = false` and explicit fields only — `keywords`,
  `caption`, `title`, `gps`, `gpsAltitude`, `dateCreated`. Color
  labels, ratings, and other LR-internal organizational metadata no
  longer flag the catalog for republish. This is the central reason
  the plugin exists.
- **Connection settings UI (task #29)**: server URL, API key, library
  ID fields in the publish service dialog. "Test Connection" button
  hits `/api/server/about` and reports HTTP status / body via
  LrDialogs. API key is stored in macOS keychain via `LrPasswords`,
  indexed by base URL — never persisted to the catalog SQLite. The
  `immichApiKey` propertyTable slot is blanked on dialog close.

## 0.1.0 — 2026-05-11

Scaffold-only release. Plugin loads in LR Plugin Manager but does not yet
publish anything.

- Info.lua: SDK 14.0, identifier `com.lakatua.lr-immich`
- publishServiceProvider.lua: stub `processRenderedPhotos` that records
  `uploadFailed` on every photo (intentional — blocks accidental use
  before real implementation lands)
- Hides export-location / file-naming / video / watermarking sections
  in the publish service settings panel

Next: task #28 (real publish routing).
