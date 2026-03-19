local AutoUpdater = {
    name = "Razormate's MTG Booster Generator",
    version = "1.0.0",
    versionUrl = "https://raw.githubusercontent.com/Razormate88/MTG-Booster-Generator/refs/heads/main/MTG-Booster-Generator.ver",
    scriptUrl = "https://raw.githubusercontent.com/Razormate88/MTG-Booster-Generator/refs/heads/main/MTG-Booster-Generator.lua",
    debug = false,

    run = function(self, host)
        self.host = host
        if not self.host then
            self:error("host not set")
            return
        end
        self:checkForUpdate()
    end,

    checkForUpdate = function(self)
        WebRequest.get(self.versionUrl, function(request)
            if request.response_code ~= 200 then
                self:error("Failed to check version (" .. tostring(request.response_code) .. ": " .. tostring(request.error) .. ")")
                return
            end

            local remoteVersion = (request.text or ""):match("[^\r\n]+") or ""
            remoteVersion = remoteVersion:gsub("^%s+", ""):gsub("%s+$", "")

            if remoteVersion ~= "" and self:isNewerVersion(remoteVersion) then
                self:fetchNewScript(remoteVersion)
            end
        end)
    end,

    isNewerVersion = function(self, remoteVersion)
        local function splitVersion(v)
            local parts = {}
            for num in tostring(v or ""):gmatch("(%d+)") do
                table.insert(parts, tonumber(num) or 0)
            end
            return parts
        end

        local remoteParts = splitVersion(remoteVersion)
        local localParts = splitVersion(self.version)
        local maxLen = math.max(#remoteParts, #localParts)

        for i = 1, maxLen do
            local rv = remoteParts[i] or 0
            local lv = localParts[i] or 0
            if rv > lv then return true end
            if rv < lv then return false end
        end

        return false
    end,

    fetchNewScript = function(self, newVersion)
        WebRequest.get(self.scriptUrl, function(request)
            if request.response_code ~= 200 then
                self:error("Failed to fetch new script (" .. tostring(request.response_code) .. ": " .. tostring(request.error) .. ")")
                return
            end

            local newScript = request.text or ""
            if newScript == "" then
                self:error("New script is empty")
                return
            end

            self.host.setLuaScript(newScript)
            self:print("Updated to version " .. tostring(newVersion))

            Wait.condition(function()
                if self.host then
                    self.host.reload()
                end
            end, function()
                return not self.host or self.host.resting
            end)
        end)
    end,

    print = function(self, message)
        print(self.name .. ": " .. tostring(message))
    end,

    error = function(self, message)
        if self.debug then
            error(self.name .. ": " .. tostring(message))
        else
            print(self.name .. " ERROR: " .. tostring(message))
        end
    end,
}








local config = {
    backURL = 'https://steamusercontent-a.akamaihd.net/ugc/1647720103762682461/35EF6E87970E2A5D6581E7D96A99F8A575B7A15F/',
    apiBaseURL = 'https://api.scryfall.com/cards/random?q=',
    apiSearchBaseURL = 'https://api.scryfall.com/cards/search?q=',
    apiSetBaseURL = 'https://api.scryfall.com/sets/',
    defaultPackImage = "https://cdn.jsdelivr.net/gh/Razormate88/MTG-Booster-Generator/pack-images/razor-booster-pack.jpg?v=20260319-2",
    defaultSetCode = "???",
    pollInterval = 0.25,
    maxDedupeAttempts = 8,
    requestRetryAttempts = 2,

    -- request pacing / smoothness
    requestSpacingSeconds = 0.1,
    dedupeRetrySpacingSeconds = 0.1,
    pageRequestSpacingSeconds = 0.1,

    -- image fallback
    packImageCheckTimeout = 8,

    -- Dynamic pack image lookup:
    -- FIN -> imageBaseUrl .. "fin" .. imageExtension
    imageBaseUrl = "https://cdn.jsdelivr.net/gh/Razormate88/MTG-Booster-Generator/pack-images/",
    imageExtension = ".jpg?v=20260319-2",

    -- Curated preview boxes only
    previewSetCodes = {
        "TMT", "ECL", "TLA", "SPM", "PIP", "EOE", "FIN", "REX", "TDM", "DFT", "INR", "FDN", "DSK", "BLB", "MB2", "ACR", "MH3", "OTJ", "MKM",
        "RVR"
    },

    previewColumns = 19,
    previewSpacingX = 2.75,
    previewSpacingZ = 4.75,
}

local data = {
    setCode = "???",
    boosterCount = 0,
    timePassed = 0,
    lastDescription = "",
    requestQueue = {},

    validation = {
        code = nil,
        state = "unknown", -- unknown | pending | valid | invalid
        meta = nil,
        message = nil,
    },
}

local packLua = [[
local defaultSetCode = "???"
local defaultPack = "https://cdn.jsdelivr.net/gh/Razormate88/MTG-Booster-Generator/pack-images/razor-booster-pack.jpg?v=20260319-2"

function tryObjectEnter()
    return false
end

function onObjectLeaveContainer(container)
    if container ~= self then
        return
    end

    Wait.condition(function()
        Wait.time(function()
            if container then
                container.destruct()
            end
        end, 1)
    end, function()
        return container and container.getQuantity() == 0
    end)
end

function onLoad()
    local setCode = string.upper(self.getDescription()):match("SET:%s*(%S+)") or self.getName():match("^(.-)%s+Booster$")
    local custom = self.getCustomObject() or {}

    if custom.diffuse == defaultPack then
        self.createButton({
            label = setCode and (setCode .. " Booster") or self.getName(),
            click_function = 'noop',
            function_owner = self,
            position = { 0, 0.2, -5 },
            rotation = { 0, 0, 0 },
            width = 1000,
            height = 200,
            font_size = 150,
            color = { 0, 0, 0, 1 },
            hover_color = { 1, 1, 1, 1 },
            press_color = { 0, 1, 0, 1 },
            font_color = { 1, 1, 1, 1 },
        })
    end

    if setCode ~= defaultSetCode and #self.getObjects() > 0 then
        self.createButton({
            label = "OPEN",
            click_function = "unpackDeck",
            function_owner = self,
            position = { 0, 0.2, 0 },
            rotation = { 0, 0, 0 },
            width = 1000,
            height = 300,
            font_size = 300,
            color = { 0, 0, 0, 1 },
            hover_color = { 0, 0, 0, 1 },
            press_color = { 0, 0, 0, 1 },
            font_color = { 1, 1, 1, 1 },
        })
    end
end

function unpackDeck()
    local contained = self.getObjects()
    if #contained == 0 then
        return
    end

    local entryGuid = contained[1].guid
    local takePos = self.getPosition() + Vector(0, 6, 0)
    local deck = self.takeObject({ guid = entryGuid, position = takePos, smooth = true })
    if not deck then
        return
    end

    deck.setLock(true)
    deck.setScale({ 2, 1, 2 })

    Wait.time(function()
        spreadDeck(deck)
    end, 0.1)
end

function spreadDeck(deck)
    if not deck then
        return
    end

    local startPos = self.getPosition() + Vector(-2.3 * 2, 2, 3.2)
    local colCount = 5
    local spacingX = 2.25
    local spacingZ = 3.1
    local total = 1

    if deck.tag == "Deck" then
        total = deck.getQuantity()
    end

    for index = 1, total do
        Wait.time(function()
            local row = math.floor((index - 1) / colCount)
            local col = (index - 1) % colCount
            local pos = startPos + Vector(col * spacingX, 2, -row * spacingZ)

            if deck.tag == "Deck" then
                local card = deck.takeObject({ position = pos, smooth = true })
                Wait.time(function()
                    if card then
                        card.setScale({ 1, 1, 1 })
                    end
                end, 0.05)

                if deck.remainder then
                    deck = deck.remainder
                    deck.setLock(true)
                end
            else
                deck.setScale({ 1, 1, 1 })
                deck.setLock(false)
                deck.setPositionSmooth(pos, false, false)
            end
        end, index * 0.8)
    end

    self.destruct()
end

function noop()
end
]]


local BuiltInOverrides = {
    ['???'] = { profile = 'empty', preview = false },

    -- custom / mixed products
    -- Regular play boosters use only the primary set so no cards from secondary
    -- art/promo sets bleed in.  Collector boosters intentionally include them.
    TMT  = { profile = 'play14', sets = { 'TMT' },              name = "Teenage Mutant Ninja Turtles" },
    TMTC = { profile = 'collector_custom', sets = { 'TMT', 'PZA' }, name = "Teenage Mutant Ninja Turtles Collector" },
    TMTT = { profile = 'spawn_all', sets = { 'TMTT' }, category = 'tokens', name = "Teenage Mutant Ninja Turtles Tokens" },

    TLA  = { profile = 'play14', sets = { 'TLA' },              name = "Avatar: The Last Airbender" },
    TLAC = { profile = 'collector_custom', sets = { 'TLA', 'TLE' }, name = "Avatar: The Last Airbender Collector" },

    SPM  = { profile = 'play14', sets = { 'SPM' },              name = "Marvel's Spider-Man" },
    SPMC = { profile = 'collector_custom', sets = { 'SPM', 'MAR', 'SPE' }, name = "Marvel's Spider-Man Collector" },

    FIN  = { profile = 'play14', sets = { 'FIN' },              name = "Final Fantasy" },
    FINC = { profile = 'collector_custom', sets = { 'FIN', 'FCA', 'FIC' }, name = "Final Fantasy Collector" },

    -- special profiles
    STX = { profile = 'strixhaven_play' },
    MID = { profile = 'transform_slot' },
    VOW = { profile = 'transform_slot' },
    DKA = { profile = 'transform_slot' },
    ISD = { profile = 'transform_slot' },
    SOI = { profile = 'transform_slot' },
    EMN = { profile = 'transform_slot' },
    KHM = { profile = 'snow_slot' },
    CNS = { profile = 'conspiracy' },
    CN2 = { profile = 'conspiracy' },
    LEA = { profile = 'alpha15', name = "Limited Edition Alpha" },
    MB1 = { profile = 'mystery_playtest' },
    CMM = { profile = 'default20', name = "Commander Masters" },
    CLB = { profile = 'default20' },
    CMR = { profile = 'default20' },

    -- tokens / art / small weird sets
    TOK   = { profile = 'spawn_all', category = 'tokens' },
    TDFT  = { profile = 'spawn_all', category = 'tokens' },
    TMKM  = { profile = 'spawn_all', category = 'tokens' },
    TOTJ  = { profile = 'spawn_all', category = 'tokens' },
    TMH3  = { profile = 'spawn_all', category = 'tokens' },
    TBLB  = { profile = 'spawn_all', category = 'tokens' },
    TDSK  = { profile = 'spawn_all', category = 'tokens' },
    TFDN  = { profile = 'spawn_all', category = 'tokens' },
    TINR  = { profile = 'spawn_all', category = 'tokens' },
    TDRC  = { profile = 'spawn_all', category = 'tokens' },
    TPLST = { profile = 'spawn_all', category = 'tokens' },

    TAR   = { profile = 'spawn_all', category = 'art_series' },
    OARC  = { profile = 'spawn_all', category = 'art_series' },
    ADFT  = { profile = 'spawn_all', category = 'art_series' },
    AMKM  = { profile = 'spawn_all', category = 'art_series' },
    AOTJ  = { profile = 'spawn_all', category = 'art_series' },
    AMH3  = { profile = 'spawn_all', category = 'art_series' },
    ABLB  = { profile = 'spawn_all', category = 'art_series' },
    ADSK  = { profile = 'spawn_all', category = 'art_series' },
    AFDN  = { profile = 'spawn_all', category = 'art_series' },
}

local function safeUpper(value)
    return string.upper(tostring(value or ""))
end

local function shallowCopy(tbl)
    local out = {}
    for k, v in pairs(tbl or {}) do
        out[k] = v
    end
    return out
end

local function mergeTables(base, override)
    local merged = shallowCopy(base or {})
    for k, v in pairs(override or {}) do
        if type(v) == "table" and type(merged[k]) == "table" then
            local nested = shallowCopy(merged[k])
            for nk, nv in pairs(v) do
                nested[nk] = nv
            end
            merged[k] = nested
        else
            merged[k] = v
        end
    end
    return merged
end

local function normalizeSetList(list, fallback)
    local out = {}
    local seen = {}
    if type(list) ~= "table" then
        return { safeUpper(fallback) }
    end
    for _, value in ipairs(list) do
        local code = safeUpper(value)
        if code ~= "" and not seen[code] then
            seen[code] = true
            table.insert(out, code)
        end
    end
    if #out == 0 then
        return { safeUpper(fallback) }
    end
    return out
end

local function urlEncode(str)
    str = tostring(str or "")
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w %-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end

local function joinQueries(parts)
    local out = {}
    for _, part in ipairs(parts or {}) do
        if part and part ~= "" then
            table.insert(out, part)
        end
    end
    return table.concat(out, " ")
end

local function scryfallSetClause(sets)
    local clauses = {}
    for _, code in ipairs(sets or {}) do
        table.insert(clauses, "set:" .. string.lower(code))
    end
    if #clauses == 0 then
        return ""
    elseif #clauses == 1 then
        return clauses[1]
    end
    return "(" .. table.concat(clauses, " OR ") .. ")"
end

-- FIX 1: return default image immediately for "???" or any missing/empty code
-- This prevents the malformed ???.jpg URL from ever being built or requested
local function inferPackImageUrl(setCode)
    if not setCode or setCode == "" or setCode == config.defaultSetCode then
        return config.defaultPackImage
    end
    if not config.imageBaseUrl or config.imageBaseUrl == "" then
        return config.defaultPackImage
    end
    return config.imageBaseUrl .. string.lower(setCode) .. config.imageExtension
end


-- FIX 2: silent fallback — no print, no reload() on leaveObject
-- Removing obj.reload() here is intentional: the image is captured by getData()
-- when the final booster is spawned, so reload() on the temp object is unnecessary
-- AND causes a destroyed-object crash when the async callback fires late
local function applyPackImage(obj, imageUrl)
    if not obj then return end
    local url = imageUrl or config.defaultPackImage
    pcall(function()
        obj.setCustomObject({ diffuse = url })
    end)
end

-- FIX 3: silent fallback — swallow missing-image case without printing anything
local function resolvePackImageUrl(setCode, callback)
    local requestedUrl = inferPackImageUrl(setCode)

    if not requestedUrl or requestedUrl == "" then
        if callback then callback(config.defaultPackImage) end
        return
    end

    if requestedUrl == config.defaultPackImage then
        if callback then callback(config.defaultPackImage) end
        return
    end

    WebRequest.get(requestedUrl, function(request)
        local ok = request
            and tonumber(request.response_code or 0) == 200
            and not tostring(request.error or ""):match("%S")

        if ok then
            if callback then callback(requestedUrl) end
        else
            -- Silent fallback — no print, just use the default
            if callback then callback(config.defaultPackImage) end
        end
    end)
end


local function makeHeaders()
    return {
        ["User-Agent"] = "Razormate MTG Booster Generator",
        ["Accept"] = "application/json",
    }
end

BoosterUrls = {}

BoosterUrls.reverseTable = function(tbl)
    local out = {}
    for i = #tbl, 1, -1 do
        table.insert(out, tbl[i])
    end
    return out
end

BoosterUrls.default15CardPack = function(sets)
    local setClause = scryfallSetClause(sets)
    return {
        joinQueries({ setClause, 'r:mythic' }),
        joinQueries({ setClause, 'r:rare' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
    }
end

BoosterUrls.default14CardPack = function(sets)
    local setClause = scryfallSetClause(sets)
    return {
        joinQueries({ setClause, 'r:mythic' }),
        joinQueries({ setClause, 'r:rare' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
    }
end

BoosterUrls.default20CardPack = function(sets)
    local setClause = scryfallSetClause(sets)
    local out = {}
    for _ = 1, 13 do
        table.insert(out, joinQueries({ setClause, 'r:common' }))
    end
    for _ = 1, 6 do
        table.insert(out, joinQueries({ setClause, 'r:uncommon' }))
    end
    table.insert(out, joinQueries({ setClause, '(r:rare OR r:mythic)' }))
    return out
end

BoosterUrls.collectorCustomPack = function(sets)
    local setClause = scryfallSetClause(sets)
    local flex = '(r:common OR r:uncommon OR r:rare OR r:mythic)'
    return {
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, flex }),
        joinQueries({ setClause, '(r:uncommon OR r:rare OR r:mythic)' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
    }
end

BoosterUrls.strixhavenPlayPack = function(sets)
    local setClause = scryfallSetClause(sets)
    return {
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ '(set:sta OR ' .. setClause .. ')', '-is:lesson' }),
        joinQueries({ setClause, 'is:lesson' }),
    }
end

BoosterUrls.conspiracyPack = function(sets)
    local setClause = scryfallSetClause(sets)
    return {
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ setClause, 'is:conspiracy' }),
        joinQueries({ setClause, '(r:common OR r:uncommon OR r:rare OR r:mythic)' }),
    }
end

BoosterUrls.alpha15Pack = function(sets)
    local setClause = scryfallSetClause(sets)
    return {
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:rare' }),
    }
end

BoosterUrls.mysteryPlaytestPack = function(sets)
    local setClause = scryfallSetClause(sets)
    return {
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:common' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, 'r:uncommon' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ setClause, '(r:rare OR r:mythic)' }),
        joinQueries({ setClause, '(frame:future OR is:playtest)' }),
        joinQueries({ setClause, 't:land' }),
    }
end

-- Proper MTG Play Booster — exactly 14 cards with correct rarity probabilities.
--
-- Slot breakdown (always sums to 14):
--   rareCount   rare/mythic slots  (1–5, probabilistic)
--   3           uncommon slots
--   1           land slot          (t:land from set)
--   1           foil slot          (<1% borderless mythic, else any rarity)
--   9-rareCount common slots
--
-- Rarity odds (matching official Play Booster sheet):
--   ~71.7%  → 1 rare/mythic
--   ~25%    → 2 rares/mythics
--   ~3%     → 3 rares/mythics
--   <1%     → 4–5 rares/mythics
BoosterUrls.play14Booster = function(sets)
    local setClause = scryfallSetClause(sets)
    local slots = {}

    -- Determine rare/mythic count
    local rareCount = 1
    local r = math.random()
    if r < 0.003 then
        rareCount = (math.random() < 0.5) and 4 or 5   -- <1 %: 4 or 5
    elseif r < 0.033 then
        rareCount = 3                                    -- 3 %
    elseif r < 0.283 then
        rareCount = 2                                    -- 25 %
    end
    -- else: rareCount = 1  (~71.7 %)

    -- Rare / Mythic slots — exclude lands so a dual-land-with-rare-rarity
    -- doesn't eat a rare slot AND bloat the land count
    for _ = 1, rareCount do
        table.insert(slots, joinQueries({ setClause, '(r:rare OR r:mythic) -t:land' }))
    end

    -- 3 Uncommons — exclude lands
    for _ = 1, 3 do
        table.insert(slots, joinQueries({ setClause, 'r:uncommon -t:land' }))
    end

    -- 1 dedicated Land slot (always present)
    table.insert(slots, joinQueries({ setClause, 't:land' }))

    -- 1 Foil slot:
    --   20% → foil land  (gives the maximum possible 2 lands: 1 regular + 1 foil)
    --   <1% → foil borderless mythic (non-land)
    --   else → foil card of any rarity, explicitly not a land
    local foilRoll = math.random()
    if foilRoll < 0.20 then
        -- Traditional Foil Land (20 % of boosters)
        table.insert(slots, joinQueries({ setClause, 't:land' }))
    elseif foilRoll < 0.21 then
        -- Foil Borderless Mythic (<1 %)
        table.insert(slots, joinQueries({ setClause, 'r:mythic is:borderless -t:land' }))
    else
        -- Standard foil — any rarity, never a land
        table.insert(slots, joinQueries({ setClause, '(r:common OR r:uncommon OR r:rare OR r:mythic) -t:land' }))
    end

    -- Commons fill remaining slots so total is always 14.
    -- rareCount + 3 uncommons + 1 land + 1 foil + commonCount = 14
    -- → commonCount = 9 - rareCount
    local commonCount = math.max(0, 9 - rareCount)
    for _ = 1, commonCount do
        -- Exclude lands — r:common includes basic lands in many sets
        table.insert(slots, joinQueries({ setClause, 'r:common -t:land' }))
    end

    return slots
end

Profiles = {}
Profiles.empty = function(spec) return {} end
Profiles.play14 = function(spec) return BoosterUrls.play14Booster(spec.sets) end
Profiles.default15 = function(spec) return BoosterUrls.default15CardPack(spec.sets) end
Profiles.default14 = function(spec) return BoosterUrls.default14CardPack(spec.sets) end
Profiles.default20 = function(spec) return BoosterUrls.default20CardPack(spec.sets) end
Profiles.collector_custom = function(spec) return BoosterUrls.collectorCustomPack(spec.sets) end
Profiles.strixhaven_play = function(spec) return BoosterUrls.strixhavenPlayPack(spec.sets) end
Profiles.conspiracy = function(spec) return BoosterUrls.conspiracyPack(spec.sets) end
Profiles.alpha15 = function(spec) return BoosterUrls.alpha15Pack(spec.sets) end
Profiles.mystery_playtest = function(spec) return BoosterUrls.mysteryPlaytestPack(spec.sets) end
Profiles.spawn_all = function(spec) return {} end

Profiles.transform_slot = function(spec)
    local base = BoosterUrls.default15CardPack(spec.sets)
    base[7] = joinQueries({ scryfallSetClause(spec.sets), 'is:transform' })
    return base
end

Profiles.snow_slot = function(spec)
    local base = BoosterUrls.default15CardPack(spec.sets)
    base[15] = joinQueries({ scryfallSetClause(spec.sets), 'type:basic is:snow' })
    return base
end

PackBuilder = {
    cache = {},
}

PackBuilder.safeDecode = function(text)
    if not text or text == "" then
        return nil
    end
    local ok, decoded = pcall(JSON.decode, text)
    if ok then
        return decoded
    end
    return nil
end

PackBuilder.generateErrorNotecard = function(errorInfo)
    return {
        Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 2, scaleY = 2, scaleZ = 1 },
        Name = "Notecard",
        Nickname = "Booster Generation Error",
        Description = tostring(errorInfo.message or "Unknown error"),
        Grid = false,
        Snap = false
    }
