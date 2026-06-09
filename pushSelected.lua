--[[----------------------------------------------------------------------------
pushSelected.lua — Library → Plug-in Extras menu item

Push metadata-only changes for the currently-selected photos to Immich
immediately, bypassing the publish-service queue. Useful when you've
made caption / GPS / keyword / dateCreated edits on a handful of
already-published photos and want them on Immich without batch-
publishing whatever else is in the Modified queue.

Known UI quirk (NOT a bug — it's how LR's Publish Services view works):
  The photo will stay visually in "Modified Photos to Re-Publish" after
  this menu runs. LR caches its publish-service view state and doesn't
  refresh until restart, plugin reload, or collection-switch + back.
  The data IS correct (Immich is patched, AgRemotePhoto.photoNeedsUpdating
  is 0, signatures stored) — just LR's UI displays stale state. Same
  applies to regular Publish runs, just less visible because the publish
  progress dialog gives a "something happened" signal.

Limitations:
  1. METADATA-ONLY. If a photo's develop settings have changed since
     last publish (signature mismatch), it gets SKIPPED. Use regular
     Publish for that — develop changes require re-rendering bytes.
  2. Photo must already be published to Immich (need a UUID to PATCH).
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

local PLUGIN_ID = 'com.lakatua.lr-immich'
local LOG_PATH  = '/tmp/lr-immich.log'

local function log(msg)
    local f = io.open(LOG_PATH, 'a')
    if f then
        f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' [pushSelected/v0.9.1] ' .. tostring(msg) .. '\n')
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

    for _, name in ipairs(toAddNames) do
        local tagId = globalTagCache[name]
        if not tagId then
            local newId, err = createTag(url, apiKey, name)
            if not newId then return false, 'tag create: ' .. tostring(err) end
            globalTagCache[name] = newId
            tagId = newId
        end
        local linkBody = '{"ids":["' .. remoteId .. '"]}'
        local lStatus, lBody =
            curlJson('PUT', url .. '/api/tags/' .. tagId .. '/assets', apiKey, linkBody)
        if lStatus ~= 200 and lStatus ~= 204 then
            return false, string.format(
                'tag link tag=%s status=%d body=%s', tagId, lStatus, lBody)
        end
    end

    for _, tid in ipairs(toRemoveIds) do
        local rmBody = '{"ids":["' .. remoteId .. '"]}'
        local dStatus, dBody =
            curlJson('DELETE', url .. '/api/tags/' .. tid .. '/assets', apiKey, rmBody)
        if dStatus ~= 200 and dStatus ~= 204 then
            return false, string.format(
                'tag unlink tag=%s status=%d body=%s', tid, dStatus, dBody)
        end
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

        -- Cache Immich tags once for this run.
        local globalTagCache = nil
        do
            local tags, err = fetchAllTags(url, apiKey)
            if tags then
                local n = 0; for _ in pairs(tags) do n = n + 1 end
                log(string.format('  tag cache: %d existing Immich tags', n))
                globalTagCache = tags
            else
                log('  tag cache: GET /api/tags FAILED — tag sync skipped. err=' .. tostring(err))
            end
        end

        local progress = LrProgressScope {
            title = string.format('Pushing %d photo%s to Immich',
                #selected, #selected == 1 and '' or 's'),
            functionContext = context,
        }

        local stats = {
            patched              = 0,
            skipped_unpublished  = 0,
            skipped_full_needed  = 0,
            failed               = 0,
        }

        local clearedEntries = {}

        for i, photo in ipairs(selected) do
            if progress:isCanceled() then break end
            progress:setPortionComplete(i - 1, #selected)

            local pid      = photo.localIdentifier
            local fileName = photo:getFormattedMetadata('fileName') or '?'
            local entry    = entryByPhotoId[pid]

            if not entry then
                log(string.format('  %s: SKIP — not in any lr-immich publish collection', fileName))
                stats.skipped_unpublished = stats.skipped_unpublished + 1
            else
                local currentSig = computeSignature(photo)
                local storedSig  = getSignature(pid)
                if storedSig and storedSig == currentSig then
                    log(string.format('  %s: METADATA-ONLY → PUT /api/assets/%s', fileName, entry.remoteId))
                    local ok, err = patchMetadata(url, apiKey, entry.remoteId, photo)
                    if ok then
                        log('    ✓ patched')
                        if globalTagCache then
                            local kws = getKeywordList(photo)
                            local tagOk, tagMsg, addedN, removedN =
                                syncTags(url, apiKey, entry.remoteId, kws, globalTagCache)
                            if tagOk then
                                log(string.format('    tag sync: %s, added=%d removed=%d (lr_kw_count=%d)',
                                    tostring(tagMsg), addedN or 0, removedN or 0, #kws))
                            else
                                log('    tag sync FAILED: ' .. tostring(tagMsg))
                            end
                        end
                        stats.patched = stats.patched + 1
                        clearedEntries[#clearedEntries + 1] = {
                            photoId = pid, collectionId = entry.collectionId,
                        }
                    else
                        log('    ✗ failed: ' .. tostring(err))
                        stats.failed = stats.failed + 1
                    end
                else
                    log(string.format(
                        '  %s: SKIP — signature mismatch (develop changed; use regular Publish)',
                        fileName))
                    stats.skipped_full_needed = stats.skipped_full_needed + 1
                end
            end

            progress:setPortionComplete(i, #selected)
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
            '  ---- pushSelected DONE: %d patched, %d unpublished, %d needs-full, %d failed ----',
            stats.patched, stats.skipped_unpublished, stats.skipped_full_needed, stats.failed))

        LrDialogs.message(
            'Push to Immich complete',
            string.format(
                '%d patched.\n%d skipped (not yet published).\n%d skipped (needs full Publish — develop changed).\n%d failed.\n\nNote: photo(s) may still appear in "Modified Photos to Re-Publish" until you restart LR or switch collections — that\'s LR UI caching, not a real status.',
                stats.patched, stats.skipped_unpublished, stats.skipped_full_needed, stats.failed),
            'info')
    end)
end

LrTasks.startAsyncTask(pushSelected)
