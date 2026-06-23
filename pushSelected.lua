--[[----------------------------------------------------------------------------
pushSelected.lua — Library → Plug-in Extras menu item

Re-publish the currently-selected (already-published) photos to Immich
immediately, bypassing the publish-service queue. Useful when you've made
caption / GPS / keyword / dateCreated / develop edits on a handful of
already-published photos and want them on Immich without batch-publishing
whatever else is in the Modified queue.

v0.10.0 UPLOAD-ONLY: this re-renders each selected photo and re-uploads
the JPEG bytes via REPLACE (PUT /api/assets/{id}/original, preserving the
UUID). Immich extracts the embedded metadata (date/caption/GPS/keywords)
on upload with ZERO sidecar writes. The OLD path did a metadata-only
PUT /api/assets/{id} + /api/tags sync, which each queued a SidecarWrite
that wrote a bad .xmp — Immich read that sidecar in preference to the
embedded JPEG, corrupting dates to midnight and dropping tags. Never again.

Known UI quirk (NOT a bug — it's how LR's Publish Services view works):
  The photo will stay visually in "Modified Photos to Re-Publish" after
  this menu runs. LR caches its publish-service view state and doesn't
  refresh until restart, plugin reload, or collection-switch + back.
  The data IS correct (AgRemotePhoto.photoNeedsUpdating is 0) — just LR's
  UI displays stale state.

Limitations:
  1. Photo must already be published to Immich (need a UUID to REPLACE).
     Unpublished selections are skipped — use regular Publish for those.
  2. Re-renders bytes every time (no fast metadata-only path anymore) —
     that's the cost of never corrupting dates again.
  3. Multiple lr-immich publish services configured: uses the FIRST.
------------------------------------------------------------------------------]]

local LrApplication     = import 'LrApplication'
local LrTasks           = import 'LrTasks'
local LrHttp            = import 'LrHttp'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrPathUtils       = import 'LrPathUtils'
local LrDate            = import 'LrDate'
local LrPasswords       = import 'LrPasswords'
local LrFileUtils       = import 'LrFileUtils'        -- v0.10.0: buildMultipart fileAttributes
local LrExportSession   = import 'LrExportSession'    -- v0.10.0: re-render selected for full re-upload

local PLUGIN_ID = 'com.lakatua.lr-immich'
local LOG_PATH  = '/tmp/lr-immich.log'

local function log(msg)
    local f = io.open(LOG_PATH, 'a')
    if f then
        f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' [pushSelected/v0.10.0] ' .. tostring(msg) .. '\n')
        f:close()
    end
end

----------------------------------------------------------------------------
-- Helpers (mirrored from publishServiceProvider.lua — no require()-share)
----------------------------------------------------------------------------

local function normalizeUrl(url)
    if not url then return '' end
    return (url:gsub('/+$', ''))
end

local function passwordKeyFor(url)
    return 'lr-immich:' .. normalizeUrl(url)
end

local function shellEscape(s)
    if s == nil then return "''" end
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Run an external command, surviving the macOS fork()-on-child-side crash
-- (ObjC runtime isn't fork-safe; see publishServiceProvider.lua's note and
-- the 2026-06-08 incident). Retries on failure since the race is
-- intermittent and these commands (sqlite UPDATE, curl DELETE) are
-- idempotent. Returns the final rc. v0.9.0.
local function execResilient(cmd, label, tries)
    tries = tries or 3
    local rc = 0
    for attempt = 1, tries do
        rc = LrTasks.execute(cmd)
        if rc == 0 then
            if attempt > 1 then
                log(string.format('  execResilient[%s]: succeeded on attempt %d/%d',
                    tostring(label), attempt, tries))
            end
            return 0
        end
        log(string.format('  execResilient[%s]: attempt %d/%d rc=%d%s',
            tostring(label), attempt, tries, rc,
            attempt < tries and ' — retrying' or ' — giving up'))
        if attempt < tries then LrTasks.sleep(0.2 * attempt) end
    end
    return rc
end

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

local function serializeForSig(v)
    local t = type(v)
    if t == 'table' then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = k .. '=' .. serializeForSig(v[k])
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