end

PackBuilder.generateInstructionNotecard = function()
    return {
        Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 2, scaleZ = 1 },
        Name = "Notecard",
        Nickname = "MTG Booster Generator",
        Description = "Set the box description like:\nSET: FIN\n\nIf the set code is invalid, an error card will be generated.",
        Grid = false,
        Snap = false
    }
end

-- Returns the formatted card name with type line and CMC — matches the original.
PackBuilder.formattedName = function(face, typeSuffix)
    return string.format(
        '%s\n%s CMC %s%s',
        (face.name or ""):gsub('"', ''),
        face.type_line or "",
        tostring(face.cmc or 0),
        typeSuffix and (" " .. typeSuffix) or ""
    ):gsub('%s+$', '')
end

-- Returns oracle text plus power/toughness or loyalty — matches the original.
PackBuilder.getCardOracleText = function(cardFace)
    local pt = ""
    if cardFace.power then
        pt = '\n[b]' .. cardFace.power .. '/' .. cardFace.toughness .. '[/b]'
    elseif cardFace.loyalty then
        pt = '\n[b]' .. tostring(cardFace.loyalty) .. '[/b]'
    end
    return (cardFace.oracle_text or "") .. pt
end

-- Builds the full TTS card data from a Scryfall card object.
-- Uses large-quality images, formatted names, oracle text descriptions,
-- DFC States, and a cache-buster for non-highres scans — exactly as the original did.
PackBuilder.createCardDataFromCardObject = function(card, cardIndex)
    if not card or not card.name then
        return nil
    end

    local imageQuality = 'large'
    local cacheBuster  = (card.image_status ~= 'highres_scan') and ('?' .. os.date("%Y%m%d")) or ""

    local cardName, cardOracle, faceURL, backData

    if card.card_faces then
        if card.image_uris then
            -- Flip / adventure / split — single image, multiple faces
            cardName = PackBuilder.formattedName(card.card_faces[1])
            cardOracle = ""
            for i, face in ipairs(card.card_faces) do
                cardOracle = cardOracle .. PackBuilder.formattedName(face) .. '\n' .. PackBuilder.getCardOracleText(face)
                if i < #card.card_faces then cardOracle = cardOracle .. '\n' end
            end
            faceURL = card.image_uris.normal:gsub('%?.*', ''):gsub('normal', imageQuality) .. cacheBuster
        else
            -- True double-faced (transform / modal DFC) — two separate images
            local face = card.card_faces[1]
            local back = card.card_faces[2]
            cardName   = PackBuilder.formattedName(face, 'DFC')
            cardOracle = PackBuilder.getCardOracleText(face)
            faceURL    = face.image_uris.normal:gsub('%?.*', ''):gsub('normal', imageQuality) .. cacheBuster
            local backURL      = back.image_uris.normal:gsub('%?.*', ''):gsub('normal', imageQuality) .. cacheBuster
            local backIndex    = cardIndex + 100
            backData = {
                Transform  = { posX=0, posY=0, posZ=0, rotX=0, rotY=0, rotZ=0, scaleX=1, scaleY=1, scaleZ=1 },
                Name       = "Card",
                Nickname   = PackBuilder.formattedName(back, 'DFC'),
                Description = PackBuilder.getCardOracleText(back),
                Memo       = card.oracle_id,
                CardID     = backIndex * 100,
                CustomDeck = {
                    [backIndex] = {
                        FaceURL = backURL, BackURL = config.backURL,
                        NumWidth = 1, NumHeight = 1,
                        Type = 0, BackIsHidden = true, UniqueBack = false,
                    }
                }
            }
        end
    else
        -- Normal single-faced card
        cardName   = PackBuilder.formattedName(card)
        cardOracle = PackBuilder.getCardOracleText(card)
        faceURL    = card.image_uris.normal:gsub('%?.*', ''):gsub('normal', imageQuality) .. cacheBuster
    end

    local cardData = {
        Transform  = { posX=0, posY=0, posZ=0, rotX=0, rotY=0, rotZ=0, scaleX=1, scaleY=1, scaleZ=1 },
        Name       = "Card",
        Nickname   = cardName,
        Description = cardOracle,
        Memo       = card.oracle_id,
        CardID     = cardIndex * 100,
        CustomDeck = {
            [cardIndex] = {
                FaceURL = faceURL, BackURL = config.backURL,
                NumWidth = 1, NumHeight = 1,
                Type = 0, BackIsHidden = true, UniqueBack = false,
            }
        }
    }

    if backData then
        cardData.States = { [2] = backData }
    end

    return cardData
