-- ============================================================
--  Razormate's MTG Booster Generator for Tabletop Simulator
--  Version 2.0.0
--
--  Generates booster packs from cached Scryfall card pools.
--  Designed for safe concurrency, bounded retries, deterministic
--  collation, reusable product profiles, and robust TTS spawning.
--
--  Scryfall does not publish sealed-product collation data through
--  its API. Generic profiles are therefore configurable simulations,
--  not guarantees of factory-exact physical booster collation.
-- ============================================================

local SCRIPT_VERSION = "2.0.0"
local SCRIPT_MARKER = "RAZORMATE_MTG_BOOSTER_GENERATOR"

-- ============================================================
--  Configuration
-- ============================================================

local CONFIG = {
    debug = false,

    card = {
        backURL = "https://steamusercontent-a.akamaihd.net/ugc/1647720103762682461/35EF6E87970E2A5D6581E7D96A99F8A575B7A15F/",
        imageQuality = "large", -- small, normal, large, png, art_crop, border_crop
        cacheBustLowResolution = true,
        includeDFCStates = true,
    },

    scryfall = {
        setURL = "https://api.scryfall.com/sets/",
        searchURL = "https://api.scryfall.com/cards/search",
        -- Scryfall's search endpoint currently documents a 2 requests/sec limit.
        minimumRequestInterval = 0.55,
        requestTimeoutSeconds = 35,
        maxAttempts = 4,
        retryBaseSeconds = 1.0,
        retryMaxSeconds = 12,
        maximumPagesPerSet = 30,
    },

    generation = {
        jobTimeoutSeconds = 240,
        replacementRestTimeoutSeconds = 12,
        maximumSpawnAllCards = 1800,
        maximumPreviewBoxes = 100,
        duplicateAttempts = 80,
        allowDuplicateFallback = true,
        prefetchCurrentSetOnLoad = false,
        fixedSeed = nil, -- Set an integer for reproducible debugging; nil uses per-pack seeds.
    },

    pack = {
        defaultSetCode = "???",
        defaultImage = "https://cdn.jsdelivr.net/gh/Razormate88/MTG-Booster-Generator/pack-images/razor-booster-pack.jpg?v=20260319-2",
        imageBaseURL = "https://cdn.jsdelivr.net/gh/Razormate88/MTG-Booster-Generator/pack-images/",
        imageSuffix = ".jpg?v=20260319-2",
        imageCheckTimeoutSeconds = 12,
        spreadColumns = 5,
        spreadSpacingX = 2.25,
        spreadSpacingZ = 3.10,
        spreadDelaySeconds = 0.12,
    },

    box = {
        descriptionPollSeconds = 0.50,
        previewColumns = 10,
        previewSpacingX = 2.75,
        previewSpacingZ = 4.75,
        previewCloneContents = true,
        previewSetCodes = {
            "TMT", "ECL", "TLA", "SPM", "PIP", "EOE", "FIN", "REX", "TDM", "DFT",
            "INR", "FDN", "DSK", "BLB", "MB2", "ACR", "MH3", "OTJ", "MKM", "RVR",
        },
    },

    updater = {
        enabled = true,
        mode = "notify", -- "notify" is safest. Change to "install" for validated auto-install.
        versionURL = "https://raw.githubusercontent.com/Razormate88/MTG-Booster-Generator/refs/heads/main/MTG-Booster-Generator.ver",
        scriptURL = "https://raw.githubusercontent.com/Razormate88/MTG-Booster-Generator/refs/heads/main/MTG-Booster-Generator.lua",
        minimumScriptBytes = 10000,
        maximumScriptBytes = 750000,
        idleInstallChecks = 90,
    },
}

local MESSAGE_COLORS = {
    info = { 1.0, 1.0, 0.4 },
    success = { 0.3, 1.0, 0.3 },
    warning = { 1.0, 0.65, 0.2 },
    error = { 1.0, 0.3, 0.3 },
}

local PLAYER_COLORS = {
    "White", "Brown", "Red", "Orange", "Yellow", "Green",
    "Teal", "Blue", "Purple", "Pink", "Grey", "Black",
}

local JobManager
local HOST_OBJECT = nil
local isSystemBusy = function() return false end

-- ============================================================
--  Utility Helpers
-- ============================================================

local function trim(value)
    local output = tostring(value or "")
    output = output:gsub("^%s+", "")
    output = output:gsub("%s+$", "")
    return output
end

local function safeUpper(value)
    return string.upper(tostring(value or ""))
end

local function safeLower(value)
    return string.lower(tostring(value or ""))
end

local function normalizeNewlines(value)
    local output = tostring(value or "")
    output = output:gsub("\r\n", "\n")
    output = output:gsub("\r", "\n")
    return output
end

local function cleanText(value)
    local output = normalizeNewlines(value)
    output = output:gsub("%z", "")
    return output
end

local function safeDecode(text)
    if not text or text == "" then return nil end
    local ok, decoded = pcall(JSON.decode, text)
    if ok then return decoded end
    return nil
end

local function safeEncode(value)
    local ok, encoded = pcall(JSON.encode, value)
    if ok then return encoded end
    return nil
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end

    local output = {}
    seen[value] = output
    for key, child in pairs(value) do
        output[deepCopy(key, seen)] = deepCopy(child, seen)
    end
    return output
end

local function shallowCopy(value)
    local output = {}
    for key, child in pairs(value or {}) do output[key] = child end
    return output
end

local function mergeTables(base, override)
    local output = deepCopy(base or {})
    for key, value in pairs(override or {}) do
        if type(value) == "table" and type(output[key]) == "table" then
            output[key] = mergeTables(output[key], value)
        else
            output[key] = deepCopy(value)
        end
    end
    return output
end

local function containsValue(list, target)
    for _, value in ipairs(list or {}) do
        if value == target then return true end
    end
    return false
end