local function computeSignature(photo)
    local develop = photo:getDevelopSettings() or {}
    return 'D:' .. serializeForSig(develop)
end

local function getKeywordList(photo)
    local raw = photo:getFormattedMetadata('keywordTagsForExport') or ''
    local list = {}
    for kw in raw:gmatch('([^,]+)') do
        kw = kw:gsub('^%s+', ''):gsub('%s+$', '')
        if kw ~= '' then list[#list + 1] = kw end
    end
    return list
end

----------------------------------------------------------------------------
-- Sidecar signature store (read-only here — only publishServiceProvider
-- writes the sidecar; pushSelected just reads to decide who qualifies).
----------------------------------------------------------------------------

local SIG_DIR  = LrPathUtils.standardizePath('~/Library/Application Support/lr-immich')
local SIG_PATH = LrPathUtils.child(SIG_DIR, 'signatures.lua')

local _sigCache = nil
local function loadSignatures()
    if _sigCache then return _sigCache end
    _sigCache = {}
    local f = io.open(SIG_PATH, 'r')
    if not f then return _sigCache end
    local content = f:read('*a') or ''
    f:close()
    local chunk, _ = loadstring(content, 'signatures-sidecar')
    if not chunk then return _sigCache end
    local ok, data = pcall(chunk)
    if ok and type(data) == 'table' then _sigCache = data end
    return _sigCache
end
local function getSignature(photoId)
    if not photoId then return nil end
    return loadSignatures()[photoId]
end

----------------------------------------------------------------------------
-- JSON API helper (v0.9.0 — native LrHttp, no fork).
--
-- Was a curl shell-out — every LR fork() to run curl could crash on the
-- child side (macOS ObjC runtime isn't fork-safe; the 2026-06-08 incident).
-- GET/POST/PUT now run in-process via LrHttp. DELETE-with-body (tag unlink)
-- stays on curl (curlJsonShell) because LrHttp's DELETE-body behavior is
-- unverified and Immich's unlink endpoint requires the body — wrapped in
-- execResilient so a fork-child crash retries. Same return contract:
-- (httpStatusCode, responseBody); (0, errText) on transport failure.
-- Mirrors publishServiceProvider.lua's curlJson.
----------------------------------------------------------------------------

local function curlJsonShell(method, url, apiKey, jsonBody)
    local bodyPath   = '/tmp/lr-immich-curl-body.txt'
    local statusPath = '/tmp/lr-immich-curl-status.txt'
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
    args[#args + 1] = '-o'; args[#args + 1] = shellEscape(bodyPath)
    args[#args + 1] = '-w'; args[#args + 1] = shellEscape('%{http_code}')
    args[#args + 1] = shellEscape(url)
    args[#args + 1] = '>'; args[#args + 1] = shellEscape(statusPath)
    args[#args + 1] = '2>&1'

    local rc = execResilient(table.concat(args, ' '), method .. ' (curl)')

    local statusCode = 0
    local sf = io.open(statusPath, 'r')
    if sf then
        local raw = sf:read('*a') or ''
        sf:close()
        statusCode = tonumber(raw:match('(%d+)')) or 0
    end
    local body = ''
    local bf = io.open(bodyPath, 'r')
    if bf then body = bf:read('*a') or ''; bf:close() end

    if rc ~= 0 and statusCode == 0 then
        return 0, string.format('curl exit %d', rc)
    end
    return statusCode, body
end

local function curlJson(method, url, apiKey, jsonBody)
    if method == 'DELETE' then
        return curlJsonShell(method, url, apiKey, jsonBody)
    end

    local headers = {
        { field = 'x-api-key', value = apiKey },
        { field = 'Accept',    value = 'application/json' },
    }

    local body, respHeaders
    if method == 'GET' then
        body, respHeaders = LrHttp.get(url, headers, 30)
    else
        headers[#headers + 1] = { field = 'Content-Type', value = 'application/json' }
        body, respHeaders = LrHttp.post(url, jsonBody or '', headers, method, 30)
    end

    if not respHeaders or respHeaders.error or respHeaders.status == nil then
        local e = respHeaders and respHeaders.error
        local errText = (e and (e.name or tostring(e.errorCode)))
            or 'LrHttp transport error'
        return 0, errText
    end
    return (tonumber(respHeaders.status) or 0), body or ''
end

----------------------------------------------------------------------------
-- Real Immich tag API
----------------------------------------------------------------------------

local function fetchAllTags(url, apiKey)
    local status, body = curlJson('GET', url .. '/api/tags', apiKey, nil)
    if status ~= 200 then
        return nil, string.format('GET /api/tags status=%d body=%s', status, body)
    end
    -- Key by tag "value" (full hierarchical path), NOT "name" (leaf).
    -- Immich treats "/" as a hierarchy separator, so "Summilux 35mm f/1.4
    -- FLE" has value=full-path, name=leaf. LR keywords match the value.
    -- (v0.9.1 — see publishServiceProvider.lua for the full writeup.)
    local valueToId = {}
    for tagJson in body:gmatch('(%b{})') do
        local tid    = tagJson:match('"id"%s*:%s*"([^"]+)"')
        local tvalue = tagJson:match('"value"%s*:%s*"([^"]+)"')
        if tid and tvalue then valueToId[tvalue] = tid end
    end
    return valueToId
end

local function createTag(url, apiKey, name)
    local body = '{"name":' .. jsonString(name) .. '}'
    local status, resp = curlJson('POST', url .. '/api/tags', apiKey, body)
    if status ~= 200 and status ~= 201 then
        return nil, string.format('POST /api/tags name=%q status=%d body=%s', name, status, resp)
    end
    local id = resp:match('"id"%s*:%s*"([^"]+)"')
    if not id then
        return nil, string.format('POST /api/tags returned no id, body=%s', resp)
    end
    return id
end

local function syncTags(url, apiKey, remoteId, lrKeywords, globalTagCache)
    local assetStatus, assetBody =
        curlJson('GET', url .. '/api/assets/' .. remoteId, apiKey, nil)
    if assetStatus ~= 200 then
        return false, string.format('GET /api/assets/%s status=%d body=%s',
            remoteId, assetStatus, assetBody)
    end

    -- Key current asset tags by "value" (full path) to match LR keywords
    -- and fetchAllTags. Assets carry only leaf/full tags, never structural
    -- parents, so the remove-diff stays correct. (v0.9.1)
    local currentByName = {}
    local tagsBlock = assetBody:match('"tags"%s*:%s*(%b[])')
    if tagsBlock then
        local inner = tagsBlock:sub(2, -2)
        for tagJson in inner:gmatch('(%b{})') do
            local tid    = tagJson:match('"id"%s*:%s*"([^"]+)"')
            local tvalue = tagJson:match('"value"%s*:%s*"([^"]+)"')
            if tid and tvalue then currentByName[tvalue] = tid end
        end
    end

    local desiredByName = {}
    for _, kw in ipairs(lrKeywords) do desiredByName[kw] = true end

    local toAddNames, toRemoveIds = {}, {}
    for name in pairs(desiredByName) do
        if not currentByName[name] then toAddNames[#toAddNames + 1] = name end
    end
    for name, tid in pairs(currentByName) do
        if not desiredByName[name] then toRemoveIds[#toRemoveIds + 1] = tid end
    end

    if #toAddNames == 0 and #toRemoveIds == 0 then
        return true, 'no tag changes', 0, 0
    end

    -- v0.9.2: per-tag resilience — one unresolvable tag must not drop the
    -- rest. Mirrors publishServiceProvider.lua's syncTags. Case-insensitive
    -- lookup (Immich tag uniqueness is case-insensitive) + refresh/retry on
    -- a 400 "already exists" + continue-on-failure.
    local failures = {}

    local function lookupTag(name)
        local id = globalTagCache[name]
        if id then return id end
        local lname = name:lower()
        for value, vid in pairs(globalTagCache) do
            if value:lower() == lname then return vid end
        end
        return nil
    end

    local refreshes = 0
    local function refreshCache()
        if refreshes >= 4 then return end
        refreshes = refreshes + 1
        local fresh = fetchAllTags(url, apiKey)
        if fresh then
            for k, v in pairs(fresh) do globalTagCache[k] = v end
        end
    end

    for _, name in ipairs(toAddNames) do
        local tagId = lookupTag(name)
        if not tagId then
            local newId, err = createTag(url, apiKey, name)
            if newId then
                globalTagCache[name] = newId
                tagId = newId
            elseif tostring(err):find('already exists', 1, true) then
                for attempt = 1, 3 do
                    refreshCache()
                    tagId = lookupTag(name)
                    if tagId then break end
                    LrTasks.sleep(1.0)
                end
                if not tagId then
                    failures[#failures + 1] = name
                    log(string.format('    tag sync: could not resolve %q after retries — skipping', name))
                end
            else
                failures[#failures + 1] = name
                log(string.format('    tag sync: create failed for %q (skipped): %s', name, tostring(err)))
            end
        end
        if tagId then
            local linkBody = '{"ids":["' .. remoteId .. '"]}'
            local lStatus, lBody =
                curlJson('PUT', url .. '/api/tags/' .. tagId .. '/assets', apiKey, linkBody)
            if lStatus ~= 200 and lStatus ~= 204 then
                failures[#failures + 1] = name
                log(string.format('    tag sync: link failed for %q (skipped): status=%d body=%s',
                    name, lStatus, tostring(lBody)))
            end
        end
    end

    for _, tid in ipairs(toRemoveIds) do
        local rmBody = '{"ids":["' .. remoteId .. '"]}'
        local dStatus, dBody =
            curlJson('DELETE', url .. '/api/tags/' .. tid .. '/assets', apiKey, rmBody)
        if dStatus ~= 200 and dStatus ~= 204 then
            log(string.format('    tag sync: unlink failed for tag=%s (skipped): status=%d body=%s',
                tid, dStatus, tostring(dBody)))
        end
    end

    if #failures > 0 then
        return false, string.format('linked %d/%d, could not resolve: %s',
            #toAddNames - #failures, #toAddNames, table.concat(failures, ', ')),
            #toAddNames - #failures, #toRemoveIds
    end
    return true, 'tag sync ok', #toAddNames, #toRemoveIds
end

local function patchMetadata(url, apiKey, remoteId, lrPhoto)
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
    if status == 200 or status == 204 then return true, nil end
    return false, string.format('PUT /api/assets/%s status=%d body=%s', remoteId, status, resp)
end

----------------------------------------------------------------------------
-- Main
----------------------------------------------------------------------------

-- v0.10.0 UPLOAD-ONLY upload helpers (ported from publishServiceProvider.lua,
-- adapted to explicit url/apiKey args). "Push Selected" now re-renders the
-- selected photos and re-uploads the bytes so Immich extracts the embedded
-- metadata (date/caption/GPS/keywords) — instead of the old metadata-only
-- PATCH + /api/tags sync, which each queued a SidecarWrite that wrote a bad
-- .xmp, corrupted dates to midnight, and dropped tags.
local function buildMultipart(jpegPath, deviceId, libraryId, lrPhoto)
    local stat = LrFileUtils.fileAttributes(jpegPath)
    local mtimeIso = LrDate.timeToIsoDate(stat and stat.fileModificationDate or LrDate.currentTime())
    local createdAt = mtimeIso
    if lrPhoto then
        local captureTime = lrPhoto:getRawMetadata('dateTimeOriginal')
        if captureTime then createdAt = LrDate.timeToIsoDate(captureTime) end
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

-- POST a new asset. Returns (uuid, errMsg).
local function uploadNewAsset(url, apiKey, deviceId, libraryId, jpegPath, lrPhoto)
    local headers = {
        { field = 'x-api-key', value = apiKey },
        { field = 'Accept',    value = 'application/json' },
    }
    local fields = buildMultipart(jpegPath, deviceId, libraryId, lrPhoto)
    local body, respHeaders = LrHttp.postMultipart(url .. '/api/assets', fields, headers)
    local status = respHeaders and respHeaders.status
    if status == 200 or status == 201 then
        local uuid = body and body:match('"id"%s*:%s*"([^"]+)"')
        if uuid then return uuid, nil end
        return nil, 'Upload HTTP ' .. tostring(status) .. ' but no asset id:\n' .. tostring(body)
    end
    return nil, 'Upload FAILED — HTTP ' .. tostring(status or '?') .. '\n' .. tostring(body or '')
end

-- PUT replace existing asset bytes (preserves UUID). Returns (true) or (false, err).
-- /api/assets/<id>/original REQUIRES multipart PUT — shell out to curl (LrHttp can't PUT multipart).
local function replaceAsset(url, apiKey, deviceId, jpegPath, remoteId, lrPhoto)
    local filename = LrPathUtils.leafName(jpegPath)
    local stat = LrFileUtils.fileAttributes(jpegPath)
    local mtimeIso = LrDate.timeToIsoDate(stat and stat.fileModificationDate or LrDate.currentTime())
    local createdAt = mtimeIso
    if lrPhoto then
        local captureTime = lrPhoto:getRawMetadata('dateTimeOriginal')
        if captureTime then createdAt = LrDate.timeToIsoDate(captureTime) end
    end
    deviceId = deviceId or 'lr-immich'
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
    local rc = execResilient(cmd, 'replace ' .. remoteId)
    if rc == 0 then return true, nil end
    local detail = ''
    local f = io.open(logPath, 'r')
    if f then detail = f:read('*a') or ''; f:close() end
    return false, string.format('PUT /api/assets/%s/original failed (curl exit %d).\n%s',
        remoteId, rc, detail)
end

local function pushSelected()
    LrFunctionContext.callWithContext('pushSelected', function(context)
        local catalog = LrApplication.activeCatalog()
        local selected = catalog:getTargetPhotos() or {}
        if #selected == 0 then
            LrDialogs.message('Push to Immich', 'No photos selected.', 'info')
            return
        end

        log('---- pushSelected START ----')
        log(string.format('  selected count: %d', #selected))

        local services = catalog:getPublishServices(PLUGIN_ID) or {}
        if #services == 0 then
            LrDialogs.message('Push to Immich',
                'No Immich publish service configured.', 'critical')
            return
        end
        local service = services[1]
        local props = service:getPublishSettings()
        local url = normalizeUrl(props.immichBaseUrl)
        local apiKey = LrPasswords.retrieve(passwordKeyFor(url))
        if url == '' or not apiKey or apiKey == '' then
            LrDialogs.message('Push to Immich',
                'Immich URL or API key not configured.', 'critical')
            return
        end

        -- photoId → {remoteId, collectionId} via the service's child
        -- publish-collections (top-level only — collection-sets not recursed).
        local entryByPhotoId = {}
        local lookupCount = 0
        for _, coll in ipairs(service:getChildCollections() or {}) do
            local hasGetPP = (type(coll.getPublishedPhotos) == 'function')
            if hasGetPP then
                local pp = coll:getPublishedPhotos() or {}
                local cid = coll.localIdentifier
                for _, p in ipairs(pp) do
                    local lp = p:getPhoto()
                    local rid = p:getRemoteId()
                    if lp and rid and not entryByPhotoId[lp.localIdentifier] then
                        entryByPhotoId[lp.localIdentifier] = { remoteId = rid, collectionId = cid }
                        lookupCount = lookupCount + 1
                    end
                end
            end
        end
        log(string.format('  built lookup of %d published photos across service collections', lookupCount))

        -- v0.10.0 UPLOAD-ONLY: only photos already published to Immich (have a
        -- remoteId) get re-rendered + re-uploaded here. Unpublished ones are
        -- skipped — use regular Publish to send them new.
        local stats = {
            replaced             = 0,
            skipped_unpublished  = 0,
            failed               = 0,
        }
        local clearedEntries = {}

        local toRender = {}
        for _, photo in ipairs(selected) do
            if entryByPhotoId[photo.localIdentifier] then
                toRender[#toRender + 1] = photo
            else
                local fileName = photo:getFormattedMetadata('fileName') or '?'
                log(string.format('  %s: SKIP — not yet published to Immich', fileName))
                stats.skipped_unpublished = stats.skipped_unpublished + 1
            end
        end

        if #toRender == 0 then
            LrDialogs.message('Push to Immich',
                'None of the selected photos are published to Immich yet.\nUse regular Publish to send them.', 'info')
            return
        end

        local deviceId  = props.immichDeviceId
        local libraryId = props.immichLibraryId

        local progress = LrProgressScope {
            title = string.format('Re-publishing %d photo%s to Immich',
                #toRender, #toRender == 1 and '' or 's'),
            functionContext = context,
        }

        -- Re-render the selected photos through the SAME export settings as the
        -- publish service, then re-upload the bytes via REPLACE (preserves the
        -- Immich UUID). Immich extracts the embedded metadata (date/caption/GPS/
        -- keywords) on upload with ZERO sidecar writes. This is what makes
        -- "Push Selected" honor develop changes too (the old path skipped them).
        local exportSession = LrExportSession {
            photosToExport = toRender,
            exportSettings = props,
        }

        local idx = 0
        for _, rendition in exportSession:renditions() do
            if progress:isCanceled() then break end
            idx = idx + 1
            progress:setPortionComplete(idx - 1, #toRender)

            local success, pathOrMsg = rendition:waitForRender()
            local photo    = rendition.photo
            local pid      = photo and photo.localIdentifier
            local entry    = pid and entryByPhotoId[pid]
            local fileName = photo and photo:getFormattedMetadata('fileName') or '?'

            if not success then
                log(string.format('  %s: render FAILED: %s', fileName, tostring(pathOrMsg)))
                stats.failed = stats.failed + 1
            elseif entry then
                log(string.format('  %s: REPLACE → PUT /api/assets/%s/original', fileName, entry.remoteId))
                local ok, err = replaceAsset(url, apiKey, deviceId, pathOrMsg, entry.remoteId, photo)
                if ok then
                    log('    ✓ re-uploaded (Immich will re-extract embedded metadata)')
                    stats.replaced = stats.replaced + 1
                    clearedEntries[#clearedEntries + 1] = {
                        photoId = pid, collectionId = entry.collectionId,
                    }
                else
                    log('    ✗ replace failed: ' .. tostring(err))
                    stats.failed = stats.failed + 1
                end
            end

            progress:setPortionComplete(idx, #toRender)
        end

        -- Batched flag-clear (one sqlite3 invocation, grouped by collection).
        if #clearedEntries > 0 then
            local catalogPath = catalog:getPath()
            if catalogPath then
                local byColl = {}
                for _, e in ipairs(clearedEntries) do
                    byColl[e.collectionId] = byColl[e.collectionId] or {}
                    table.insert(byColl[e.collectionId], e.photoId)
                end
                local sqlParts = { 'BEGIN IMMEDIATE;' }
                for cid, pids in pairs(byColl) do
                    sqlParts[#sqlParts + 1] = string.format(
                        ' UPDATE AgRemotePhoto SET photoNeedsUpdating = 0' ..
                        ' WHERE collection = %d AND photo IN (%s);',
                        cid, table.concat(pids, ','))
                end
                sqlParts[#sqlParts + 1] = ' COMMIT;'

                local cmd = string.format(
                    '/usr/bin/sqlite3 -cmd %s %s %s',
                    shellEscape('.timeout 30000'),
                    shellEscape(catalogPath),
                    shellEscape(table.concat(sqlParts)))
                local rc = execResilient(cmd, 'flag-clear')
                local nc = 0; for _ in pairs(byColl) do nc = nc + 1 end
                log(string.format('  batched flag-clear: %d photos across %d collection(s), rc=%d',
                    #clearedEntries, nc, rc))
            end
        end

        progress:done()

        log(string.format(
            '  ---- pushSelected DONE: %d re-uploaded, %d unpublished(skipped), %d failed ----',
            stats.replaced, stats.skipped_unpublished, stats.failed))

        LrDialogs.message(
            'Push to Immich complete',
            string.format(
                '%d re-uploaded (Immich re-extracts embedded date/caption/keywords).\n%d skipped (not yet published — use regular Publish).\n%d failed.\n\nNote: photo(s) may still appear in "Modified Photos to Re-Publish" until you restart LR or switch collections — that\'s LR UI caching, not a real status.',
                stats.replaced, stats.skipped_unpublished, stats.failed),
            'info')
    end)
end

LrTasks.startAsyncTask(pushSelected)