end

PackBuilder.getRandomPackImage = function(setCode)
    return inferPackImageUrl(setCode)
end

PackBuilder.applyResolvedPackImage = function(obj, setCode, callback)
    resolvePackImageUrl(setCode, function(finalUrl)
        if obj then
            applyPackImage(obj, finalUrl)
        end
        if callback then
            callback(finalUrl)
        end
    end)
end

local function inferProfileFromMeta(meta)
    if not meta then
        return "play14"
    end

    local setType = string.lower(meta.set_type or "")
    local cardCount = tonumber(meta.card_count or 0) or 0

    if setType == "token" or setType == "memorabilia" then
        return "spawn_all"
    end

    if cardCount > 0 and cardCount < 14 then
        return "spawn_all"
    end

    if setType == "commander" then
        return "default20"
    end

    return "play14"
end

local function resolveSetSpec(setCode)
    local code = safeUpper(setCode)
    local override = BuiltInOverrides[code] or {}
    local meta = nil

    if data.validation.code == code and data.validation.state == "valid" then
        meta = data.validation.meta
    end

    local spec = {
        code = code,
        name = (meta and meta.name) or code,
        date = (meta and meta.released_at) or "",
        set_type = (meta and meta.set_type) or "",
        card_count = tonumber((meta and meta.card_count) or 0) or 0,
        sets = { code },
        profile = inferProfileFromMeta(meta),
        category = nil,
        image = inferPackImageUrl(code),
        spawnAll = false,
    }

    spec = mergeTables(spec, override)
    spec.sets = normalizeSetList(spec.sets, code)
    spec.spawnAll = spec.profile == "spawn_all"

    return spec
