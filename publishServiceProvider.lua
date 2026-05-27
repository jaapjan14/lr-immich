--[[----------------------------------------------------------------------------
publishServiceProvider.lua — Immich publish service

Status:
  Task #26 — scaffold ........................................ done
  Task #27 — narrow metadataThatTriggersRepublish ............ done
  Task #29 — connection settings UI + Immich auth ............ done
  Task #28 — processRenderedPhotos (full-upload routing) ..... done
  Task #31 — metadata-only API routing ....................... DEFERRED
------------------------------------------------------------------------------]]

local LrView          = import 'LrView'
local LrTasks         = import 'LrTasks'
local LrHttp          = import 'LrHttp'
local LrDialogs       = import 'LrDialogs'
local LrPasswords     = import 'LrPasswords'
local LrPathUtils     = import 'LrPathUtils'
local LrFileUtils     = import 'LrFileUtils'
local LrDate          = import 'LrDate'
local LrApplication   = import 'LrApplication'

-- Single append-mode log at /tmp/lr-immich.log so every decision the plugin
-- makes is visible across publish sessions. `tail -f /tmp/lr-immich.log` to watch.
local LOG_PATH = '/tmp/lr-immich.log'
local function log(msg)
    local f = io.open(LOG_PATH, 'a')
    if f then
        f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' [v0.8.0] ' .. tostring(msg) .. '\n')
        f:close()
    end
end
log('---- plugin module loaded ----')

local provider = {}

provider.supportsIncrementalPublish = 'only'

-- Plugin icon — Darkroom Log's "DR" film-reel mark. Shows next to
-- "Immich (lr-immich)" in the Publish Services panel header.
provider.small_icon = 'darkroom-icon.png'

-- IMPORTANT: immichApiKey is NOT in exportPresetFields. That's deliberate.
-- LR persists every declared exportPresetField as plaintext to
-- AgLibraryPublishedCollectionContent. Declaring immichApiKey there leaks the
-- API key into the catalog SQLite file. Instead we keep the key only in the
-- macOS keychain via LrPasswords (indexed by immichBaseUrl) and load it into
-- propertyTable at dialog-open time. The UI binds to that ephemeral
-- propertyTable.immichApiKey field, which never gets written to the catalog
-- because LR's persistence is scoped to exportPresetFields.
provider.exportPresetFields = {
    { key = 'immichBaseUrl',   default = '' },
    { key = 'immichLibraryId', default = '' },
    { key = 'immichDeviceId',  default = 'lr-immich' },
    { key = 'darkroomBaseUrl', default = '' },
}

provider.hideSections = {
    'exportLocation',
    'fileNaming',
    'video',
    'watermarking',
}

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function normalizeUrl(url)
    if not url then return '' end
    return (url:gsub('/+$', ''))
end

local function passwordKeyFor(url)
    return 'lr-immich:' .. normalizeUrl(url)
end

local function getApiKey(publishSettings)
    -- Always read from the keychain. The propertyTable at publish time
    -- does NOT contain immichApiKey because we don't declare it in
    -- exportPresetFields (catalog-leak avoidance). Only the dialog's
    -- live propertyTable holds it temporarily, and that's not what
    -- processRenderedPhotos receives.
    local url = publishSettings.immichBaseUrl
    if not url or url == '' then return nil end
    return LrPasswords.retrieve(passwordKeyFor(url))
end

----------------------------------------------------------------------------
-- Task #27: narrow trigger blob
----------------------------------------------------------------------------
function provider.metadataThatTriggersRepublish(publishSettings)
    return {
        default     = false,
        keywords    = true,
        caption     = true,
        title       = true,
        gps         = true,
        gpsAltitude = true,
        dateCreated = true,
    }
end

----------------------------------------------------------------------------
-- Task #29: settings UI
----------------------------------------------------------------------------

local function testConnection(url, apiKey)
    LrTasks.startAsyncTask(function()
        url = normalizeUrl(url)
        if url == '' then
            LrDialogs.message('Immich', 'Set Server URL first.')
            return
        end
        if not apiKey or apiKey == '' then
            LrDialogs.message('Immich', 'Set API Key first.')
            return
        end
        local headers = { { field = 'x-api-key', value = apiKey } }
        local body, respHeaders = LrHttp.get(url .. '/api/server/about', headers, 10)
        local status = respHeaders and respHeaders.status
        if status == 200 then
            LrDialogs.message('Immich connection OK', body or '(empty body)')
        elseif status == 401 or status == 403 then
            LrDialogs.message('Immich auth FAILED',
                'HTTP ' .. tostring(status) .. ' — check the API key.\n\n' .. tostring(body or ''))
        else
            LrDialogs.message('Immich connection FAILED',
                'HTTP ' .. tostring(status or 'unknown') .. '\n\n' .. tostring(body or ''))
        end
    end)
end

function provider.sectionsForTopOfDialog(f, propertyTable)
    return {
        {
            title = 'Immich Connection',
            synopsis = function(props) return normalizeUrl(props.immichBaseUrl) end,

            f:row {
                spacing = f:label_spacing(),
                f:static_text { title = 'Server URL:', alignment = 'right', width = 100 },
                f:edit_field {
                    value = LrView.bind 'immichBaseUrl',
                    width_in_chars = 40,
                    placeholder_string = 'https://immich.example.com',
                    immediate = true,
                },
            },

            f:row {
                spacing = f:label_spacing(),
                f:static_text { title = 'API Key:', alignment = 'right', width = 100 },
                f:edit_field {
                    value = LrView.bind 'immichApiKey',
                    width_in_chars = 40,
                    placeholder_string = '(stored in keychain — not in catalog)',
                    immediate = true,
                },
            },

            f:row {
                spacing = f:label_spacing(),
                f:static_text { title = 'Library ID:', alignment = 'right', width = 100 },
                f:edit_field {
                    value = LrView.bind 'immichLibraryId',
                    width_in_chars = 40,
                    placeholder_string = '(optional — leave blank for default)',
                    immediate = true,
                },
            },

            f:row {
                spacing = f:label_spacing(),
                f:static_text { title = 'Darkroom URL:', alignment = 'right', width = 100 },
                f:edit_field {
                    value = LrView.bind 'darkroomBaseUrl',
                    width_in_chars = 40,
                    placeholder_string = 'https://your-darkroom.example.com  (optional — for title sync)',
                    immediate = true,
                },
            },

            f:row {
                spacing = f:label_spacing(),
                f:static_text { title = '', width = 100 },
                f:push_button {
                    title = 'Test Connection',
                    action = function()
                        testConnection(propertyTable.immichBaseUrl, propertyTable.immichApiKey)
                    end,
                },
            },
        },
    }
