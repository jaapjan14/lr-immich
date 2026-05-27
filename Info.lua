--[[----------------------------------------------------------------------------
lr-immich — Lightroom Classic publish service for Immich

Replaces the built-in "Hard Drive" publish provider currently powering
the lr-sync workflow. Two reasons it exists:

  1. The built-in Hard Drive provider re-flags every photo in the
     publish queue on ANY metadata change (color labels, ratings, etc.),
     because it hard-codes its trigger set. Custom publish providers
     get to declare metadataThatTriggersRepublish — so we narrow it to
     fields Immich actually cares about (keywords, captions, GPS, etc.).

  2. With our own processRenderedPhotos, we can distinguish
     metadata-only changes from image-byte changes and call Immich's
     metadata API directly when no pixels moved — skipping the slow
     full-JPEG upload that lr-immich-sync.sh does today.
------------------------------------------------------------------------------]]

return {
    LrSdkVersion        = 14.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier = 'com.lakatua.lr-immich',
    LrPluginName        = 'lr-immich (Immich publish)',
    LrPluginInfoUrl     = 'https://github.com/lakatua/lr-immich',

    LrExportServiceProvider = {
        title = 'Immich (lr-immich)',
        file  = 'publishServiceProvider.lua',
    },

    -- v0.6.1: removed LrMetadataProvider. v0.5.0–v0.6.0 stored a
    -- per-photo "publishSignature" in the catalog via setPropertyForPlugin,
    -- but that path tripped SQLITE_BUSY_SNAPSHOT (error 517) whenever
    -- LR's connection had a stale snapshot from our prior sqlite3
    -- flag-clear. Signatures now live in a sidecar Lua file under
    -- ~/Library/Application Support/lr-immich/. See publishServiceProvider.lua.

    -- v0.6.3: pushSelected restored. v0.6.2 stripped it on the
    -- assumption that LR's "Modified Photos to Re-Publish" UI staleness
    -- was pushSelected-specific. Turns out the staleness is universal —
    -- regular Publish has it too; we just notice less because the
    -- publish progress dialog gives visual feedback. Photos are
    -- correctly patched on Immich and the catalog flag is cleared in
    -- either path; the LR UI just needs an LR restart (or collection
    -- switch + back) to refresh its cached view. Documented in the
    -- menu's completion dialog.
    LrLibraryMenuItems = {
        {
            title = 'Push Selected to Immich',
            file  = 'pushSelected.lua',
        },
    },

    VERSION = { major = 0, minor = 7, revision = 0, build = 1 },
}