end

BoosterUrls.getSetUrls = function(setCode)
    local spec = resolveSetSpec(setCode)
    local builder = Profiles[spec.profile] or Profiles.play14
    return BoosterUrls.reverseTable(builder(spec))
end

local function validateSetCode(code, callback)
    local upper = safeUpper(code)

    if upper == "" or upper == config.defaultSetCode then
        data.validation.code = upper
        data.validation.state = "unknown"
        data.validation.meta = nil
        data.validation.message = nil
        if callback then callback(false, nil) end
        return
    end

    if data.validation.code == upper and data.validation.state == "valid" then
        if callback then callback(true, data.validation.meta) end
        return
    end

    if data.validation.code == upper and data.validation.state == "invalid" then
        if callback then callback(false, nil) end
        return
    end

    data.validation.code = upper
    data.validation.state = "pending"
    data.validation.meta = nil
    data.validation.message = nil

    local url = config.apiSetBaseURL .. string.lower(upper)
    WebRequest.custom(url, "GET", true, nil, makeHeaders(), function(request)
        if data.validation.code ~= upper then
            return
        end

        if request.response_code ~= 200 then
            data.validation.state = "invalid"
            data.validation.meta = nil
            data.validation.message = "Set code not found on Scryfall."
            if callback then callback(false, nil) end
            return
        end

        local parsed = PackBuilder.safeDecode(request.text or "")
        if not parsed or parsed.object == "error" or not parsed.code then
            data.validation.state = "invalid"
            data.validation.meta = nil
            data.validation.message = "Set code not found on Scryfall."
            if callback then callback(false, nil) end
            return
        end

        data.validation.state = "valid"
        data.validation.meta = parsed
        data.validation.message = nil
        if callback then callback(true, parsed) end
    end)