end

-- Populate the UI's immichApiKey field from the keychain at dialog-open.
-- This is the ONLY place propertyTable.immichApiKey gets set. It exists
-- in the propertyTable for the duration of the dialog (so the UI can
-- bind/display it), but is NOT in exportPresetFields, so LR won't
-- persist it to the catalog when the user clicks Save.
function provider.startDialog(propertyTable)
    local url = propertyTable.immichBaseUrl
    propertyTable.immichApiKey = ''
    if url and url ~= '' then
        propertyTable.immichApiKey = LrPasswords.retrieve(passwordKeyFor(url)) or ''
    end
end

-- On Save, write the (possibly edited) API key to the keychain.
function provider.endDialog(propertyTable, why)
    if why == 'ok' then
        local url = propertyTable.immichBaseUrl
        if url and url ~= '' then
            LrPasswords.store(passwordKeyFor(url), propertyTable.immichApiKey or '')
        end
    end
    -- Belt-and-suspenders: blank the propertyTable field even though LR
    -- shouldn't be persisting it (not in exportPresetFields).
    propertyTable.immichApiKey = ''
end

----------------------------------------------------------------------------
-- Task #28: full-upload routing
----------------------------------------------------------------------------

-- Build the multipart body LR's HTTP layer wants for an Immich asset
-- upload. Immich expects fields:
--   * assetData       (binary file)
--   * deviceAssetId   (unique string per device — we use originalFilename)
--   * deviceId        (string)
--   * fileCreatedAt   (ISO datetime)
--   * fileModifiedAt  (ISO datetime)
--   * isFavorite      (bool)
--   * libraryId       (UUID, optional)
local function buildMultipart(jpegPath, deviceId, libraryId, lrPhoto)
    local stat = LrFileUtils.fileAttributes(jpegPath)
    local mtimeIso = LrDate.timeToIsoDate(stat and stat.fileModificationDate or LrDate.currentTime())
    local createdAt = mtimeIso
    if lrPhoto then
        local captureTime = lrPhoto:getRawMetadata('dateTimeOriginal')
        if captureTime then
            createdAt = LrDate.timeToIsoDate(captureTime)
        end
    end

    local filename = LrPathUtils.leafName(jpegPath)
    local fields = {
        { name = 'deviceAssetId',  value = filename },
        { name = 'deviceId',       value = deviceId or 'lr-immich' },
        { name = 'fileCreatedAt',  value = createdAt },
        { name = 'fileModifiedAt', value = mtimeIso },
        { name = 'isFavorite',     value = 'false' },
        { name = 'assetData',
          fileName    = filename,
          filePath    = jpegPath,
          contentType = 'image/jpeg' },
    }
    if libraryId and libraryId ~= '' then
        table.insert(fields, { name = 'libraryId', value = libraryId })
    end
    return fields
end

-- Post a new asset to Immich. Returns (uuid, errMsg).
local function uploadNew(publishSettings, jpegPath, lrPhoto)
    local url = normalizeUrl(publishSettings.immichBaseUrl)
    local apiKey = getApiKey(publishSettings)
    if url == '' or not apiKey or apiKey == '' then
        return nil, 'Immich URL or API key not configured.'
    end

    local headers = {
        { field = 'x-api-key', value = apiKey },
        { field = 'Accept',    value = 'application/json' },
    }
    local fields = buildMultipart(jpegPath, publishSettings.immichDeviceId,
                                   publishSettings.immichLibraryId, lrPhoto)
    local body, respHeaders = LrHttp.postMultipart(url .. '/api/assets', fields, headers)
    local status = respHeaders and respHeaders.status
    if status == 200 or status == 201 then
        -- Body is JSON like {"id":"<uuid>","duplicate":false}. Parse minimally.
        local uuid = body and body:match('"id"%s*:%s*"([^"]+)"')
        if uuid then return uuid, nil end
        return nil, 'Upload returned HTTP ' .. tostring(status) .. ' but no asset id in body:\n' .. tostring(body)
    end
    return nil, 'Upload FAILED — HTTP ' .. tostring(status or 'unknown') .. '\n' .. tostring(body or '')
end

-- Wrap a value in single quotes for safe shell interpolation.
-- Replaces each single quote with the 4-char sequence '\'' (close, escape, literal, open).
local function shellEscape(s)
    if s == nil then return "''" end
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

----------------------------------------------------------------------------
-- Signature sidecar store (v0.6.1)
--
-- Replaces v0.5.0–v0.6.0's setPropertyForPlugin approach, which hit
-- SQLITE_BUSY_SNAPSHOT (error 517) whenever LR's connection had a stale
-- snapshot from our prior sqlite3 flag-clear. The catalog writes from
-- LR's withWriteAccessDo then conflict and either lock up LR's UI or
-- silently drop the signature save.
--
-- Sidecar lives at ~/Library/Application Support/lr-immich/signatures.lua
-- and is a single Lua return-table indexed by photo localIdentifier
-- (number) → signature string. Loaded once per LR session, written on
-- every successful publish.
--
-- Tradeoff vs catalog-stored: doesn't survive catalog backup/restore
-- and is per-user-per-Mac (not portable). Worst case after a restore
-- is "fall back to REPLACE path on next publish" — which is what we'd
-- do anyway for any photo we haven't signed yet.
----------------------------------------------------------------------------

local SIG_DIR  = LrPathUtils.standardizePath('~/Library/Application Support/lr-immich')
local SIG_PATH = LrPathUtils.child(SIG_DIR, 'signatures.lua')