local function tableCount(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function truncate(value, maximum)
    value = tostring(value or "")
    if #value <= maximum then return value end
    return value:sub(1, math.max(0, maximum - 3)) .. "..."
end

local function urlEncode(value)
    value = tostring(value or "")
    value = value:gsub("\n", "\r\n")
    value = value:gsub("([^%w %-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
    value = value:gsub(" ", "+")
    return value
end

local function joinQueries(parts)
    local output = {}
    for _, part in ipairs(parts or {}) do
        if part and trim(part) ~= "" then table.insert(output, trim(part)) end
    end
    return table.concat(output, " ")
end

local function normalizeSetList(values, fallback)
    local output = {}
    local seen = {}

    for _, value in ipairs(type(values) == "table" and values or {}) do
        local code = safeUpper(trim(value))
        if code ~= "" and not seen[code] then
            seen[code] = true
            table.insert(output, code)
        end
    end

    if #output == 0 and fallback and fallback ~= "" then
        table.insert(output, safeUpper(fallback))
    end

    return output
end

local function scryfallSetClause(setCodes)
    local clauses = {}
    for _, code in ipairs(setCodes or {}) do
        table.insert(clauses, "set:" .. safeLower(code))
    end
    if #clauses == 0 then return "" end
    if #clauses == 1 then return clauses[1] end
    return "(" .. table.concat(clauses, " OR ") .. ")"
end

local function hashString(value)
    local hash = 5381
    for index = 1, #tostring(value or "") do
        hash = (hash * 33 + string.byte(value, index)) % 2147483647
    end
    return hash
end

local function isObjectAlive(object)
    if not object then return false end
    local ok, guid = pcall(function() return object.getGUID() end)
    return ok and guid and guid ~= ""
end

local function safeObjectCall(object, label, callback)
    if not isObjectAlive(object) then return false, "Object no longer exists." end
    local ok, result = pcall(callback)
    if not ok and CONFIG.debug then
        print("[MTG Booster Generator] " .. tostring(label) .. ": " .. tostring(result))
    end
    return ok, result
end

local function logMessage(level, message)
    if level == "debug" and not CONFIG.debug then return end
    print("[MTG Booster Generator v" .. SCRIPT_VERSION .. "] " .. tostring(message))
end

local function broadcast(color, message, kind)
    local tint = MESSAGE_COLORS[kind or "info"] or MESSAGE_COLORS.info
    if color and color ~= "" then
        broadcastToColor(tostring(message), color, tint)
    else
        broadcastToAll(tostring(message), tint)
    end
end

local function notifyHosts(message, kind)
    local delivered = false
    for _, color in ipairs(PLAYER_COLORS) do
        local player = Player[color]
        if player and player.host then
            broadcast(color, message, kind)
            delivered = true
        end
    end
    if not delivered then logMessage(kind or "info", message) end
end

local function playerCanAdmin(player)
    return player and (player.host or player.admin or player.promoted)
end

-- ============================================================
--  Deterministic Per-Pack Random Number Generator
--  Park-Miller LCG avoids changing Lua's global math.random state.
-- ============================================================

local RNG = {}
RNG.__index = RNG

function RNG.new(seed)
    seed = math.floor(math.abs(tonumber(seed) or 1)) % 2147483647
    if seed == 0 then seed = 1 end
    local instance = setmetatable({ state = seed }, RNG)
    -- Warm the generator so sequential debug seeds do not produce correlated first rolls.
    for _ = 1, 4 do instance.state = (instance.state * 48271) % 2147483647 end
    return instance
end

function RNG:nextInteger()
    self.state = (self.state * 48271) % 2147483647
    return self.state
end

function RNG:random()
    return self:nextInteger() / 2147483647
end

function RNG:index(maximum)
    maximum = math.floor(tonumber(maximum) or 0)
    if maximum <= 0 then return nil end
    return math.floor(self:random() * maximum) + 1
end

function RNG:chance(probability)
    return self:random() < clamp(tonumber(probability) or 0, 0, 1)
end

function RNG:weightedChoice(choices)
    local total = 0
    for _, choice in ipairs(choices or {}) do
        local weight = math.max(0, tonumber(choice.weight) or 0)
        if weight > 0 and choice.available ~= false then total = total + weight end
    end
    if total <= 0 then return nil end

    local roll = self:random() * total
    local cumulative = 0
    for _, choice in ipairs(choices or {}) do
        local weight = math.max(0, tonumber(choice.weight) or 0)
        if weight > 0 and choice.available ~= false then
            cumulative = cumulative + weight
            if roll <= cumulative then return choice.value end
        end
    end
    return choices[#choices] and choices[#choices].value or nil
end

-- ============================================================
--  Safe Auto-Updater
-- ============================================================

local AutoUpdater = {
    name = "Razormate's MTG Booster Generator",
    host = nil,
    checking = false,
}

function AutoUpdater:splitVersion(version)
    local parts = {}
    for number in tostring(version or ""):gmatch("(%d+)") do
        table.insert(parts, tonumber(number) or 0)
    end
    return parts
end

function AutoUpdater:isNewerVersion(remoteVersion)
    local remote = self:splitVersion(remoteVersion)
    local current = self:splitVersion(SCRIPT_VERSION)
    local maximum = math.max(#remote, #current)

    for index = 1, maximum do
        local remoteValue = remote[index] or 0
        local currentValue = current[index] or 0
        if remoteValue > currentValue then return true end
        if remoteValue < currentValue then return false end
    end
    return false
end

function AutoUpdater:validateScript(scriptText, expectedVersion)
    if type(scriptText) ~= "string" then return false, "Downloaded script was not text." end
    if #scriptText < CONFIG.updater.minimumScriptBytes then return false, "Downloaded script was unexpectedly small." end
    if #scriptText > CONFIG.updater.maximumScriptBytes then return false, "Downloaded script exceeded the safety limit." end
    if not scriptText:find(SCRIPT_MARKER, 1, true) then return false, "Downloaded script marker was missing." end

    local declaration = 'local SCRIPT_VERSION = "' .. tostring(expectedVersion) .. '"'
    if not scriptText:find(declaration, 1, true) then
        return false, "Downloaded script did not match the version manifest."
    end
    return true
end

function AutoUpdater:installWhenIdle(version, scriptText, checksRemaining)
    checksRemaining = checksRemaining or CONFIG.updater.idleInstallChecks
    if not self.host then return end

    if isSystemBusy() or not self.host.resting then
        if checksRemaining <= 0 then
            notifyHosts("Booster Generator v" .. version .. " was downloaded but not installed because the object stayed busy.", "warning")
            return
        end
        Wait.time(function() self:installWhenIdle(version, scriptText, checksRemaining - 1) end, 1)
        return
    end

    local ok, err = pcall(function() self.host.setLuaScript(scriptText) end)
    if not ok then
        notifyHosts("Failed to install Booster Generator update: " .. tostring(err), "error")
        return
    end

    notifyHosts("MTG Booster Generator updated to v" .. version .. ". Reloading...", "success")
    Wait.time(function() if self.host then self.host.reload() end end, 0.5)
end

function AutoUpdater:downloadAndInstall(version)
    WebRequest.get(CONFIG.updater.scriptURL, function(request)
        if not request or request.is_error or tonumber(request.response_code or 0) ~= 200 then
            notifyHosts("Could not download Booster Generator v" .. version .. ".", "error")
            return
        end

        local scriptText = request.text or ""
        local valid, reason = self:validateScript(scriptText, version)
        if not valid then
            notifyHosts("Rejected Booster Generator update: " .. tostring(reason), "error")
            return
        end

        self:installWhenIdle(version, scriptText)
    end)
end

function AutoUpdater:checkForUpdate(requestingColor)
    if not CONFIG.updater.enabled or self.checking then return end
    self.checking = true

    WebRequest.get(CONFIG.updater.versionURL, function(request)
        self.checking = false
        if not request or request.is_error or tonumber(request.response_code or 0) ~= 200 then
            if requestingColor then broadcast(requestingColor, "Update check failed.", "warning") end
            return
        end

        local remoteVersion = trim((request.text or ""):match("[^\r\n]+") or "")
        if remoteVersion == "" or not self:isNewerVersion(remoteVersion) then
            if requestingColor then broadcast(requestingColor, "Booster Generator v" .. SCRIPT_VERSION .. " is current.", "success") end
            return
        end

        if CONFIG.updater.mode == "install" then
            notifyHosts("Downloading MTG Booster Generator v" .. remoteVersion .. "...", "info")
            self:downloadAndInstall(remoteVersion)
        else
            notifyHosts("MTG Booster Generator v" .. remoteVersion .. " is available. Current version: v" .. SCRIPT_VERSION .. ".", "warning")
        end
    end)
end

function AutoUpdater:run(host)
    self.host = host
    if not CONFIG.updater.enabled then return end
    Wait.time(function() self:checkForUpdate(nil) end, 1)
end

-- ============================================================
--  Global Scryfall Request Scheduler
-- ============================================================

local RequestScheduler = {
    queue = {},
    active = false,
    activeTag = nil,
}

function RequestScheduler:enqueue(tag, label, task, onCrash)
    table.insert(self.queue, {
        tag = tag,
        label = label or "request",
        task = task,
        onCrash = onCrash,
    })
    self:pump()
end

function RequestScheduler:cancelTag(tag)
    if not tag then return end
    local retained = {}
    for _, item in ipairs(self.queue) do
        if item.tag ~= tag then table.insert(retained, item) end
    end
    self.queue = retained
end

function RequestScheduler:isBusy()
    return self.active or #self.queue > 0
end

function RequestScheduler:pump()
    if self.active or #self.queue == 0 then return end

    local item = table.remove(self.queue, 1)
    self.active = true
    self.activeTag = item.tag
    local completed = false

    local function done()
        if completed then return end
        completed = true
        Wait.time(function()
            self.active = false
            self.activeTag = nil
            self:pump()
        end, CONFIG.scryfall.minimumRequestInterval)
    end

    local ok, err = pcall(item.task, done)
    if not ok then
        logMessage("error", "Request task failed (" .. tostring(item.label) .. "): " .. tostring(err))
        done()
        if item.onCrash then pcall(item.onCrash, err) end
    end
end

-- ============================================================
--  Scryfall HTTP Client
-- ============================================================

local ScryfallAPI = {}

function ScryfallAPI.makeHeaders()
    return {
        ["User-Agent"] = "Razormate-MTG-Booster-Generator/" .. SCRIPT_VERSION ..
            " (+https://github.com/Razormate88/MTG-Booster-Generator)",
        ["Accept"] = "application/json",
    }
end

function ScryfallAPI.isTransientFailure(statusCode, networkError)
    statusCode = tonumber(statusCode) or 0
    if networkError or statusCode == 0 then return true end
    if statusCode == 408 or statusCode == 425 or statusCode == 429 then return true end
    return statusCode >= 500 and statusCode <= 599
end

function ScryfallAPI.getRetryAfter(request)
    if not request or not request.getResponseHeader then return nil end
    local ok, value = pcall(function() return request.getResponseHeader("Retry-After") end)
    if not ok then return nil end
    local seconds = tonumber(value)
    return seconds and seconds >= 0 and seconds or nil
end

function ScryfallAPI.describeFailure(request, fallback)
    local code = tonumber(request and request.response_code) or 0
    local message = nil
    if request and request.text and request.text ~= "" then
        local parsed = safeDecode(request.text)
        if parsed and parsed.details then message = parsed.details end
    end
    if not message or message == "" then message = request and request.error or fallback or "Unknown request failure" end
    return {
        code = code,
        message = tostring(message),
        transient = ScryfallAPI.isTransientFailure(code, request and request.is_error),
    }
end

function ScryfallAPI.requestJSON(url, tag, isRelevant, callback, attempt)
    attempt = attempt or 1
    if isRelevant and not isRelevant() then return end

    RequestScheduler:enqueue(tag, "Scryfall GET", function(done)
        if isRelevant and not isRelevant() then done() return end

        local settled = false
        local requestHandle = nil

        local function finish(request, forcedFailure)
            if settled then return end
            settled = true
            done()
            if isRelevant and not isRelevant() then return end

            local responseCode = tonumber(request and request.response_code) or 0
            local networkError = request and request.is_error

            if not forcedFailure and not networkError and responseCode == 200 then
                local parsed = safeDecode(request.text or "")
                if parsed then
                    local ok, err = pcall(callback, parsed, nil)
                    if not ok then logMessage("error", "Scryfall callback failed: " .. tostring(err)) end
                    return
                end
                forcedFailure = { code = 200, message = "Scryfall returned invalid JSON.", transient = true }
            end

            local failure = forcedFailure or ScryfallAPI.describeFailure(request)
            if failure.transient and attempt < CONFIG.scryfall.maxAttempts then
                local retryAfter = ScryfallAPI.getRetryAfter(request)
                local exponential = CONFIG.scryfall.retryBaseSeconds * (2 ^ (attempt - 1))
                local delay = retryAfter or clamp(
                    exponential + ((os.clock and os.clock() or 0) % 0.25),
                    CONFIG.scryfall.retryBaseSeconds,
                    CONFIG.scryfall.retryMaxSeconds
                )
                Wait.time(function()
                    ScryfallAPI.requestJSON(url, tag, isRelevant, callback, attempt + 1)
                end, delay)
                return
            end

            local ok, err = pcall(callback, nil, failure)
            if not ok then logMessage("error", "Scryfall failure callback failed: " .. tostring(err)) end
        end

        local ok, err = pcall(function()
            requestHandle = WebRequest.custom(
                url,
                "GET",
                true,
                nil,
                ScryfallAPI.makeHeaders(),
                function(request) finish(request, nil) end
            )
        end)

        if not ok then
            finish(nil, { code = 0, message = "WebRequest.custom failed: " .. tostring(err), transient = true })
            return
        end

        Wait.time(function()
            if settled then return end
            if requestHandle and requestHandle.dispose then pcall(function() requestHandle.dispose() end) end
            finish(requestHandle, {
                code = 0,
                message = "Scryfall request timed out after " .. CONFIG.scryfall.requestTimeoutSeconds .. " seconds.",
                transient = true,
            })
        end, CONFIG.scryfall.requestTimeoutSeconds)
    end, function(err)
        callback(nil, { code = 0, message = "Request scheduler failure: " .. tostring(err), transient = false })
    end)
end

function ScryfallAPI.getSet(code, tag, isRelevant, callback)
    local url = CONFIG.scryfall.setURL .. safeLower(code)
    ScryfallAPI.requestJSON(url, tag, isRelevant, callback)
end

function ScryfallAPI.buildSearchURL(query)
    return CONFIG.scryfall.searchURL
        .. "?q=" .. urlEncode(query)
        .. "&unique=prints&order=set&dir=asc&include_extras=true"
end

-- ============================================================
--  Product Catalog and Profile Definitions
-- ============================================================

local BUILTIN_OVERRIDES = {
    ["???"] = { profile = "empty", preview = false, name = "MTG" },

    -- Synthetic product aliases. The alias itself need not be a Scryfall set code.
    TMT  = { profile = "play14", sets = { "TMT" }, name = "Teenage Mutant Ninja Turtles" },
    TMTC = { profile = "collector_custom", sets = { "TMT", "PZA" }, name = "Teenage Mutant Ninja Turtles Collector" },
    TMTT = { profile = "spawn_all", sets = { "TMTT" }, category = "tokens", name = "Teenage Mutant Ninja Turtles Tokens" },

    TLA  = { profile = "play14", sets = { "TLA" }, name = "Avatar: The Last Airbender" },
    TLAC = { profile = "collector_custom", sets = { "TLA", "TLE" }, name = "Avatar: The Last Airbender Collector" },

    SPM  = { profile = "play14", sets = { "SPM" }, name = "Marvel's Spider-Man" },
    SPMC = { profile = "collector_custom", sets = { "SPM", "MAR", "SPE" }, name = "Marvel's Spider-Man Collector" },

    FIN  = { profile = "play14", sets = { "FIN" }, name = "Final Fantasy" },
    FINC = { profile = "collector_custom", sets = { "FIN", "FCA", "FIC" }, name = "Final Fantasy Collector" },

    STX = { profile = "strixhaven_play", sets = { "STX", "STA" } },
    MID = { profile = "transform_slot" },
    VOW = { profile = "transform_slot" },
    DKA = { profile = "transform_slot" },
    ISD = { profile = "transform_slot" },
    SOI = { profile = "transform_slot" },
    EMN = { profile = "transform_slot" },
    KHM = { profile = "snow_slot" },
    CNS = { profile = "conspiracy" },
    CN2 = { profile = "conspiracy" },
    LEA = { profile = "alpha15", name = "Limited Edition Alpha" },
    MB1 = { profile = "mystery_playtest", sets = { "MB1", "CMB1" } },
    CMM = { profile = "default20", name = "Commander Masters" },
    CLB = { profile = "default20" },
    CMR = { profile = "default20" },

    TOK   = { profile = "spawn_all", category = "tokens" },
    TDFT  = { profile = "spawn_all", category = "tokens" },
    TMKM  = { profile = "spawn_all", category = "tokens" },
    TOTJ  = { profile = "spawn_all", category = "tokens" },
    TMH3  = { profile = "spawn_all", category = "tokens" },
    TBLB  = { profile = "spawn_all", category = "tokens" },
    TDSK  = { profile = "spawn_all", category = "tokens" },
    TFDN  = { profile = "spawn_all", category = "tokens" },
    TINR  = { profile = "spawn_all", category = "tokens" },
    TDRC  = { profile = "spawn_all", category = "tokens" },
    TPLST = { profile = "spawn_all", category = "tokens" },

    TAR   = { profile = "spawn_all", category = "art_series" },
    OARC  = { profile = "spawn_all", category = "art_series" },
    ADFT  = { profile = "spawn_all", category = "art_series" },
    AMKM  = { profile = "spawn_all", category = "art_series" },
    AOTJ  = { profile = "spawn_all", category = "art_series" },
    AMH3  = { profile = "spawn_all", category = "art_series" },
    ABLB  = { profile = "spawn_all", category = "art_series" },
    ADSK  = { profile = "spawn_all", category = "art_series" },
    AFDN  = { profile = "spawn_all", category = "art_series" },
}

local ProductCatalog = {}

function ProductCatalog.inferProfile(meta)
    if not meta then return "play14" end
    local setType = safeLower(meta.set_type)
    local cardCount = tonumber(meta.card_count or 0) or 0

    if setType == "token" or setType == "memorabilia" then return "spawn_all" end
    if cardCount > 0 and cardCount < 14 then return "spawn_all" end
    if setType == "commander" then return "default20" end
    return "play14"
end

function ProductCatalog.resolve(setCode, primaryMeta)
    local code = safeUpper(trim(setCode))
    if code == "" then code = CONFIG.pack.defaultSetCode end

    local override = BUILTIN_OVERRIDES[code] or {}
    local base = {
        code = code,
        name = (primaryMeta and primaryMeta.name) or code,
        releasedAt = (primaryMeta and primaryMeta.released_at) or "",
        setType = (primaryMeta and primaryMeta.set_type) or "",
        cardCount = tonumber(primaryMeta and primaryMeta.card_count or 0) or 0,
        sets = { code },
        profile = ProductCatalog.inferProfile(primaryMeta),
        category = nil,
        preview = true,
        includeNonBooster = false,
        spawnAll = false,
    }

    local spec = mergeTables(base, override)
    spec.sets = normalizeSetList(spec.sets, code)
    spec.spawnAll = spec.profile == "spawn_all"
    if spec.profile == "collector_custom" then spec.includeNonBooster = true end
    if override.name then spec.name = override.name end
    return spec
end

function ProductCatalog.isSyntheticCode(code)
    local override = BUILTIN_OVERRIDES[safeUpper(code)]
    if not override then return false end
    local sets = normalizeSetList(override.sets, code)
    return #sets ~= 1 or sets[1] ~= safeUpper(code)
end

-- ============================================================
--  Metadata Cache
-- ============================================================

local MetadataService = { cache = {} }

function MetadataService.clear()
    MetadataService.cache = {}
end

function MetadataService.load(code, tag, isRelevant, callback)
    code = safeUpper(code)
    local cached = MetadataService.cache[code]

    if cached and cached.state == "ready" then callback(cached.meta, nil) return end
    if cached and cached.state == "failed" then callback(nil, cached.error) return end

    if cached and cached.state == "loading" then
        table.insert(cached.waiters, { relevant = isRelevant, callback = callback })
        return
    end

    local entry = { state = "loading", waiters = { { relevant = isRelevant, callback = callback } } }
    MetadataService.cache[code] = entry

    local function deliver(meta, failure)
        if failure then
            entry.state = "failed"
            entry.error = failure
        else
            entry.state = "ready"
            entry.meta = meta
        end

        local waiters = entry.waiters
        entry.waiters = {}
        if failure and failure.transient then MetadataService.cache[code] = nil end
        for _, waiter in ipairs(waiters) do
            if not waiter.relevant or waiter.relevant() then
                pcall(waiter.callback, meta, failure)
            end
        end
    end

    ScryfallAPI.getSet(code, "metadata:" .. code, nil, function(parsed, failure)
        if failure then deliver(nil, failure) return end
        if not parsed or parsed.object == "error" or not parsed.code then
            deliver(nil, { code = 404, message = "Set code " .. code .. " was not found on Scryfall.", transient = false })
            return
        end
        deliver(parsed, nil)
    end)
end

function MetadataService.loadSpec(initialSpec, tag, isRelevant, callback)
    local setCodes = initialSpec.sets or {}
    if #setCodes == 0 then
        callback(nil, { message = "Product contained no Scryfall set codes." })
        return
    end

    local remaining = #setCodes
    local metas = {}
    local finished = false

    local function fail(failure)
        if finished then return end
        finished = true
        callback(nil, failure)
    end

    for index, code in ipairs(setCodes) do
        MetadataService.load(code, tag, isRelevant, function(meta, failure)
            if finished or (isRelevant and not isRelevant()) then return end
            if failure then
                fail({
                    code = failure.code,
                    message = "Could not load set " .. code .. ": " .. tostring(failure.message),
                    transient = failure.transient,
                })
                return
            end

            metas[index] = meta
            remaining = remaining - 1
            if remaining == 0 then
                finished = true
                local resolved = ProductCatalog.resolve(initialSpec.code, metas[1])
                -- Preserve alias overrides and the already-normalized set list.
                resolved = mergeTables(resolved, BUILTIN_OVERRIDES[initialSpec.code] or {})
                resolved.sets = normalizeSetList(initialSpec.sets, initialSpec.code)
                resolved.spawnAll = resolved.profile == "spawn_all"
                resolved.metadata = metas
                if not (BUILTIN_OVERRIDES[initialSpec.code] and BUILTIN_OVERRIDES[initialSpec.code].name) then
                    resolved.name = metas[1] and metas[1].name or resolved.name
                end
                resolved.releasedAt = metas[1] and metas[1].released_at or resolved.releasedAt
                callback(resolved, nil)
            end
        end)
    end
end

-- ============================================================
--  Card Pool Loader and Cache
-- ============================================================

local PoolService = { cache = {} }

local TOKEN_LAYOUTS = {
    token = true,
    double_faced_token = true,
    emblem = true,
    art_series = true,
}

local function cardHasPaperGame(card)
    if type(card.games) ~= "table" then return true end
    return containsValue(card.games, "paper")
end

local function cardHasFinish(card, finish)
    return containsValue(card.finishes or {}, finish)
end

local function cardHasFrameEffect(card, effect)
    return containsValue(card.frame_effects or {}, effect)
end

local function cardHasPromoType(card, promoType)
    return containsValue(card.promo_types or {}, promoType)
end

local function cardTypeContains(card, text)
    return safeLower(card.type_line):find(safeLower(text), 1, true) ~= nil
end

local function cardIsLand(card)
    return cardTypeContains(card, "land")
end

local function cardIsBasicLand(card)
    return cardTypeContains(card, "basic") and cardIsLand(card)
end

local function cardIsEnglish(card)
    return not card.lang or safeLower(card.lang) == "en"
end

local function cardIsNormalGamePiece(card)
    return not TOKEN_LAYOUTS[safeLower(card.layout)]
end

local function addToPool(pools, name, card)
    pools[name] = pools[name] or {}
    table.insert(pools[name], card)
end

function PoolService.cacheKey(spec)
    return safeLower(spec.profile or "play14") .. "|" .. table.concat(spec.sets or {}, ",")
end

function PoolService.clear()
    PoolService.cache = {}
end

function PoolService.buildPools(cards, spec)
    local pools = {
        all = {},
        eligible = {},
        booster = {},
        common = {}, uncommon = {}, rare = {}, mythic = {},
        commonNonLand = {}, uncommonNonLand = {}, rareNonLand = {}, mythicNonLand = {},
        land = {}, basicLand = {}, snowBasic = {},
        transform = {}, conspiracy = {}, lesson = {}, archive = {}, playtest = {},
        borderlessMythicNonLand = {}, foilEligible = {},
    }

    local eligible = {}
    local booster = {}

    for _, card in ipairs(cards or {}) do
        table.insert(pools.all, card)

        local paper = cardHasPaperGame(card)
        local english = cardIsEnglish(card)
        local normalPiece = cardIsNormalGamePiece(card)
        local include = paper and english and (spec.spawnAll or normalPiece)

        if include then
            table.insert(eligible, card)
            if card.booster == true and normalPiece then table.insert(booster, card) end
        end
    end

    pools.eligible = eligible
    pools.booster = booster

    local base = eligible
    if not spec.spawnAll and not spec.includeNonBooster and #booster > 0 then base = booster end

    for _, card in ipairs(base) do
        local rarity = safeLower(card.rarity)
        local land = cardIsLand(card)

        if rarity == "common" or rarity == "uncommon" or rarity == "rare" or rarity == "mythic" then
            addToPool(pools, rarity, card)
            if not land then addToPool(pools, rarity .. "NonLand", card) end
        end

        if land then
            addToPool(pools, "land", card)
            if cardIsBasicLand(card) then addToPool(pools, "basicLand", card) end
            if cardIsBasicLand(card) and cardTypeContains(card, "snow") then addToPool(pools, "snowBasic", card) end
        end

        local layout = safeLower(card.layout)
        if layout == "transform" or layout == "modal_dfc" or layout == "reversible_card" or layout == "meld" then
            addToPool(pools, "transform", card)
        end
        if cardTypeContains(card, "conspiracy") then addToPool(pools, "conspiracy", card) end
        if cardTypeContains(card, "lesson") then addToPool(pools, "lesson", card) end
        if safeLower(card.set) == "sta" then addToPool(pools, "archive", card) end
        if safeLower(card.set) == "cmb1" or cardHasFrameEffect(card, "future") or cardHasPromoType(card, "playtest") then
            addToPool(pools, "playtest", card)
        end
        if rarity == "mythic" and not land and (safeLower(card.border_color) == "borderless" or card.full_art == true) then
            addToPool(pools, "borderlessMythicNonLand", card)
        end
        if cardHasFinish(card, "foil") then addToPool(pools, "foilEligible", card) end
    end

    return pools, base
end

function PoolService.load(spec, tag, isRelevant, onProgress, callback)
    local key = PoolService.cacheKey(spec)
    local cached = PoolService.cache[key]

    if cached and cached.state == "ready" then callback(cached, nil) return end
    if cached and cached.state == "failed" then callback(nil, cached.error) return end
    if cached and cached.state == "loading" then
        table.insert(cached.waiters, { relevant = isRelevant, callback = callback, progress = onProgress })
        return
    end

    local entry = {
        state = "loading",
        waiters = { { relevant = isRelevant, callback = callback, progress = onProgress } },
        spec = spec,
    }
    PoolService.cache[key] = entry

    local cards = {}
    local seen = {}
    local setIndex = 1
    local completed = false
    local function entryRelevant()
        return entry.state == "loading"
    end

    local function notifyProgress(message)
        for _, waiter in ipairs(entry.waiters) do
            if waiter.progress and (not waiter.relevant or waiter.relevant()) then pcall(waiter.progress, message) end
        end
    end

    local function deliver(result, failure)
        if completed then return end
        completed = true
        if failure then
            entry.state = "failed"
            entry.error = failure
        else
            entry.state = "ready"
            entry.cards = result.cards
            entry.pools = result.pools
            entry.basePool = result.basePool
        end

        local waiters = entry.waiters
        entry.waiters = {}
        if failure and failure.transient then PoolService.cache[key] = nil end
        for _, waiter in ipairs(waiters) do
            if not waiter.relevant or waiter.relevant() then pcall(waiter.callback, failure and nil or entry, failure) end
        end
    end

    local function finalize()
        local pools, basePool = PoolService.buildPools(cards, spec)
        if #cards == 0 then
            deliver(nil, { code = 0, message = "Scryfall returned no cards for " .. table.concat(spec.sets, ", ") .. ".", transient = false })
            return
        end
        if not spec.spawnAll and #basePool == 0 then
            deliver(nil, { code = 0, message = "No booster-eligible cards were found for this product.", transient = false })
            return
        end
        deliver({ cards = cards, pools = pools, basePool = basePool }, nil)
    end

    local fetchSet
    fetchSet = function(pageURL, pageNumber)
        if not entryRelevant() then return end
        local code = spec.sets[setIndex]
        if not code then finalize() return end

        if pageNumber > CONFIG.scryfall.maximumPagesPerSet then
            deliver(nil, { code = 0, message = "Set " .. code .. " exceeded the configured page safety limit.", transient = false })
            return
        end

        local url = pageURL
        if not url then
            local query = joinQueries({ "set:" .. safeLower(code), "game:paper", "lang:en" })
            url = ScryfallAPI.buildSearchURL(query)
        end

        notifyProgress("Loading " .. code .. " page " .. tostring(pageNumber) .. "...")
        ScryfallAPI.requestJSON(url, "pool:" .. key, entryRelevant, function(parsed, failure)
            if failure then
                deliver(nil, {
                    code = failure.code,
                    message = "Could not load card pool for " .. code .. ": " .. tostring(failure.message),
                    transient = failure.transient,
                })
                return
            end

            if not parsed or parsed.object == "error" or type(parsed.data) ~= "table" then
                deliver(nil, { code = 0, message = "Scryfall returned invalid search data for " .. code .. ".", transient = false })
                return
            end

            for _, card in ipairs(parsed.data) do
                local keyValue = tostring(card.id or (card.set or "") .. ":" .. tostring(card.collector_number or ""))
                if keyValue ~= "" and not seen[keyValue] then
                    seen[keyValue] = true
                    table.insert(cards, card)
                end
            end

            if parsed.has_more and parsed.next_page then
                fetchSet(parsed.next_page, pageNumber + 1)
            else
                setIndex = setIndex + 1
                fetchSet(nil, 1)
            end
        end)
    end

    fetchSet(nil, 1)
end

-- ============================================================
--  Booster Profile Builders
-- ============================================================

local Profiles = {}

local function appendSlots(slots, count, selector, options)
    for index = 1, count do
        local slot = deepCopy(options or {})
        slot.selector = selector
        slot.id = slot.id or (selector .. "-" .. tostring(index))
        table.insert(slots, slot)
    end
end

function Profiles.empty(spec, rng)
    return {}
end

function Profiles.default15(spec, rng)
    local slots = {}
    appendSlots(slots, 10, "commonNonLand")
    appendSlots(slots, 3, "uncommonNonLand")
    appendSlots(slots, 1, "rareMythicNonLand")
    appendSlots(slots, 1, "land", { allowDuplicate = true, fallbacks = { "commonNonLand", "anyNonLandWeighted" } })
    return slots
end

function Profiles.default14(spec, rng)
    local slots = {}
    appendSlots(slots, 9, "commonNonLand")
    appendSlots(slots, 3, "uncommonNonLand")
    appendSlots(slots, 1, "rareMythicNonLand")
    appendSlots(slots, 1, "land", { allowDuplicate = true, fallbacks = { "commonNonLand", "anyNonLandWeighted" } })
    return slots
end

function Profiles.default20(spec, rng)
    local slots = {}
    appendSlots(slots, 13, "commonNonLand")
    appendSlots(slots, 6, "uncommonNonLand")
    appendSlots(slots, 1, "rareMythicNonLand")
    return slots
end

function Profiles.play14(spec, rng)
    local slots = {}
    local rareCount = rng:weightedChoice({
        { value = 1, weight = 71.7 },
        { value = 2, weight = 25.0 },
        { value = 3, weight = 3.0 },
        { value = 4, weight = 0.15 },
        { value = 5, weight = 0.15 },
    }) or 1

    appendSlots(slots, rareCount, "rareMythicNonLand")
    appendSlots(slots, 3, "uncommonNonLand")
    appendSlots(slots, 1, "land", { allowDuplicate = true, fallbacks = { "commonNonLand", "anyNonLandWeighted" } })

    local foilSelector = "anyNonLandWeighted"
    local foilRoll = rng:random()
    if foilRoll < 0.20 then
        foilSelector = "land"
    elseif foilRoll < 0.21 then
        foilSelector = "borderlessMythicNonLand"
    end
    appendSlots(slots, 1, foilSelector, {
        finish = "foil",
        allowDuplicate = foilSelector == "land",
        fallbacks = { "anyNonLandWeighted", "land" },
    })

    appendSlots(slots, math.max(0, 9 - rareCount), "commonNonLand")
    return slots
end

function Profiles.collector_custom(spec, rng)
    local slots = {}
    appendSlots(slots, 10, "anyNonLandWeighted", { finish = "foil" })
    appendSlots(slots, 1, "uncommonPlus", { finish = "foil" })
    appendSlots(slots, 4, "rareMythicNonLand", { finish = "foil" })
    return slots
end

function Profiles.strixhaven_play(spec, rng)
    local slots = {}
    appendSlots(slots, 9, "commonNonLand")
    appendSlots(slots, 3, "uncommonNonLand")
    appendSlots(slots, 1, "rareMythicNonLand")
    appendSlots(slots, 1, "archive", { fallbacks = { "anyNonLandWeighted" } })
    appendSlots(slots, 1, "lesson", { fallbacks = { "commonNonLand", "anyNonLandWeighted" } })
    return slots
end

function Profiles.conspiracy(spec, rng)
    local slots = {}
    appendSlots(slots, 9, "commonNonLand")
    appendSlots(slots, 3, "uncommonNonLand")
    appendSlots(slots, 1, "rareMythicNonLand")
    appendSlots(slots, 1, "conspiracy", { fallbacks = { "anyNonLandWeighted" } })
    appendSlots(slots, 1, "anyNonLandWeighted")
    return slots
end

function Profiles.alpha15(spec, rng)
    local slots = {}
    appendSlots(slots, 11, "commonNonLand")
    appendSlots(slots, 3, "uncommonNonLand")
    appendSlots(slots, 1, "rareNonLand", { fallbacks = { "rareMythicNonLand" } })
    return slots
end

function Profiles.mystery_playtest(spec, rng)
    local slots = {}
    appendSlots(slots, 8, "commonNonLand")
    appendSlots(slots, 3, "uncommonNonLand")
    appendSlots(slots, 2, "rareMythicNonLand")
    appendSlots(slots, 1, "playtest", { fallbacks = { "anyNonLandWeighted" } })
    appendSlots(slots, 1, "land", { allowDuplicate = true, fallbacks = { "commonNonLand", "anyNonLandWeighted" } })
    return slots
end

function Profiles.transform_slot(spec, rng)
    local slots = Profiles.default15(spec, rng)
    slots[7] = { id = "transform", selector = "transform", fallbacks = { "commonNonLand", "anyNonLandWeighted" } }
    return slots
end

function Profiles.snow_slot(spec, rng)
    local slots = Profiles.default15(spec, rng)
    slots[#slots] = { id = "snow-land", selector = "snowBasic", allowDuplicate = true, fallbacks = { "basicLand", "land" } }
    return slots
end

function Profiles.spawn_all(spec, rng)
    return {}
end

-- ============================================================
--  Collation Engine
-- ============================================================

local CollationEngine = {}

local function cardIdentity(card)
    return tostring(card.oracle_id or card.name or card.id or "")
end

local function chooseUniqueFromPool(pool, rng, selected, allowDuplicate)
    if type(pool) ~= "table" or #pool == 0 then return nil, false end

    if allowDuplicate then return pool[rng:index(#pool)], false end

    for _ = 1, math.min(CONFIG.generation.duplicateAttempts, math.max(1, #pool * 2)) do
        local candidate = pool[rng:index(#pool)]
        if candidate and not selected[cardIdentity(candidate)] then return candidate, false end
    end

    for _, candidate in ipairs(pool) do
        if not selected[cardIdentity(candidate)] then return candidate, false end
    end

    if CONFIG.generation.allowDuplicateFallback then return pool[rng:index(#pool)], true end
    return nil, false
end

function CollationEngine.rarityPoolName(pools, weights, rng)
    local choices = {}
    for rarity, weight in pairs(weights or {}) do
        local poolName = rarity .. "NonLand"
        table.insert(choices, {
            value = poolName,
            weight = weight,
            available = pools[poolName] and #pools[poolName] > 0,
        })
    end
    return rng:weightedChoice(choices)
end

function CollationEngine.resolveSelector(selector, pools, rng)
    if selector == "rareMythicNonLand" then
        local poolName = CollationEngine.rarityPoolName(pools, { rare = 7, mythic = 1 }, rng)
        return poolName and pools[poolName] or nil, poolName
    elseif selector == "anyNonLandWeighted" then
        local poolName = CollationEngine.rarityPoolName(pools, { common = 70, uncommon = 20, rare = 8, mythic = 2 }, rng)
        return poolName and pools[poolName] or nil, poolName
    elseif selector == "uncommonPlus" then
        local poolName = CollationEngine.rarityPoolName(pools, { uncommon = 70, rare = 25, mythic = 5 }, rng)
        return poolName and pools[poolName] or nil, poolName
    end
    return pools[selector], selector
end

function CollationEngine.selectSlot(slot, pools, rng, selected)
    local selectors = { slot.selector }
    for _, fallback in ipairs(slot.fallbacks or {}) do table.insert(selectors, fallback) end

    for fallbackIndex, selector in ipairs(selectors) do
        local pool, resolvedName = CollationEngine.resolveSelector(selector, pools, rng)
        local card, duplicated = chooseUniqueFromPool(pool, rng, selected, slot.allowDuplicate)
        if card then
            return card, {
                usedFallback = fallbackIndex > 1,
                duplicated = duplicated,
                selector = resolvedName or selector,
                finish = slot.finish,
            }
        end
    end

    return nil, { error = "No card was available for slot " .. tostring(slot.id or slot.selector) .. "." }
end

function CollationEngine.generate(spec, poolEntry, seed)
    local rng = RNG.new(seed)
    local profileBuilder = Profiles[spec.profile] or Profiles.play14

    if spec.spawnAll then
        local cards = deepCopy(poolEntry.cards or {})
        table.sort(cards, function(left, right)
            local leftSet = safeLower(left.set)
            local rightSet = safeLower(right.set)
            if leftSet ~= rightSet then return leftSet < rightSet end
            local leftNumber = tostring(left.collector_number or "")
            local rightNumber = tostring(right.collector_number or "")
            return leftNumber < rightNumber
        end)

        if #cards > CONFIG.generation.maximumSpawnAllCards then
            return nil, {
                message = "This set contains " .. #cards .. " cards, exceeding the configured spawn-all limit of " ..
                    CONFIG.generation.maximumSpawnAllCards .. ".",
            }
        end

        return {
            cards = cards,
            slots = {},
            warnings = {},
            seed = seed,
        }, nil
    end

    local slots = profileBuilder(spec, rng)
    local selected = {}
    local cards = {}
    local slotResults = {}
    local warnings = {}

    for index, slot in ipairs(slots) do
        local card, result = CollationEngine.selectSlot(slot, poolEntry.pools, rng, selected)
        if not card then
            return nil, { message = result.error or ("Could not fill booster slot " .. index .. ".") }
        end

        local identity = cardIdentity(card)
        if identity ~= "" then selected[identity] = true end
        table.insert(cards, card)
        table.insert(slotResults, {
            id = slot.id,
            selector = result.selector,
            finish = result.finish,
            card = card,
        })

        if result.usedFallback then
            table.insert(warnings, "Slot " .. tostring(slot.id or index) .. " used fallback pool " .. tostring(result.selector) .. ".")
        end
        if result.duplicated then
            table.insert(warnings, "Slot " .. tostring(slot.id or index) .. " required a duplicate card.")
        end
    end

    return {
        cards = cards,
        slots = slotResults,
        warnings = warnings,
        seed = seed,
    }, nil
end

-- ============================================================
--  TTS Card and Deck Builder
--  Maintains legacy DFC memo compatibility and optional TTS states.
-- ============================================================

local CardBuilder = {}

function CardBuilder.chooseImageURI(imageURIs)
    if type(imageURIs) ~= "table" then return nil end
    return imageURIs[CONFIG.card.imageQuality]
        or imageURIs.large
        or imageURIs.normal
        or imageURIs.small
        or imageURIs.png
end

function CardBuilder.addCacheBuster(url, card)
    if not url then return nil end
    if not CONFIG.card.cacheBustLowResolution then return url end
    if card and card.image_status == "highres_scan" then return url end
    local separator = url:find("?", 1, true) and "&" or "?"
    return url .. separator .. "tts_cache=" .. os.date("%Y%m%d")
end

function CardBuilder.formattedName(face, typeSuffix, fallbackCMC)
    face = face or {}
    local cmc = face.cmc
    if cmc == nil then cmc = fallbackCMC end
    if cmc == nil then cmc = 0 end

    local name = cleanText(face.name or ""):gsub('"', "")
    local typeLine = cleanText(face.type_line or "")
    local suffix = typeSuffix and (" " .. tostring(typeSuffix)) or ""
    local output = string.format("%s\n%s CMC %s%s", name, typeLine, tostring(cmc), suffix)
    output = output:gsub("%s+$", "")
    return output
end

function CardBuilder.oracleText(face)
    face = face or {}
    local output = cleanText(face.oracle_text or "")
    if face.power ~= nil or face.toughness ~= nil then
        output = output .. "\n[b]" .. tostring(face.power or "?") .. "/" .. tostring(face.toughness or "?") .. "[/b]"
    elseif face.loyalty ~= nil then
        output = output .. "\n[b]" .. tostring(face.loyalty) .. "[/b]"
    elseif face.defense ~= nil then
        output = output .. "\n[b]Defense " .. tostring(face.defense) .. "[/b]"
    end
    return output
end

function CardBuilder.memoSafe(value)
    local output = cleanText(value or "")
    output = output:gsub("|", "¦")
    return output
end

function CardBuilder.makeState(backFace, backURL, identity, stateDeckID, fallbackCMC)
    return {
        Transform = {
            posX = 0, posY = 0, posZ = 0,
            rotX = 0, rotY = 0, rotZ = 0,
            scaleX = 1, scaleY = 1, scaleZ = 1,
        },
        Name = "Card",
        Nickname = CardBuilder.formattedName(backFace, "DFC", fallbackCMC),
        Description = CardBuilder.oracleText(backFace),
        Memo = identity,
        CardID = stateDeckID * 100,
        CustomDeck = {
            [stateDeckID] = {
                FaceURL = backURL,
                BackURL = CONFIG.card.backURL,
                NumWidth = 1,
                NumHeight = 1,
                Type = 0,
                BackIsHidden = true,
                UniqueBack = false,
            },
        },
    }
end

function CardBuilder.create(card, deckID)
    if type(card) ~= "table" or not card.name then return nil, "Scryfall returned incomplete card data." end

    local cardName, cardDescription, faceURL
    local backURL, backName, backDescription, backFace

    if type(card.card_faces) == "table" and #card.card_faces > 0 then
        if card.image_uris then
            cardName = CardBuilder.formattedName(card.card_faces[1], nil, card.cmc)
            local descriptions = {}
            for _, face in ipairs(card.card_faces) do
                table.insert(descriptions, CardBuilder.formattedName(face, nil, card.cmc) .. "\n" .. CardBuilder.oracleText(face))
            end
            cardDescription = table.concat(descriptions, "\n")
            faceURL = CardBuilder.chooseImageURI(card.image_uris)
        elseif #card.card_faces >= 2 then
            local front = card.card_faces[1]
            backFace = card.card_faces[2]
            cardName = CardBuilder.formattedName(front, "DFC", card.cmc)
            cardDescription = CardBuilder.oracleText(front)
            faceURL = CardBuilder.chooseImageURI(front.image_uris)
            backURL = CardBuilder.chooseImageURI(backFace.image_uris)
            backName = CardBuilder.formattedName(backFace, "DFC", card.cmc)
            backDescription = CardBuilder.oracleText(backFace)
        else
            return nil, "Card had faces but no usable image data: " .. tostring(card.name)
        end
    else
        cardName = CardBuilder.formattedName(card, nil, card.cmc)
        cardDescription = CardBuilder.oracleText(card)
        faceURL = CardBuilder.chooseImageURI(card.image_uris)
    end

    faceURL = CardBuilder.addCacheBuster(faceURL, card)
    backURL = CardBuilder.addCacheBuster(backURL, card)
    if not faceURL or faceURL == "" then return nil, "No front image was available for " .. tostring(card.name) end
    if backFace and (not backURL or backURL == "") then return nil, "No back image was available for " .. tostring(card.name) end

    local identity = tostring(card.oracle_id or card.id or "")
    local memo = identity
    if backURL then
        memo = identity
            .. "|BFACE=" .. CardBuilder.memoSafe(backURL)
            .. "|BNAME=" .. CardBuilder.memoSafe(backName)
            .. "|BDESC=" .. CardBuilder.memoSafe(backDescription)
    end

    local cardData = {
        Transform = {
            posX = 0, posY = 0, posZ = 0,
            rotX = 0, rotY = 0, rotZ = 0,
            scaleX = 1, scaleY = 1, scaleZ = 1,
        },
        Name = "Card",
        Nickname = cardName,
        Description = cardDescription,
        Memo = memo,
        CardID = deckID * 100,
        CustomDeck = {
            [deckID] = {
                FaceURL = faceURL,
                BackURL = CONFIG.card.backURL,
                NumWidth = 1,
                NumHeight = 1,
                Type = 0,
                BackIsHidden = true,
                UniqueBack = false,
            },
        },
    }

    if backFace and CONFIG.card.includeDFCStates then
        local stateDeckID = 10000 + deckID
        cardData.States = {
            [2] = CardBuilder.makeState(backFace, backURL, identity, stateDeckID, card.cmc),
        }
    end

    return cardData, nil
end

local DeckBuilder = {}

function DeckBuilder.build(cards, deckName)
    local deck = {
        Transform = {
            posX = 0, posY = 0, posZ = 0,
            rotX = 0, rotY = 180, rotZ = 0,
            scaleX = 1, scaleY = 1, scaleZ = 1,
        },
        Name = "Deck",
        Nickname = deckName,
        DeckIDs = {},
        CustomDeck = {},
        ContainedObjects = {},
    }

    local errors = {}
    for index, card in ipairs(cards or {}) do
        local cardData, failure = CardBuilder.create(card, index)
        if cardData then
            table.insert(deck.ContainedObjects, cardData)
            table.insert(deck.DeckIDs, cardData.CardID)
            deck.CustomDeck[index] = deepCopy(cardData.CustomDeck[index])
        else
            table.insert(errors, failure or ("Could not build " .. tostring(card.name)))
        end
    end

    local count = #deck.ContainedObjects
    if count == 0 then return nil, errors end
    if count == 1 then return deck.ContainedObjects[1], errors end
    return deck, errors
end

function DeckBuilder.errorNotecard(message, details)
    local description = tostring(message or "Unknown booster-generation error.")
    if details and details ~= "" then description = description .. "\n\n" .. tostring(details) end
    return {
        Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 2, scaleY = 2, scaleZ = 1 },
        Name = "Notecard",
        Nickname = "Booster Generation Error",
        Description = description,
        Grid = false,
        Snap = false,
    }
end

function DeckBuilder.instructionNotecard()
    return {
        Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 2, scaleZ = 1 },
        Name = "Notecard",
        Nickname = "MTG Booster Generator",
        Description = "Set the booster box description like:\nSET: FIN\n\nThen pull a blank booster pack from the box.",
        Grid = false,
        Snap = false,
    }
end

-- ============================================================
--  Script Embedded in Generated Booster Packs
-- ============================================================

local PACK_LUA = [[
local OPENING = false
local COLUMNS = 5
local SPACING_X = 2.25
local SPACING_Z = 3.10
local DELAY = 0.12

local function alive(object)
    if not object then return false end
    local ok = pcall(function() return object.getGUID() end)
    return ok
end

function tryObjectEnter()
    return false
end

local function positionFor(origin, index)
    local row = math.floor((index - 1) / COLUMNS)
    local column = (index - 1) % COLUMNS
    return origin + Vector(column * SPACING_X, 0, -row * SPACING_Z)
end

local function finishOpen()
    if alive(self) then pcall(function() self.destruct() end) end
end

local function spreadDeck(deck, origin, index)
    index = index or 1
    if not alive(deck) then finishOpen() return end

    if deck.tag ~= "Deck" then
        pcall(function()
            deck.setScale({ 1, 1, 1 })
            deck.setLock(false)
            deck.setPositionSmooth(positionFor(origin, index), false, false)
        end)
        finishOpen()
        return
    end

    local target = positionFor(origin, index)
    local ok = pcall(function()
        deck.takeObject({
            position = target,
            smooth = true,
            callback_function = function(card)
                if alive(card) then pcall(function() card.setScale({ 1, 1, 1 }) end) end
                Wait.time(function()
                    local remainder = nil
                    pcall(function() remainder = deck.remainder end)
                    if alive(remainder) then deck = remainder end
                    spreadDeck(deck, origin, index + 1)
                end, DELAY)
            end,
        })
    end)

    if not ok then finishOpen() end
end

local function releaseSingleObject(entry, origin)
    self.takeObject({
        guid = entry.guid,
        position = origin,
        smooth = true,
        callback_function = function(object)
            if alive(object) then
                pcall(function()
                    object.setScale({ 1, 1, 1 })
                    object.setLock(false)
                end)
            end
            finishOpen()
        end,
    })
end

function unpackPack(_, playerColor)
    if OPENING then return end
    OPENING = true
    pcall(function() self.clearButtons() end)

    local entries = self.getObjects() or {}
    if #entries == 0 then finishOpen() return end

    local origin = self.getPosition() + Vector(-4.6, 2.0, 3.2)
    local first = entries[1]

    self.takeObject({
        guid = first.guid,
        position = self.getPosition() + Vector(0, 5, 0),
        smooth = false,
        callback_function = function(object)
            if not alive(object) then finishOpen() return end
            if object.tag == "Deck" then
                pcall(function()
                    object.setLock(true)
                    object.setScale({ 2, 1, 2 })
                end)
                Wait.time(function() spreadDeck(object, origin, 1) end, 0.10)
            else
                pcall(function()
                    object.setScale({ 1, 1, 1 })
                    object.setLock(false)
                    object.setPositionSmooth(origin, false, false)
                end)
                finishOpen()
            end
        end,
    })
end

function onObjectLeaveContainer(container)
    if container ~= self then return end
    Wait.time(function()
        if alive(self) then
            local ok, quantity = pcall(function() return self.getQuantity() end)
            if ok and quantity == 0 then finishOpen() end
        end
    end, 1)
end

function onLoad()
    local entries = self.getObjects() or {}
    if #entries == 0 then return end

    self.createButton({
        label = "OPEN",
        click_function = "unpackPack",
        function_owner = self,
        position = { 0, 0.2, 0 },
        rotation = { 0, 0, 0 },
        width = 1000,
        height = 300,
        font_size = 300,
        color = { 0, 0, 0, 0.95 },
        hover_color = { 0.15, 0.15, 0.15, 1 },
        press_color = { 0.05, 0.05, 0.05, 1 },
        font_color = { 1, 1, 1, 1 },
        tooltip = "Open and spread this booster pack",
    })
end
]]

-- ============================================================
--  Pack Image Resolver
-- ============================================================

local ImageService = { cache = {} }

function ImageService.inferURL(setCode)
    local code = safeUpper(setCode)
    if code == "" or code == CONFIG.pack.defaultSetCode then return CONFIG.pack.defaultImage end
    return CONFIG.pack.imageBaseURL .. safeLower(code) .. CONFIG.pack.imageSuffix
end

function ImageService.applyToObject(object, imageURL)
    if not isObjectAlive(object) then return end
    pcall(function()
        local custom = object.getCustomObject() or {}
        custom.diffuse = imageURL or CONFIG.pack.defaultImage
        object.setCustomObject(custom)
    end)
end

function ImageService.applyToData(objectData, imageURL)
    if type(objectData) ~= "table" then return end
    if type(objectData.CustomMesh) == "table" then objectData.CustomMesh.DiffuseURL = imageURL end
    if type(objectData.CustomImage) == "table" then objectData.CustomImage.ImageURL = imageURL end
end

function ImageService.resolve(setCode, callback)
    local code = safeUpper(setCode)
    if code == "" or code == CONFIG.pack.defaultSetCode then callback(CONFIG.pack.defaultImage) return end

    local cached = ImageService.cache[code]
    if cached and cached.state == "ready" then callback(cached.url) return end
    if cached and cached.state == "loading" then table.insert(cached.waiters, callback) return end

    local requestedURL = ImageService.inferURL(code)
    local entry = { state = "loading", waiters = { callback }, url = CONFIG.pack.defaultImage }
    ImageService.cache[code] = entry
    local settled = false
    local handle = nil

    local function finish(url)
        if settled then return end
        settled = true
        entry.state = "ready"
        entry.url = url or CONFIG.pack.defaultImage
        local waiters = entry.waiters
        entry.waiters = {}
        for _, waiter in ipairs(waiters) do pcall(waiter, entry.url) end
    end

    local ok = pcall(function()
        handle = WebRequest.head(requestedURL, function(request)
            local status = tonumber(request and request.response_code) or 0
            local networkError = request and request.is_error
            finish((not networkError and status >= 200 and status < 400) and requestedURL or CONFIG.pack.defaultImage)
        end)
    end)

    if not ok then finish(CONFIG.pack.defaultImage) return end

    Wait.time(function()
        if settled then return end
        if handle and handle.dispose then pcall(function() handle.dispose() end) end
        finish(CONFIG.pack.defaultImage)
    end, CONFIG.pack.imageCheckTimeoutSeconds)
end

-- ============================================================
--  Booster Generation Job Manager
-- ============================================================

JobManager = {
    jobs = {},
    nextID = 0,
    seedOverride = CONFIG.generation.fixedSeed,
    stats = { generated = 0, failed = 0, cacheHits = 0 },
}

function JobManager:anyActive()
    return next(self.jobs) ~= nil
end

function JobManager:makeSeed(job)
    if self.seedOverride ~= nil then
        return math.floor(tonumber(self.seedOverride) or 1) + job.id
    end
    local guidHash = hashString(job.placeholderGUID or "")
    local timeValue = os.time and os.time() or 1
    return (timeValue + guidHash + (job.id * 104729)) % 2147483647
end

function JobManager:isRelevant(job)
    return self.jobs[job.id] == job and not job.finished and isObjectAlive(job.placeholder)
end

function JobManager:setStatus(job, text)
    if not self:isRelevant(job) then return end
    safeObjectCall(job.placeholder, "edit status button", function()
        job.placeholder.editButton({ index = 0, label = truncate(text, 32) })
    end)
end

function JobManager:setImageStatus(job, text)
    if not self:isRelevant(job) then return end
    safeObjectCall(job.placeholder, "edit image button", function()
        job.placeholder.editButton({ index = 1, label = truncate(text, 32) })
    end)
end

function JobManager:cleanup(job)
    RequestScheduler:cancelTag(job.tag)
    self.jobs[job.id] = nil
end

function JobManager:finishFailure(job, message, details)
    if job.finished or job.terminalResult then return end
    job.terminalResult = true
    job.contents = { DeckBuilder.errorNotecard(message, details) }
    job.errorMessage = tostring(message)
    job.contentsReady = true
    self.stats.failed = self.stats.failed + 1
    self:setStatus(job, "generation failed")
    self:tryReplace(job)
end

function JobManager:buildContents(job, spec, poolEntry)
    if job.finished or job.terminalResult then return end
    local seed = self:makeSeed(job)
    local result, generationFailure = CollationEngine.generate(spec, poolEntry, seed)
    if generationFailure then
        self:finishFailure(job, generationFailure.message or "Booster collation failed.")
        return
    end

    local deckObject, buildErrors = DeckBuilder.build(result.cards, spec.name .. " Booster")
    if not deckObject then
        self:finishFailure(job, "No TTS card objects could be built.", table.concat(buildErrors or {}, "\n"))
        return
    end

    job.spec = spec
    job.result = result
    job.terminalResult = true
    job.contents = { deckObject }
    job.contentsReady = true
    job.buildErrors = buildErrors or {}
    self:setStatus(job, "ready to seal")
    self:tryReplace(job)
end

function JobManager:replacePlaceholder(job)
    if not self:isRelevant(job) or job.replacing then return end
    job.replacing = true

    local ok, objectData = pcall(function() return job.placeholder.getData() end)
    if not ok or not objectData then
        job.finished = true
        self:cleanup(job)
        return
    end

    objectData.Locked = false
    objectData.Nickname = job.spec and (job.spec.name .. " Booster (" .. job.code .. ")") or (job.code .. " Booster")
    objectData.Description = "SET: " .. job.code
    if job.spec and job.spec.releasedAt and job.spec.releasedAt ~= "" then
        objectData.Description = objectData.Description .. "\nReleased: " .. job.spec.releasedAt
    end
    if job.result then
        objectData.Description = objectData.Description
            .. "\nProfile: " .. tostring(job.spec.profile)
            .. "\nSeed: " .. tostring(job.result.seed)
            .. (#job.result.warnings > 0 and ("\nWarnings: " .. tostring(#job.result.warnings)) or "")
    elseif job.errorMessage then
        objectData.Description = objectData.Description .. "\nERROR: " .. job.errorMessage
    end

    objectData.ContainedObjects = deepCopy(job.contents or {})
    objectData.LuaScript = PACK_LUA
    objectData.LuaScriptState = ""
    ImageService.applyToData(objectData, job.imageURL or CONFIG.pack.defaultImage)

    pcall(function() job.placeholder.destruct() end)

    local spawned = false
    local spawnOK, spawnError = pcall(function()
        spawnObjectData({
            data = objectData,
            callback_function = function(generatedPack)
                spawned = true
                if generatedPack then
                    ImageService.applyToObject(generatedPack, job.imageURL or CONFIG.pack.defaultImage)
                end
                job.finished = true
                self.stats.generated = self.stats.generated + (job.errorMessage and 0 or 1)
                self:cleanup(job)
            end,
        })
    end)

    if not spawnOK then
        job.finished = true
        logMessage("error", "Could not spawn generated booster: " .. tostring(spawnError))
        self:cleanup(job)
    end
end

function JobManager:tryReplace(job)
    if not self:isRelevant(job) or not job.contentsReady or not job.imageReady or job.replacing then return end

    local function replaceNow()
        if self:isRelevant(job) then self:replacePlaceholder(job) end
    end

    local function resting()
        if not self:isRelevant(job) then return true end
        local ok, value = pcall(function() return job.placeholder.resting end)
        return not ok or value
    end

    Wait.condition(
        replaceNow,
        resting,
        CONFIG.generation.replacementRestTimeoutSeconds,
        replaceNow
    )
end

function JobManager:start(placeholder, setCode)
    if not isObjectAlive(placeholder) then return end

    self.nextID = self.nextID + 1
    local job = {
        id = self.nextID,
        code = safeUpper(setCode),
        placeholder = placeholder,
        placeholderGUID = placeholder.getGUID(),
        tag = "booster-job:" .. tostring(self.nextID),
        startedAt = os.time and os.time() or 0,
        contentsReady = false,
        imageReady = false,
        replacing = false,
        finished = false,
        terminalResult = false,
    }
    self.jobs[job.id] = job

    placeholder.clearButtons()
    placeholder.createButton({
        label = "initializing " .. job.code,
        click_function = "noop",
        function_owner = HOST_OBJECT,
        position = { 0, 0.2, -1.6 },
        rotation = { 0, 0, 0 },
        width = 1100,
        height = 220,
        font_size = 125,
        color = { 0, 0, 0, 0.95 },
        hover_color = { 0, 0, 0, 0.95 },
        press_color = { 0, 0, 0, 0.95 },
        font_color = { 1, 1, 1, 1 },
    })
    placeholder.createButton({
        label = "checking image",
        click_function = "noop",
        function_owner = HOST_OBJECT,
        position = { 0, 0.2, 1.6 },
        rotation = { 0, 0, 0 },
        width = 1100,
        height = 220,
        font_size = 125,
        color = { 0, 0, 0, 0.95 },
        hover_color = { 0, 0, 0, 0.95 },
        press_color = { 0, 0, 0, 0.95 },
        font_color = { 1, 1, 1, 1 },
    })
    placeholder.setLuaScript("function tryObjectEnter() return false end")

    Wait.time(function()
        if self:isRelevant(job) and not job.finished then
            self:finishFailure(job, "Booster generation timed out after " .. CONFIG.generation.jobTimeoutSeconds .. " seconds.")
        end
    end, CONFIG.generation.jobTimeoutSeconds)

    ImageService.resolve(job.code, function(url)
        if not self:isRelevant(job) then return end
        job.imageURL = url
        job.imageReady = true
        ImageService.applyToObject(job.placeholder, url)
        self:setImageStatus(job, url == CONFIG.pack.defaultImage and "default image" or "image ready")
        self:tryReplace(job)
    end)

    if job.code == CONFIG.pack.defaultSetCode then
        job.spec = ProductCatalog.resolve(job.code, nil)
        job.terminalResult = true
        job.contents = { DeckBuilder.instructionNotecard() }
        job.contentsReady = true
        self:setStatus(job, "instructions ready")
        self:tryReplace(job)
        return
    end

    local initialSpec = ProductCatalog.resolve(job.code, nil)
    self:setStatus(job, "validating product")

    MetadataService.loadSpec(initialSpec, job.tag, function() return self:isRelevant(job) end, function(spec, failure)
        if not self:isRelevant(job) then return end
        if failure then
            self:finishFailure(job, failure.message or "Product validation failed.")
            return
        end

        job.spec = spec
        self:setStatus(job, "loading card pool")
        PoolService.load(
            spec,
            job.tag,
            function() return self:isRelevant(job) end,
            function(message) self:setStatus(job, message) end,
            function(poolEntry, poolFailure)
                if not self:isRelevant(job) then return end
                if poolFailure then
                    self:finishFailure(job, poolFailure.message or "Card-pool loading failed.")
                    return
                end
                self:setStatus(job, "collating pack")
                self:buildContents(job, spec, poolEntry)
            end
        )
    end)
end

-- ============================================================
--  Booster Box State and Object Behavior
-- ============================================================

local state = {
    setCode = CONFIG.pack.defaultSetCode,
    lastDescription = "",
    pollElapsed = 0,
}

local function parseSetCodeFromDescription()
    local description = self.getDescription() or ""
    local code = description:match("[Ss][Ee][Tt]:%s*([%w_%-]+)")
    return safeUpper(code or CONFIG.pack.defaultSetCode)
end

local function setBoxName()
    local initial = ProductCatalog.resolve(state.setCode, nil)
    self.setName((initial.name or state.setCode) .. " Booster Box")

    if state.setCode ~= CONFIG.pack.defaultSetCode then
        MetadataService.load(initial.sets[1], "box-name:" .. state.setCode, nil, function(meta)
            if parseSetCodeFromDescription() ~= state.setCode then return end
            local spec = ProductCatalog.resolve(state.setCode, meta)
            self.setName((spec.name or state.setCode) .. " Booster Box")
        end)
    end
end

local function updateBoxFromDescription()
    state.setCode = parseSetCodeFromDescription()
    state.lastDescription = self.getDescription() or ""
    setBoxName()
    self.clearButtons()
end

local function applyImageToCloneData(boxData, imageURL)
    ImageService.applyToData(boxData, imageURL)
end

local function spawnPreviewBoxesInternal()
    local codes = CONFIG.box.previewSetCodes or {}
    if #codes > CONFIG.generation.maximumPreviewBoxes then
        broadcast(nil, "Preview list exceeds the configured maximum of " .. CONFIG.generation.maximumPreviewBoxes .. ".", "error")
        return
    end

    local ok, template = pcall(function() return self.getData() end)
    if not ok or not template then return end

    local origin = self.getPosition() + Vector(CONFIG.box.previewSpacingX, 0, 0)
    local columns = math.max(1, CONFIG.box.previewColumns)

    for index, rawCode in ipairs(codes) do
        Wait.time(function()
            local code = safeUpper(rawCode)
            local spec = ProductCatalog.resolve(code, nil)
            local row = math.floor((index - 1) / columns)
            local column = (index - 1) % columns
            local dataCopy = deepCopy(template)

            dataCopy.Nickname = (spec.name or code) .. " Booster Box"
            dataCopy.Description = "SET: " .. code
            dataCopy.LuaScriptState = ""
            dataCopy.Locked = false
            dataCopy.Transform.posX = origin.x + column * CONFIG.box.previewSpacingX
            dataCopy.Transform.posY = origin.y
            dataCopy.Transform.posZ = origin.z - row * CONFIG.box.previewSpacingZ

            if not CONFIG.box.previewCloneContents then dataCopy.ContainedObjects = {} end

            ImageService.resolve(code, function(imageURL)
                applyImageToCloneData(dataCopy, imageURL)
                spawnObjectData({ data = dataCopy })
            end)
        end, (index - 1) * 0.05)
    end
end

function spawnPreviewBoxes(playerColor)
    spawnPreviewBoxesInternal()
end

function spawnSupportedPacks(playerColor)
    spawnPreviewBoxesInternal()
end

function clearBoosterCaches(playerColor)
    PoolService.clear()
    MetadataService.clear()
    ImageService.cache = {}
    if playerColor then broadcast(playerColor, "Booster caches cleared.", "success") end
end

function checkBoosterUpdate(playerColor)
    AutoUpdater:checkForUpdate(playerColor)
end

function noop()
end

function onObjectLeaveContainer(container, object)
    if container ~= self or not isObjectAlive(object) then return end

    local code = state.setCode
    local spec = ProductCatalog.resolve(code, nil)
    object.setName((spec.name or code) .. " Booster (" .. code .. ")")
    object.setDescription("SET: " .. code)
    JobManager:start(object, code)
end

function onUpdate()
    state.pollElapsed = state.pollElapsed + Time.delta_time
    if state.pollElapsed < CONFIG.box.descriptionPollSeconds then return end
    state.pollElapsed = 0

    local description = self.getDescription() or ""
    if description ~= state.lastDescription then updateBoxFromDescription() end
end

function onSave()
    return safeEncode({
        version = SCRIPT_VERSION,
        setCode = state.setCode,
        seedOverride = JobManager.seedOverride,
        stats = JobManager.stats,
    }) or ""
end

function onLoad(savedData)
    HOST_OBJECT = self
    local saved = safeDecode(savedData or "")
    if saved then
        JobManager.seedOverride = saved.seedOverride
        if type(saved.stats) == "table" then JobManager.stats = mergeTables(JobManager.stats, saved.stats) end
    end

    updateBoxFromDescription()
    self.addContextMenuItem("Spawn Preview Boxes", spawnPreviewBoxes)
    self.addContextMenuItem("Clear Booster Cache", clearBoosterCaches)
    self.addContextMenuItem("Check for Updates", checkBoosterUpdate)
    AutoUpdater:run(self)

    if CONFIG.generation.prefetchCurrentSetOnLoad and state.setCode ~= CONFIG.pack.defaultSetCode then
        local spec = ProductCatalog.resolve(state.setCode, nil)
        MetadataService.loadSpec(spec, "prefetch:" .. state.setCode, nil, function(resolved)
            if resolved then PoolService.load(resolved, "prefetch:" .. state.setCode, nil, nil, function() end) end
        end)
    end
end

function onDestroy()
    for _, job in pairs(JobManager.jobs) do
        job.finished = true
        RequestScheduler:cancelTag(job.tag)
    end
    JobManager.jobs = {}
end

function onChat(message, player)
    local text = trim(message)
    local command, argument = text:match("^!booster%s+(%S+)%s*(.-)%s*$")
    if not command then return end
    command = safeLower(command)

    if command == "status" then
        local cacheReady = 0
        for _, entry in pairs(PoolService.cache) do if entry.state == "ready" then cacheReady = cacheReady + 1 end end
        broadcast(player and player.color or nil,
            "Set " .. state.setCode .. " | active jobs " .. tableCount(JobManager.jobs) ..
            " | cached pools " .. cacheReady .. " | generated " .. JobManager.stats.generated ..
            " | failed " .. JobManager.stats.failed,
            "info"
        )
        return false
    end

    if not playerCanAdmin(player) then
        broadcast(player and player.color or nil, "Only a host, admin, or promoted player can use that booster command.", "error")
        return false
    end

    if command == "set" then
        local code = safeUpper(argument)
        if code == "" then
            broadcast(player.color, "Usage: !booster set FIN", "warning")
        else
            self.setDescription("SET: " .. code)
            updateBoxFromDescription()
            broadcast(player.color, "Booster product changed to " .. code .. ".", "success")
        end
    elseif command == "preview" then
        spawnPreviewBoxesInternal()
    elseif command == "clearcache" then
        clearBoosterCaches(player.color)
    elseif command == "seed" then
        local normalized = safeLower(trim(argument))
        if normalized == "" or normalized == "random" or normalized == "off" then
            JobManager.seedOverride = nil
            broadcast(player.color, "Booster seed override disabled.", "success")
        else
            local seed = tonumber(argument)
            if not seed then
                broadcast(player.color, "Seed must be an integer or 'random'.", "error")
            else
                JobManager.seedOverride = math.floor(seed)
                broadcast(player.color, "Booster seed override set to " .. tostring(JobManager.seedOverride) .. ".", "success")
            end
        end
    elseif command == "update" then
        AutoUpdater:checkForUpdate(player.color)
    else
        broadcast(player.color, "Commands: set, status, preview, clearcache, seed, update", "info")
    end

    return false
end

isSystemBusy = function()
    return JobManager:anyActive() or RequestScheduler:isBusy()
end