end

PackBuilder.fetchDeckData = function(boosterID, setCode, urls, leaveObject, attempts, existingDeck, replaceIndices, originalUrls)
    attempts = attempts or 0
    originalUrls = originalUrls or urls

    local deck = existingDeck or {
        Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 180, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1 },
        Name = "Deck",
        Nickname = setCode .. " Booster",
        DeckIDs = {},
        CustomDeck = {},
        ContainedObjects = {},
    }

    local requestsPending = #urls
    local requestsCompleted = 0
    local requestErrors = {}

    if requestsPending == 0 then
        PackBuilder.cache[boosterID] = { PackBuilder.generateInstructionNotecard() }
        return
    end

    local function finishRequest()
        requestsCompleted = requestsCompleted + 1
        local remaining = requestsPending - requestsCompleted
        local label = "remaining: " .. remaining
        if attempts > 0 then
            label = "deduping: " .. attempts .. ": " .. remaining
        end
        if leaveObject then
            pcall(function()
                leaveObject.editButton({ index = 1, label = label })
            end)
        end
    end

    for j, query in ipairs(urls) do
        Wait.time(function()
            local i = replaceIndices and replaceIndices[j] or j
            local url = config.apiBaseURL .. urlEncode(query)

            WebRequest.custom(url, "GET", true, nil, makeHeaders(), function(request)
                if request.response_code == 200 then
                    local parsed = PackBuilder.safeDecode(request.text or "")
                    if parsed and parsed.object ~= "error" then
                        local cardData = PackBuilder.createCardDataFromCardObject(parsed, i)
                        if cardData then
                            deck.ContainedObjects[i] = cardData
                            deck.DeckIDs[i] = cardData.CardID
                            deck.CustomDeck[i] = cardData.CustomDeck[i]
                        else
                            table.insert(requestErrors, { message = "Failed to decode card data." })
                        end
                    else
                        table.insert(requestErrors, { message = "Scryfall returned an error for a card request." })
                    end
                else
                    table.insert(requestErrors, { message = "HTTP error " .. tostring(request.response_code) })
                end
                finishRequest()
            end)
        end, (j - 1) * config.requestSpacingSeconds)
    end
    Wait.condition(function()
        -- BUG FIX: use pairs() instead of ipairs() — ipairs stops at nil holes
        local seen = {}
        local dupes = {}

        for i, card in pairs(deck.ContainedObjects) do
            if card then
                if seen[card.Nickname] then
                    table.insert(dupes, i)
                else
                    seen[card.Nickname] = true
                end
            end
        end

        if #dupes > 0 and attempts < config.maxDedupeAttempts then
            local dupeUrls = {}
            for _, i in ipairs(dupes) do
                table.insert(dupeUrls, originalUrls[i])
            end

            Wait.time(function()
                PackBuilder.fetchDeckData(boosterID, setCode, dupeUrls, leaveObject, attempts + 1, deck, dupes, originalUrls)
            end, config.dedupeRetrySpacingSeconds)
        else
            -- BUG FIX: compact sparse arrays before finalizing
            -- Find the max numeric index that was actually written
            local maxIdx = 0
            for k in pairs(deck.ContainedObjects) do
                if type(k) == "number" and k > maxIdx then maxIdx = k end
            end

            -- Collect cards in original slot order, skipping failed slots
            local compactedCards = {}
            for i = 1, maxIdx do
                local card = deck.ContainedObjects[i]
                if card then
                    table.insert(compactedCards, card)
                end
            end

            -- Rebuild deck tables with clean sequential indices
            deck.ContainedObjects = {}
            deck.DeckIDs        = {}
            deck.CustomDeck     = {}

            for newIdx, card in ipairs(compactedCards) do
                local newCardID = newIdx * 100
                -- Pull image entry regardless of what the old CustomDeck key was
                local deckEntry = nil
                for _, entry in pairs(card.CustomDeck or {}) do
                    deckEntry = entry
                    break
                end
                if deckEntry then
                    card.CardID    = newCardID
                    card.CustomDeck = { [newIdx] = deckEntry }
                    deck.ContainedObjects[newIdx] = card
                    deck.DeckIDs[newIdx]          = newCardID
                    deck.CustomDeck[newIdx]        = deckEntry
                end
            end

            local cardCount      = #deck.ContainedObjects
            local boosterContents = {}

            if setCode == config.defaultSetCode then
                table.insert(boosterContents, PackBuilder.generateInstructionNotecard())
            elseif cardCount == 0 then
                table.insert(boosterContents, PackBuilder.generateErrorNotecard({
                    message = "Could not generate any cards for this booster."
                }))
            elseif cardCount == 1 then
                -- BUG FIX: TTS rejects a Deck with only 1 card — spawn the card directly
                table.insert(boosterContents, deck.ContainedObjects[1])
            else
                table.insert(boosterContents, deck)
            end

            for _, errorInfo in ipairs(requestErrors) do
                table.insert(boosterContents, PackBuilder.generateErrorNotecard(errorInfo))
            end

            PackBuilder.cache[boosterID] = boosterContents
        end
    end, function()
        return requestsPending == requestsCompleted
    end)