local _sigCache = nil

local function loadSignatures()
    if _sigCache then return _sigCache end
    _sigCache = {}
    local f = io.open(SIG_PATH, 'r')
    if not f then
        log('  signatures: no sidecar at ' .. SIG_PATH .. ' (first run is OK)')
        return _sigCache
    end
    local content = f:read('*a') or ''
    f:close()
    -- dofile-equivalent in memory. Don't use dofile() because we want
    -- explicit error trapping without yielding-in-pcall risk.
    local chunk, err = loadstring(content, 'signatures-sidecar')
    if not chunk then
        log('  signatures: parse failed (' .. tostring(err) .. '); starting empty')
        return _sigCache
    end
    local ok, data = pcall(chunk)
    if ok and type(data) == 'table' then
        _sigCache = data
        local n = 0; for _ in pairs(data) do n = n + 1 end
        log(string.format('  signatures: loaded %d entries from sidecar', n))
    else
        log('  signatures: sidecar returned non-table; starting empty')
    end
    return _sigCache
end

local function saveSignatures()
    if not _sigCache then return true end
    -- Ensure parent dir exists. Use mkdir -p via shell — LR's
    -- LrFileUtils.createAllDirectories may yield in weird contexts.
    LrTasks.execute('/bin/mkdir -p ' .. shellEscape(SIG_DIR))

    local f, err = io.open(SIG_PATH, 'w')
    if not f then
        log('  signatures: write FAILED — ' .. tostring(err))
        return false
    end
    f:write('-- lr-immich signatures sidecar. Auto-generated; do not edit by hand.\n')
    f:write('-- Indexed by LR photo localIdentifier (number).\n')
    f:write('return {\n')
    -- Stable order helps human-diffing if anyone opens this file.
    local keys = {}
    for k in pairs(_sigCache) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        f:write(string.format('  [%d] = %q,\n', k, _sigCache[k]))
    end
    f:write('}\n')
    f:close()
    return true
end

local function getSignature(photoId)
    if not photoId then return nil end
    return loadSignatures()[photoId]
end

local function setSignature(photoId, sig)
    if not photoId or not sig then return end
    loadSignatures()[photoId] = sig
end

----------------------------------------------------------------------------
-- curl helper (v0.6.1)
--
-- Returns (httpStatusCode, responseBody). On network/curl error returns
-- (0, errorText). Crucially this is NOT `curl -f` — v0.6.0 used -f and
-- discarded HTTP-4xx response bodies, which cost us hours diagnosing
-- "exit 56 HTTP 400" without seeing Immich's actual error message.
----------------------------------------------------------------------------