end


PackBuilder.fetchAllCardsForSet = function(boosterID, setCode, spec, leaveObject)
    local deck = {
        Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 180, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1 },
        Name = "Deck",
        Nickname = setCode .. " Booster",
        DeckIDs = {},
        CustomDeck = {},
        ContainedObjects = {},
    }

    local uniqueMap = {}
    local indexCounter = 0

    local function finalize()
        local count = #deck.ContainedObjects
        if count == 0 then
            PackBuilder.cache[boosterID] = {
                PackBuilder.generateErrorNotecard({ message = "No cards found for this set." })
            }
        elseif count == 1 then
            -- BUG FIX: TTS cannot spawn a 1-card Deck
            PackBuilder.cache[boosterID] = { deck.ContainedObjects[1] }
        else
            PackBuilder.cache[boosterID] = { deck }
        end
    end

    local function fetchPage(urlOrQuery, page)
        local targetUrl = tostring(urlOrQuery or "")
        if not targetUrl:match("^https?://") then
            targetUrl = config.apiSearchBaseURL .. urlEncode(targetUrl)
        end

        WebRequest.custom(targetUrl, "GET", true, nil, makeHeaders(), function(request)
            if request.response_code ~= 200 then
                finalize()
                return
            end

            local parsed = PackBuilder.safeDecode(request.text or "")
            if not parsed or parsed.object == "error" then
                finalize()
                return
            end

            if leaveObject then
                pcall(function()
                    leaveObject.editButton({ index = 1, label = "page: " .. tostring(page) })
                end)
            end

            for _, card in ipairs(parsed.data or {}) do
                local uniqueKey = PackBuilder.extractUniqueCardKey(card)
                if uniqueKey and not uniqueMap[uniqueKey] then
                    uniqueMap[uniqueKey] = true
                    indexCounter = indexCounter + 1
                    local cardData = PackBuilder.createCardDataFromCardObject(card, indexCounter)
                    if cardData then
                        deck.ContainedObjects[indexCounter] = cardData
                        deck.DeckIDs[indexCounter] = cardData.CardID
                        deck.CustomDeck[indexCounter] = cardData.CustomDeck[indexCounter]
                    end
                end
            end

            if parsed.has_more and parsed.next_page then
                Wait.time(function()
                    fetchPage(parsed.next_page, page + 1)
                end, config.pageRequestSpacingSeconds)
            else
                finalize()
            end
        end)
    end

    fetchPage(scryfallSetClause(spec.sets), 1)
end

local function hasDescriptionChanged()
    local description = self.getDescription()
    if description ~= data.lastDescription then
        data.lastDescription = description
        return true
    end
    return false
end

local function setBoxName()
    local spec = resolveSetSpec(data.setCode)
    self.setName(spec.name .. " Booster Box")
end

local function updateObject()
    data.setCode = string.upper(self.getDescription()):match("SET:%s*(%S+)") or config.defaultSetCode
    setBoxName()

    -- No label button — the box image already shows the set name.
    self.clearButtons()
end

local function syncStateFromDescription()
    local newCode = string.upper(self.getDescription()):match("SET:%s*(%S+)") or config.defaultSetCode
    if newCode == data.setCode then
        return
    end

    data.setCode = newCode
    updateObject()

    if data.setCode ~= config.defaultSetCode then
        validateSetCode(data.setCode, function(valid)
            setBoxName()
            if not valid then
                print("Invalid or unsupported set code: " .. tostring(data.setCode))
            end
        end)
    else
        data.validation.code = config.defaultSetCode
        data.validation.state = "unknown"
        data.validation.meta = nil
        data.validation.message = nil
    end
end

local function spawnPreviewBoxesInternal()
    local startPos = self.getPosition() + Vector(config.previewSpacingX, 0, 0)
    local cols = math.max(1, config.previewColumns)

    -- Get base object data once; strip contents so we don't clone all contained packs
    local ok, selfData = pcall(function() return self.getData() end)
    if not ok or not selfData then return end

    local baseTransform = selfData.Transform or {}

    for index, setCode in ipairs(config.previewSetCodes or {}) do
        Wait.time(function()
            local code = safeUpper(setCode)
            local spec = resolveSetSpec(code)

            local row = math.floor((index - 1) / cols)
            local col = (index - 1) % cols

            -- Build per-box custom mesh/image data with set-specific diffuse baked in
            local imageUrl = inferPackImageUrl(code)
            local customMesh = nil
            if type(selfData.CustomMesh) == "table" then
                customMesh = {}
                for k, v in pairs(selfData.CustomMesh) do customMesh[k] = v end
                customMesh.DiffuseURL = imageUrl
            end
            local customImage = nil
            if type(selfData.CustomImage) == "table" then
                customImage = {}
                for k, v in pairs(selfData.CustomImage) do customImage[k] = v end
                customImage.ImageURL = imageUrl
            end

            local boxData = {
                Name        = selfData.Name,
                Nickname    = spec.name .. " Booster Box",
                Description = "SET: " .. code,
                Transform   = {
                    posX   = startPos.x + col * config.previewSpacingX,
                    posY   = startPos.y,
                    posZ   = startPos.z - row * config.previewSpacingZ,
                    rotX   = baseTransform.rotX or 0,
                    rotY   = baseTransform.rotY or 0,
                    rotZ   = baseTransform.rotZ or 0,
                    scaleX = baseTransform.scaleX or 1,
                    scaleY = baseTransform.scaleY or 1,
                    scaleZ = baseTransform.scaleZ or 1,
                },
                LuaScript      = selfData.LuaScript or "",
                LuaScriptState = "",
                CustomMesh     = customMesh,
                CustomImage    = customImage,
                Bag            = selfData.Bag,
                Grid           = selfData.Grid,
                Snap           = selfData.Snap,
                Locked         = false,
                ContainedObjects = selfData.ContainedObjects or {},
            }

            spawnObjectData({ data = boxData })
        end, (index - 1) * 0.05)
    end
end

function spawnPreviewBoxes()
    spawnPreviewBoxesInternal()
end

-- stale safety alias for old objects / old buttons
function spawnSupportedPacks()
    spawnPreviewBoxesInternal()
end

function noop()
end

function onLoad()
    updateObject()
    data.lastDescription = self.getDescription()

    if data.setCode == config.defaultSetCode then
        self.addContextMenuItem("Spawn Boxes", spawnPreviewBoxes)
    end
end

function onUpdate()
    data.timePassed = data.timePassed + Time.delta_time
    if data.timePassed >= config.pollInterval then
        data.timePassed = 0
        if hasDescriptionChanged() then
            syncStateFromDescription()
        end
    end
end