local function curlJson(method, url, apiKey, jsonBody)
    local bodyPath   = '/tmp/lr-immich-curl-body.txt'
    local statusPath = '/tmp/lr-immich-curl-status.txt'

    -- Clear last call's body so a missing -o write doesn't leak old data.
    local cf = io.open(bodyPath, 'w'); if cf then cf:close() end

    local args = {
        'curl', '-sS', '--max-time', '30',
        '-X', method,
        '-H', shellEscape('x-api-key: ' .. apiKey),
        '-H', shellEscape('Accept: application/json'),
    }
    if jsonBody then
        args[#args + 1] = '-H'
        args[#args + 1] = shellEscape('Content-Type: application/json')
        args[#args + 1] = '-d'
        args[#args + 1] = shellEscape(jsonBody)
    end
    args[#args + 1] = '-o'
    args[#args + 1] = shellEscape(bodyPath)
    args[#args + 1] = '-w'
    args[#args + 1] = shellEscape('%{http_code}')
    args[#args + 1] = shellEscape(url)
    args[#args + 1] = '>'
    args[#args + 1] = shellEscape(statusPath)
    args[#args + 1] = '2>&1'

    local rc = LrTasks.execute(table.concat(args, ' '))

    local statusCode = 0
    do
        local sf = io.open(statusPath, 'r')
        if sf then
            local raw = sf:read('*a') or ''
            sf:close()
            statusCode = tonumber(raw:match('(%d+)')) or 0
        end
    end

    local body = ''
    do
        local bf = io.open(bodyPath, 'r')
        if bf then
            body = bf:read('*a') or ''
            bf:close()
        end
    end

    if rc ~= 0 and statusCode == 0 then
        return 0, string.format('curl exit %d', rc)
    end
    return statusCode, body
end

-- Replace the binary of an existing asset (UUID preserved). Returns (true, nil) or (false, err).
--
-- LR SDK gotcha: LrHttp.postMultipart's 4th arg is timeoutInSeconds, NOT a method override.
-- Passing 'PUT' there gets silently coerced/ignored and the call still POSTs. Immich's
-- /api/assets/<id>/original endpoint REQUIRES PUT — POST gets treated as a new upload and
-- creates a +1 duplicate. So we shell out to curl, which speaks multipart PUT natively.
local function replaceExisting(publishSettings, jpegPath, remoteId, lrPhoto)
    local url = normalizeUrl(publishSettings.immichBaseUrl)
    local apiKey = getApiKey(publishSettings)
    if url == '' or not apiKey or apiKey == '' then
        return false, 'Immich URL or API key not configured.'
    end

    local filename = LrPathUtils.leafName(jpegPath)
    local stat = LrFileUtils.fileAttributes(jpegPath)
    local mtimeIso = LrDate.timeToIsoDate(stat and stat.fileModificationDate or LrDate.currentTime())
    local createdAt = mtimeIso
    if lrPhoto then
        local captureTime = lrPhoto:getRawMetadata('dateTimeOriginal')
        if captureTime then
            createdAt = LrDate.timeToIsoDate(captureTime)
        end
    end
    local deviceId = publishSettings.immichDeviceId or 'lr-immich'

    -- Capture curl's output so we can surface real error messages, not just exit codes.
    local logPath = LrPathUtils.standardizePath('/tmp/lr-immich-curl.log')

    local cmd = table.concat({
        'curl', '-sS', '-f', '--max-time', '120',
        '-X', 'PUT',
        '-H', shellEscape('x-api-key: ' .. apiKey),
        '-F', shellEscape('assetData=@' .. jpegPath),
        '-F', shellEscape('deviceAssetId=lr-replace-' .. filename),
        '-F', shellEscape('deviceId='      .. deviceId),
        '-F', shellEscape('fileCreatedAt=' .. createdAt),
        '-F', shellEscape('fileModifiedAt='.. mtimeIso),
        shellEscape(url .. '/api/assets/' .. remoteId .. '/original'),
        '>', shellEscape(logPath), '2>&1',
    }, ' ')

    local rc = LrTasks.execute(cmd)
    if rc == 0 then
        return true, nil
    end
    -- Read curl output for diagnostics
    local detail = ''
    local f = io.open(logPath, 'r')
    if f then detail = f:read('*a') or ''; f:close() end
    -- curl exit codes: 22 = HTTP >= 400, 28 = timeout, 7 = connection refused, 6 = DNS, etc.
    return false, string.format(
        'PUT /api/assets/%s/original failed (curl exit %d).\n%s',
        remoteId, rc, detail)
end

----------------------------------------------------------------------------
-- Task #31: metadata-only routing
--
-- Goal: when a photo is flagged for republish but the rendered JPEG bytes
-- would be IDENTICAL to what's on Immich, skip the slow JPEG upload and
-- just PATCH the metadata (caption, GPS, dateCreated).
--
-- Detection: store a "publish signature" per photo via plugin metadata
-- (see metadataProvider.lua). Signature = serialized develop settings +
-- sorted keyword list. If those two are unchanged since last successful
-- publish, the JPEG re-render produces functionally identical bytes
-- (modulo non-deterministic EXIF timestamps Immich ignores).
--
-- On first publish of any pre-v0.5.0 photo, the signature is nil — so
-- we take the full-upload path and record the signature. Subsequent
-- caption/GPS/dateCreated edits then take the cheap PATCH path.
----------------------------------------------------------------------------

-- Recursively serialize a value into a deterministic string for signature
-- comparison. Sorts table keys so iteration order can't change the result.
local function serializeForSig(v)
    local t = type(v)
    if t == 'table' then
        local keys = {}
        for k in pairs(v) do keys[#keys+1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts+1] = k .. '=' .. serializeForSig(v[k])
        end
        return '{' .. table.concat(parts, ',') .. '}'
    elseif t == 'string' then
        return string.format('%q', v)
    elseif t == 'nil' then
        return 'nil'
    else
        return tostring(v)
    end
end

-- Compute the publish signature for a photo. If this equals the stored
-- signature from last publish, the rendered JPEG bytes are unchanged —
-- caption/GPS/dateCreated/keywords might have changed but we handle
-- those via the Immich API (metadata PATCH + tag sync) without
-- re-uploading.
--
-- v0.6.0 narrowing: signature is develop-settings-only. v0.5.0 also
-- included the sorted keyword list, forcing a full upload on keyword
-- edits so the new EXIF would land in Immich. v0.6.0 syncs LR keywords
-- to Immich's tag system via the API instead, so keyword changes can
-- take the fast path too.
local function computeSignature(photo)
    local develop = photo:getDevelopSettings() or {}
    return 'D:' .. serializeForSig(develop)
end

-- Get the photo's exportable keyword list — LR resolves containing-
-- keywords and respects the per-keyword "Include on Export" flag. This
-- is what would normally land in the JPEG's EXIF on export, so it's the
-- right authority for what tags should be on the Immich asset.
local function getKeywordList(photo)
    local raw = photo:getFormattedMetadata('keywordTagsForExport') or ''
    local list = {}
    for kw in raw:gmatch('([^,]+)') do
        kw = kw:gsub('^%s+', ''):gsub('%s+$', '')
        if kw ~= '' then
            list[#list + 1] = kw
        end
    end
    return list
end

-- Minimal JSON-string escape. Caption/title strings are UTF-8 already and
-- JSON accepts raw UTF-8, so we don't need \uXXXX escapes — only backslash,
-- quote, and common control chars. Defined here (rather than near
-- patchMetadata where it was in v0.5.x) so syncTags below can reference it
-- — Lua local-function lookup is lexical-at-definition-time, not at-call.
local function jsonString(s)
    if s == nil then return '""' end
    s = tostring(s)
        :gsub('\\', '\\\\')
        :gsub('"', '\\"')
        :gsub('\n', '\\n')
        :gsub('\r', '\\r')
        :gsub('\t', '\\t')
    return '"' .. s .. '"'
end

-- Fetch ALL tags in the user's Immich account. Returns nameToId map.
-- v0.6.1 corrected: there's no /api/tags/upsert endpoint (that was a
-- v0.6.0 fabrication). Real Immich shape is GET /api/tags returning
-- a flat array of {id, name, value, ...}. We fetch once per publish
-- run and cache for the duration.
local function fetchAllTags(url, apiKey)
    local status, body = curlJson('GET', url .. '/api/tags', apiKey, nil)
    if status ~= 200 then
        return nil, string.format('GET /api/tags status=%d body=%s', status, body)
    end
    local nameToId = {}
    for tagJson in body:gmatch('(%b{})') do
        local tid = tagJson:match('"id"%s*:%s*"([^"]+)"')
        local tname = tagJson:match('"name"%s*:%s*"([^"]+)"')
        if tid and tname then
            nameToId[tname] = tid
        end
    end
    return nameToId
end

-- Create a single tag in Immich. Returns tag id on success.
-- POST /api/tags {name: "..."} → 201 with {id, name, value, ...}
local function createTag(url, apiKey, name)
    local body = '{"name":' .. jsonString(name) .. '}'
    local status, resp = curlJson('POST', url .. '/api/tags', apiKey, body)
    if status ~= 200 and status ~= 201 then
        return nil, string.format('POST /api/tags name=%q status=%d body=%s',
            name, status, resp)
    end
    local id = resp:match('"id"%s*:%s*"([^"]+)"')
    if not id then
        return nil, string.format('POST /api/tags returned no id, body=%s', resp)
    end
    return id
end

-- Sync the photo's LR keywords to the Immich asset's tags (Option A:
-- mirror — adds AND removes). Returns (ok, errOrSummary, addedN, removedN).
--
-- v0.6.1 uses the REAL Immich tag API (v0.6.0 used a fabricated
-- /api/tags/upsert endpoint that 400'd every time):
--   GET    /api/tags            — list all user tags (cached via globalTagCache)
--   POST   /api/tags            — create a tag {name}
--   PUT    /api/tags/{id}/assets   — link asset(s) to tag {ids: [...]}
--   DELETE /api/tags/{id}/assets   — unlink asset(s) from tag {ids: [...]}
--
-- Caveat (Option A): this nukes tags Jacob added directly in the Immich
-- web UI / iOS app. Don't tag from the Immich side; tag from LR.
local function syncTags(url, apiKey, remoteId, lrKeywords, globalTagCache)
    -- 1. GET current Immich tags on THIS asset.
    local assetStatus, assetBody =
        curlJson('GET', url .. '/api/assets/' .. remoteId, apiKey, nil)
    if assetStatus ~= 200 then
        return false, string.format('GET /api/assets/%s status=%d body=%s',
            remoteId, assetStatus, assetBody)
    end

    local currentByName = {}
    local tagsBlock = assetBody:match('"tags"%s*:%s*(%b[])')
    if tagsBlock then
        local inner = tagsBlock:sub(2, -2)
        for tagJson in inner:gmatch('(%b{})') do
            local tid = tagJson:match('"id"%s*:%s*"([^"]+)"')
            local tname = tagJson:match('"name"%s*:%s*"([^"]+)"')
            if tid and tname then
                currentByName[tname] = tid
            end
        end
    end

    -- 2. Build desired set from LR.
    local desiredByName = {}
    for _, kw in ipairs(lrKeywords) do
        desiredByName[kw] = true
    end

    -- 3. Diff.
    local toAddNames = {}
    local toRemoveIds = {}
    for name in pairs(desiredByName) do
        if not currentByName[name] then
            toAddNames[#toAddNames + 1] = name
        end
    end
    for name, tid in pairs(currentByName) do
        if not desiredByName[name] then
            toRemoveIds[#toRemoveIds + 1] = tid
        end
    end

    if #toAddNames == 0 and #toRemoveIds == 0 then
        return true, 'no tag changes', 0, 0
    end

    -- 4. Adds: ensure tag exists (via cache + POST if missing), then link.
    --
    -- v0.6.4: 400 "A tag with that name already exists" recovery.
    -- Immich's IPTC parser asynchronously creates tags during multipart
    -- uploads — so by the time syncTags runs after UPLOAD-NEW, our
    -- globalTagCache (fetched at publish start) is stale and POST
    -- /api/tags returns 400 for any keyword Immich just auto-imported.
    -- v0.6.3 aborted the whole sync on first 400; v0.6.4 detects the
    -- specific "already exists" error, refreshes the cache once, and
    -- continues.
    local cacheRefreshed = false
    for _, name in ipairs(toAddNames) do
        local tagId = globalTagCache[name]
        if not tagId then
            local newId, err = createTag(url, apiKey, name)
            if not newId then
                local isDup = tostring(err):find('already exists', 1, true) ~= nil
                if isDup and not cacheRefreshed then
                    -- Refresh cache from Immich — auto-imported tags will
                    -- now show up. Do this at most once per sync run.
                    local fresh = fetchAllTags(url, apiKey)
                    if fresh then
                        for k, v in pairs(fresh) do globalTagCache[k] = v end
                        cacheRefreshed = true
                        tagId = globalTagCache[name]
                    end
                end
                if not tagId then
                    return false, 'tag create failed: ' .. tostring(err)
                end
            else
                globalTagCache[name] = newId
                tagId = newId
            end
        end
        -- PUT /api/tags/{id}/assets — link the asset (idempotent on Immich).
        local linkBody = '{"ids":["' .. remoteId .. '"]}'
        local lStatus, lBody = curlJson(
            'PUT', url .. '/api/tags/' .. tagId .. '/assets', apiKey, linkBody)
        if lStatus ~= 200 and lStatus ~= 204 then
            return false, string.format(
                'tag link tag=%s status=%d body=%s', tagId, lStatus, lBody)
        end
    end

    -- 5. Removes.
    for _, tid in ipairs(toRemoveIds) do
        local rmBody = '{"ids":["' .. remoteId .. '"]}'
        local dStatus, dBody = curlJson(
            'DELETE', url .. '/api/tags/' .. tid .. '/assets', apiKey, rmBody)
        if dStatus ~= 200 and dStatus ~= 204 then
            return false, string.format(
                'tag unlink tag=%s status=%d body=%s', tid, dStatus, dBody)
        end
    end

    return true, 'tag sync ok', #toAddNames, #toRemoveIds
end

-- Push LR title to the Darkroom server. Immich's asset model has no title
-- field, so we use a parallel sidecar API on Darkroom. Called from all three
-- publish paths (metadata-only PATCH, REPLACE, UPLOAD-NEW) so the Darkroom
-- title index is always current regardless of which path the publish took.
--
-- Best-effort: any failure (Darkroom unreachable, wrong URL, missing config)
-- is logged but never bubbles up to fail the publish. Immich is the
-- authoritative store; title sync is a nice-to-have.
local function pushTitleToDarkroom(publishSettings, remoteId, lrPhoto)
    local drUrl = normalizeUrl(publishSettings.darkroomBaseUrl)
    if drUrl == '' then return end
    if not remoteId or remoteId == '' then return end
    if not lrPhoto then return end
    local apiKey = getApiKey(publishSettings)
    if not apiKey or apiKey == '' then return end
    local title = lrPhoto:getFormattedMetadata('title') or ''
    local body = '{"assetId":' .. jsonString(remoteId) .. ',"title":' .. jsonString(title) .. '}'
    local status, resp = curlJson('POST', drUrl .. '/api/lr-title', apiKey, body)
    if status == 200 or status == 204 then
        log(string.format('    ✓ darkroom title push: asset=%s title=%q', remoteId, title))
    else
        log(string.format('    ⚠ darkroom title push failed (best-effort): status=%d body=%s',
            status or 0, tostring(resp)))
    end
end

-- PATCH-style metadata-only update (Immich's PUT /api/assets/{id}). Pushes
-- caption/GPS/dateCreated to the existing asset without touching the bytes.
-- No trashed-shadow side effect (the shadow trick is /original-only).
local function patchMetadata(publishSettings, remoteId, lrPhoto)
    local url = normalizeUrl(publishSettings.immichBaseUrl)
    local apiKey = getApiKey(publishSettings)
    if url == '' or not apiKey or apiKey == '' then
        return false, 'Immich URL or API key not configured.'
    end

    local parts = {}

    local caption = lrPhoto:getFormattedMetadata('caption') or ''
    parts[#parts + 1] = '"description":' .. jsonString(caption)

    local gps = lrPhoto:getRawMetadata('gps')
    if gps and gps.latitude and gps.longitude then
        parts[#parts + 1] = '"latitude":'  .. tostring(gps.latitude)
        parts[#parts + 1] = '"longitude":' .. tostring(gps.longitude)
    end

    local dateCreated = lrPhoto:getRawMetadata('dateTimeOriginal')
    if dateCreated then
        parts[#parts + 1] = '"dateTimeOriginal":' .. jsonString(LrDate.timeToIsoDate(dateCreated))
    end

    local body = '{' .. table.concat(parts, ',') .. '}'
    local status, resp = curlJson('PUT', url .. '/api/assets/' .. remoteId, apiKey, body)
    if status == 200 or status == 204 then
        return true, nil
    end
    return false, string.format(
        'PUT /api/assets/%s (metadata-only) status=%d body=%s',
        remoteId, status, resp)
end

function provider.processRenderedPhotos(functionContext, exportContext)
    log('processRenderedPhotos START')
    local exportSession = exportContext.exportSession
    local publishSettings = exportContext.propertyTable
    local baseUrl = normalizeUrl(publishSettings.immichBaseUrl)

    -- Fail fast if connection isn't configured.
    local apiKey = getApiKey(publishSettings)
    if baseUrl == '' or not apiKey or apiKey == '' then
        log('  ABORT: URL or API key missing')
        for _, rendition in exportSession:renditions() do
            rendition:waitForRender()
            rendition:uploadFailed('lr-immich: Server URL or API key not configured.')
        end
        return
    end

    local nPhotos = exportSession:countRenditions()
    log('  processing ' .. nPhotos .. ' rendition(s), baseUrl=' .. baseUrl)

    -- v0.6.5: count successes/failures per path so we can show an end-of-run
    -- bezel. Needed because LR's Publish Services panel caches its "Modified
    -- Photos to Re-Publish" grouping and lies about state until restart — the
    -- bezel is the user's only reliable signal that the publish actually went
    -- through.
    local cnMeta, cnReplace, cnUpload, cnFail = 0, 0, 0, 0

    -- Fetch Immich's full tag list once at publish start. syncTags reuses
    -- this cache and updates it whenever it creates a new tag. Saves one
    -- GET /api/tags per photo (which would be wasteful on a 67-photo run).
    local globalTagCache = nil
    do
        local tags, err = fetchAllTags(baseUrl, apiKey)
        if tags then
            local n = 0; for _ in pairs(tags) do n = n + 1 end
            log(string.format('  tag cache: loaded %d existing Immich tags', n))
            globalTagCache = tags
        else
            log('  tag cache: GET /api/tags FAILED — tag sync will be skipped this run. err=' ..
                tostring(err))
            globalTagCache = nil
        end
    end

    -- Per-photo tag-sync wrapper. v0.6.0: every successful publish path
    -- (metadata-only, replace, upload-new) calls this to mirror LR
    -- keywords → Immich tags. Tag-sync failure logs but does NOT abort
    -- the publish — the photo's bytes/metadata still landed, the tags
    -- can retry on the next publish.
    local function doSyncTags(photo, remoteIdToUse, contextLabel)
        if not photo or not remoteIdToUse or remoteIdToUse == '' then return end
        if not globalTagCache then return end  -- cache fetch failed; skip
        local kws = getKeywordList(photo)
        local ok, msg, addedN, removedN =
            syncTags(baseUrl, apiKey, remoteIdToUse, kws, globalTagCache)
        if ok then
            log(string.format('    tag sync (%s): %s, added=%d removed=%d (lr_kw_count=%d)',
                contextLabel, tostring(msg), addedN or 0, removedN or 0, #kws))
        else
            log(string.format('    tag sync (%s) FAILED: %s', contextLabel, tostring(msg)))
        end
    end

    local progressScope = exportContext:configureProgress {
        title = nPhotos > 1
            and ('Publishing ' .. nPhotos .. ' photos to Immich')
            or  'Publishing 1 photo to Immich',
    }

    -- Resolve the LrPublishedCollection. v0.3.5's pcall wrappers triggered
    -- "Yielding is not allowed within a C or metamethod call" — the SDK
    -- methods yield internally and pcall creates a non-yieldable boundary.
    -- Call them directly. processRenderedPhotos is already in a yieldable
    -- context (LR's publish task), so this is fine.
    local publishedCollection = exportContext.publishedCollection
    log('  exportContext.publishedCollection: type=' .. type(publishedCollection))
    if publishedCollection then
        log('    name: ' .. tostring(publishedCollection:getName()))
    end

    -- Build (photo.localIdentifier → remoteId) lookup.
    -- v0.8.0: scan the ENTIRE publish service, not just the collection being
    -- published. LR tracks published-state per collection, so a photo synced
    -- through one collection (e.g. the default 'z8-immich') has no published
    -- record in a sibling smart collection ('tag-z8-immich'). Without this,
    -- publishing the smart collection would route already-synced photos to
    -- UPLOAD-NEW and duplicate them in Immich. Harvesting every collection in
    -- the service lets us find the existing remoteId wherever it lives, route
    -- the photo to metadata-only/replace (UUID preserved), and let LR record
    -- the published-state in the current collection via recordPublishedPhotoId.
    local remoteIdByPhotoId = {}
    local cachedCount = 0

    -- Pull (photo → remoteId) from one collection into the lookup. First
    -- writer wins, so the collection being published is harvested first and
    -- its own remoteIds take precedence over a sibling's.
    local function harvest(coll, label)
        if not coll then return end
        local pubPhotos = coll:getPublishedPhotos()
        local added = 0
        for _, pp in ipairs(pubPhotos) do
            local p = pp:getPhoto()
            local rid = pp:getRemoteId()
            if p and rid and rid ~= '' then
                local key = p.localIdentifier or 0
                if not remoteIdByPhotoId[key] then
                    remoteIdByPhotoId[key] = rid
                    cachedCount = cachedCount + 1
                    added = added + 1
                end
            end
        end
        log(string.format('  harvested %d new remoteIds from %q (%d published rows)',
            added, tostring(label), #pubPhotos))
    end

    -- Recursively gather every published collection under a service/set node.
    -- Call the SDK methods directly (no pcall) — they yield internally and a
    -- pcall boundary triggers "Yielding is not allowed within a C call".
    local function gatherCollections(node, acc)
        local colls = node:getChildCollections()
        if colls then for _, c in ipairs(colls) do acc[#acc + 1] = c end end
        local sets = node:getChildCollectionSets()
        if sets then for _, s in ipairs(sets) do gatherCollections(s, acc) end end
    end

    if publishedCollection then
        harvest(publishedCollection, publishedCollection:getName())  -- current first
        local service = publishedCollection:getService()
        if service then
            local all = {}
            gatherCollections(service, all)
            for _, c in ipairs(all) do
                if c.localIdentifier ~= publishedCollection.localIdentifier then
                    harvest(c, c:getName())
                end
            end
        end
    end
    log('  cached ' .. cachedCount .. ' photoId→remoteId mappings (service-wide)')

    -- Accumulate successfully-replaced photo ids; we'll clear their
    -- photoNeedsUpdating flags in ONE sqlite3 call after the loop ends.
    -- v0.4.0 ran sqlite3 per-photo, which contended with LR's own writes
    -- on the catalog (history-step inserts, etc.) and caused "database is
    -- locked" errors mid-publish on batches > ~5 photos. Single batched
    -- call at the end takes a brief lock once instead of N times.
    local clearedPhotoIds = {}

    -- Track count for the post-loop log. Signatures themselves are
    -- written immediately into the sidecar's in-memory cache on each
    -- successful publish, then flushed to disk in one io.open(...,'w')
    -- call after the loop. Metadata-only path doesn't update signatures
    -- (by definition unchanged).
    local sigsSetCount = 0

    local renditionIndex = 0

    for _, rendition in exportSession:renditions() do
        if progressScope:isCanceled() then break end

        -- Update progress bar BEFORE rendering — gives "X of N" feedback
        -- before the slow render+upload step on the current photo.
        progressScope:setPortionComplete(renditionIndex, nPhotos)

        local success, pathOrMsg = rendition:waitForRender()
        if not success then
            log('  render FAILED: ' .. tostring(pathOrMsg))
            rendition:uploadFailed(tostring(pathOrMsg))
        else
            local jpegPath  = pathOrMsg
            local photo     = rendition.photo
            local photoId   = photo and photo.localIdentifier or nil
            local publishedPhoto = rendition.publishedPhoto
            local remoteId  = publishedPhoto and publishedPhoto:getRemoteId() or nil
            local photoName = photo and photo:getFormattedMetadata('fileName') or '?'
            log(string.format('  rendition: photo=%s photoId=%s | publishedPhoto=%s | remoteId=%s',
                photoName, tostring(photoId),
                tostring(publishedPhoto ~= nil), tostring(remoteId)))

            -- Fallback: if rendition.publishedPhoto didn't give us a remoteId,
            -- look it up via the publishedCollection's published-photos table
            -- which we cached above.
            if (not remoteId or remoteId == '') and photoId then
                local fallback = remoteIdByPhotoId[photoId]
                if fallback then
                    log('    fallback lookup: photoId ' .. tostring(photoId) .. ' → remoteId ' .. fallback)
                    remoteId = fallback
                else
                    log('    fallback lookup: photoId ' .. tostring(photoId) .. ' NOT found in publishedCollection table')
                end
            end

            -- Decide path: metadata-only vs full upload. Only meaningful
            -- for republishes (we have a remoteId AND a previously-stored
            -- signature to compare against).
            -- v0.6.1: signatures live in a sidecar Lua file (see SIG_PATH
            -- and getSignature/setSignature). v0.5.0–v0.6.0 stored them via
            -- setPropertyForPlugin, which hit SQLITE_BUSY_SNAPSHOT 517
            -- when LR's connection had a stale snapshot from our prior
            -- sqlite3 flag-clear.
            local currentSig, storedSig
            if photo and remoteId and remoteId ~= '' then
                currentSig = computeSignature(photo)
                storedSig  = getSignature(photoId)
                local sigMatch = (storedSig ~= nil and storedSig ~= '' and storedSig == currentSig)
                log(string.format('    signature: stored=%s current_len=%d match=%s',
                    storedSig and ('len=' .. #storedSig) or 'nil',
                    #currentSig, tostring(sigMatch)))
            end

            if remoteId and remoteId ~= '' and storedSig and storedSig == currentSig then
                -- METADATA-ONLY PATH. JPEG was rendered but we throw it
                -- away — render is cheap (~1-2s), upload is the slow part
                -- (~10-30s) and that's what we skip. No shadow created on
                -- Immich either (PUT /api/assets/{id} doesn't trash the
                -- existing file, unlike /api/assets/{id}/original).
                log('    → METADATA-ONLY path (PUT /api/assets/' .. remoteId .. ')')
                local ok, err = patchMetadata(publishSettings, remoteId, photo)
                if ok then
                    log('    ✓ metadata patch succeeded')
                    doSyncTags(photo, remoteId, 'metadata-only')
                    pushTitleToDarkroom(publishSettings, remoteId, photo)
                    rendition:recordPublishedPhotoId(remoteId)
                    rendition:recordPublishedPhotoUrl(baseUrl .. '/photos/' .. remoteId)
                    if photoId then
                        clearedPhotoIds[#clearedPhotoIds + 1] = photoId
                    end
                    -- Don't re-save signature: it's unchanged by definition.
                    cnMeta = cnMeta + 1
                else
                    log('    ✗ metadata patch failed: ' .. tostring(err))
                    rendition:uploadFailed(err)
                    cnFail = cnFail + 1
                end
            elseif remoteId and remoteId ~= '' then
                -- REPLACE PATH — develop or keywords changed, or first
                -- post-v0.5.0 publish for a photo that has no signature yet.
                log('    → REPLACE path (curl PUT to /api/assets/' .. remoteId .. '/original)')
                local ok, err = replaceExisting(publishSettings, jpegPath, remoteId, photo)
                if ok then
                    log('    ✓ replace succeeded, recording remoteId+url')
                    doSyncTags(photo, remoteId, 'replace')
                    pushTitleToDarkroom(publishSettings, remoteId, photo)
                    rendition:recordPublishedPhotoId(remoteId)
                    rendition:recordPublishedPhotoUrl(baseUrl .. '/photos/' .. remoteId)
                    if photoId then
                        clearedPhotoIds[#clearedPhotoIds + 1] = photoId
                        setSignature(photoId, currentSig)
                        sigsSetCount = sigsSetCount + 1
                    end
                    cnReplace = cnReplace + 1
                else
                    log('    ✗ replace failed: ' .. tostring(err))
                    rendition:uploadFailed(err)
                    cnFail = cnFail + 1
                end
            else
                -- UPLOAD-NEW PATH — first time this photo is sent to Immich.
                log('    → UPLOAD-NEW path (POST /api/assets) — no remoteId on rendition')
                local uuid, err = uploadNew(publishSettings, jpegPath, photo)
                if uuid then
                    doSyncTags(photo, uuid, 'upload-new')
                    pushTitleToDarkroom(publishSettings, uuid, photo)
                    rendition:recordPublishedPhotoId(uuid)
                    rendition:recordPublishedPhotoUrl(baseUrl .. '/photos/' .. uuid)
                    if photoId then
                        currentSig = currentSig or computeSignature(photo)
                        setSignature(photoId, currentSig)
                        sigsSetCount = sigsSetCount + 1
                    end
                    cnUpload = cnUpload + 1
                else
                    rendition:uploadFailed(err)
                    cnFail = cnFail + 1
                end
            end
        end

        renditionIndex = renditionIndex + 1
        progressScope:setPortionComplete(renditionIndex, nPhotos)
    end

    -- Batched flag-clear AFTER the loop. One sqlite3 call total, regardless
    -- of batch size. -cmd ".timeout 30000" makes sqlite3 wait politely up
    -- to 30s if LR holds the write lock. BEGIN IMMEDIATE asks for the
    -- writer slot cleanly under WAL mode so we queue properly behind any
    -- in-flight LR writes instead of racing.
    if #clearedPhotoIds > 0 then
        local catalog = LrApplication.activeCatalog()
        local catalogPath = catalog:getPath()
        local collId = publishedCollection and publishedCollection.localIdentifier or nil
        if catalogPath and collId then
            local ids = table.concat(clearedPhotoIds, ',')
            local sql = 'BEGIN IMMEDIATE;'
                     .. ' UPDATE AgRemotePhoto SET photoNeedsUpdating = 0'
                     .. ' WHERE collection = ' .. collId
                     .. ' AND photo IN (' .. ids .. ');'
                     .. ' COMMIT;'
            local cmd = string.format(
                '/usr/bin/sqlite3 -cmd %s %s %s',
                shellEscape('.timeout 30000'),
                shellEscape(catalogPath),
                shellEscape(sql))
            local rc = LrTasks.execute(cmd)
            log(string.format('  batched flag-clear: %d photos, rc=%d', #clearedPhotoIds, rc))
        else
            log('  skipped batched flag-clear — missing catalogPath or collId')
        end
    end

    -- Flush signatures to sidecar file. v0.6.1: no LR catalog writes,
    -- so no lock contention with our prior sqlite3 flag-clear and no
    -- 517 errors. One io.open(...,'w'); the whole signature table gets
    -- rewritten on each publish.
    if sigsSetCount > 0 then
        local ok = saveSignatures()
        if ok then
            local n = 0; for _ in pairs(loadSignatures()) do n = n + 1 end
            log(string.format('  signatures flushed to sidecar: %d new, %d total',
                sigsSetCount, n))
        else
            log('  signatures sidecar write FAILED (see preceding error)')
        end
    end

    progressScope:done()

    -- End-of-run summary. Bezel for any normal completion (transient toast
    -- in LR's UI); modal dialog when there were failures so the user can't
    -- miss them.
    local parts = {}
    if cnMeta    > 0 then parts[#parts+1] = string.format('%d metadata', cnMeta) end
    if cnReplace > 0 then parts[#parts+1] = string.format('%d replaced', cnReplace) end
    if cnUpload  > 0 then parts[#parts+1] = string.format('%d new',      cnUpload) end
    local summary = #parts > 0 and table.concat(parts, ' · ') or 'nothing published'
    if cnFail > 0 then summary = summary .. string.format(' · %d FAILED', cnFail) end
    log('Summary: ' .. summary)
    LrDialogs.showBezel('lr-immich ✓ ' .. summary, 5)
    if cnFail > 0 then
        LrDialogs.message('lr-immich',
            string.format('%d photo(s) failed to publish. Check the log for details:\n%s',
                cnFail, LOG_PATH),
            'warning')
    end
end

----------------------------------------------------------------------------
-- Optional: let users click on a published photo in LR and open it in
-- the Immich web UI.
----------------------------------------------------------------------------
function provider.goToPublishedPhoto(publishSettings, info)
    if info.remoteUrl then
        LrHttp.openUrlInBrowser(info.remoteUrl)
    end
end

return provider