function onObjectLeaveContainer(container, leaveObject)
    if container ~= self then
        return
    end

    local currentCode = data.setCode
    local spec = resolveSetSpec(currentCode)

    if spec and spec.name then
        leaveObject.setName(spec.name .. " Booster (" .. currentCode .. ")")
        leaveObject.setDescription("SET: " .. currentCode .. (spec.date and spec.date ~= "" and ("\nReleased: " .. spec.date) or ""))
    else
        leaveObject.setName(currentCode .. " Booster")
        leaveObject.setDescription("SET: " .. currentCode)
    end

    data.boosterCount = data.boosterCount + 1
    local currentBoosterID = data.boosterCount

    leaveObject.createButton({
        label = "generating " .. currentCode,
        click_function = "noop",
        function_owner = self,
        position = { 0, 0.2, -1.6 },
        rotation = { 0, 0, 0 },
        width = 1000,
        height = 200,
        font_size = 130,
        color = { 0, 0, 0, 95 },
        hover_color = { 0, 0, 0, 95 },
        press_color = { 0, 0, 0, 95 },
        font_color = { 1, 1, 1, 95 },
    })

    leaveObject.createButton({
        label = "resolving image...",
        click_function = "noop",
        function_owner = self,
        position = { 0, 0.2, 1.6 },
        rotation = { 0, 0, 0 },
        width = 1000,
        height = 200,
        font_size = 130,
        color = { 0, 0, 0, 95 },
        hover_color = { 0, 0, 0, 95 },
        press_color = { 0, 0, 0, 95 },
        font_color = { 1, 1, 1, 95 },
    })

    leaveObject.setLuaScript("function tryObjectEnter() return false end")

    local function startGeneration()
        if currentCode == config.defaultSetCode then
            PackBuilder.cache[currentBoosterID] = { PackBuilder.generateInstructionNotecard() }
            return
        end

        if data.validation.code == currentCode and data.validation.state == "invalid" then
            PackBuilder.cache[currentBoosterID] = {
                PackBuilder.generateErrorNotecard({ message = data.validation.message or "Invalid set code." })
            }
            return
        end

        local resolvedSpec = resolveSetSpec(currentCode)
        if resolvedSpec.spawnAll then
            PackBuilder.fetchAllCardsForSet(currentBoosterID, currentCode, resolvedSpec, leaveObject)
        else
            local urls = BoosterUrls.getSetUrls(currentCode)
            leaveObject.editButton({ index = 1, label = "remaining: " .. tostring(#urls) })
            PackBuilder.fetchDeckData(currentBoosterID, currentCode, urls, leaveObject)
        end
    end

    local function startAfterImage()
        if data.validation.code == currentCode and data.validation.state == "valid" then
            startGeneration()
        elseif data.validation.code == currentCode and data.validation.state == "invalid" then
            startGeneration()
        else
            leaveObject.editButton({ index = 1, label = "checking set..." })
            validateSetCode(currentCode, function()
                if leaveObject then
                    startGeneration()
                end
            end)
        end
    end

    -- Resolve the pack image from the set code when possible.
    -- inferPackImageUrl already returns config.defaultPackImage for ??? so this
    -- is safe for every case.  We only fall back to reading the box's own diffuse
    -- if the set code somehow produced the default (e.g. the box is still ???),
    -- and even then we sanitise it so ??? .jpg can never reach TTS.
    local resolvedPackImage
    if currentCode ~= config.defaultSetCode then
        -- Build the CDN URL directly from the set code — works for both manually
        -- typed set codes on the original box AND spawned preview boxes.
        resolvedPackImage = inferPackImageUrl(currentCode)
    else
        -- ??? box: use the box's own diffuse, sanitised.
        local _boxDiffuse = (self.getCustomObject() or {}).diffuse or ""
        resolvedPackImage = (
            _boxDiffuse ~= ""
            and _boxDiffuse:match("^https?://")
            and not _boxDiffuse:find("%?%?%?")
        ) and _boxDiffuse or config.defaultPackImage
    end

    -- Apply the image to leaveObject immediately, before TTS's renderer touches it.
    applyPackImage(leaveObject, resolvedPackImage)

    pcall(function()
        leaveObject.editButton({ index = 1, label = "image ready" })
    end)
    Wait.time(function()
        if leaveObject then
            startAfterImage()
        end
    end, 0.05)

    Wait.condition(
        function()
            Wait.condition(function()
                -- BUG FIX: leaveObject isn't nil after destruct in TTS; use pcall
                local ok, objectData = pcall(function() return leaveObject.getData() end)
                if not ok or not objectData then
                    PackBuilder.cache[currentBoosterID] = nil
                    return
                end

                pcall(function() leaveObject.destruct() end)

                objectData.Locked = false
                objectData.ContainedObjects = PackBuilder.cache[currentBoosterID]
                PackBuilder.cache[currentBoosterID] = nil  -- BUG FIX: free cache entry

                local generatedBooster = spawnObjectData({ data = objectData })
                if generatedBooster then
                    -- Apply image BEFORE setLuaScript so packLua's onLoad sees the
                    -- correct diffuse when it checks custom.diffuse == defaultPack.
                    applyPackImage(generatedBooster, resolvedPackImage)
                    generatedBooster.setLuaScript(packLua)
                end
            end, function()
                -- BUG FIX: leaveObject.resting throws if the object was externally
                -- destroyed; catch it so the condition resolves cleanly
                local ok, resting = pcall(function() return leaveObject.resting end)
                return (not ok) or resting
            end)
        end,
        function()
            return PackBuilder.cache[currentBoosterID] ~= nil
        end
    )
end

function onChat(message, player)
    local msg = tostring(message or "")
    local cmd, arg = msg:match('^!booster%s+(%S+)%s*(.*)$')
    if not cmd then
        return
    end

    cmd = string.lower(cmd)

    if cmd == "set" then
        local setCode = safeUpper(arg)
        if setCode ~= "" then
            self.setDescription("SET: " .. setCode)
            syncStateFromDescription()
            print("Booster set changed to " .. setCode)
        end
    elseif cmd == "preview" then
        spawnPreviewBoxesInternal()
    end
end
