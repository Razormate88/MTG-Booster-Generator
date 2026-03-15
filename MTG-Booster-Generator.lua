local AutoUpdater = {
    name = "MTG Booster Generator",
    version = "0.8.2",
    versionUrl = "https://raw.githubusercontent.com/Razormate88/MTG-Booster-Generator/refs/heads/main/MTG-Booster-Generator.ver",
    scriptUrl = "https://raw.githubusercontent.com/Razormate88/MTG-Booster-Generator/refs/heads/main/MTG-Booster-Generator.lua",
    debug = false,

    run = function(self, host)
        self.host = host
        if not self.host then
            self:error("Error: host not set, ensure AutoUpdater:run(self) is in your onLoad() function")
            return
        end
        self:checkForUpdate()
    end,
    checkForUpdate = function(self)
        WebRequest.get(self.versionUrl, function(request)
            if request.response_code ~= 200 then
                self:error("Failed to check version (" .. request.response_code .. ": " .. request.error .. ")")
                return
            end
            local remoteVersion = request.text:match("[^\r\n]+") or ""
            if self:isNewerVersion(remoteVersion) then
                self:fetchNewScript(remoteVersion)
            end
        end)
    end,
    isNewerVersion = function(self, remoteVersion)
        local function split(v)
            return { v:match("^(%d+)%.?(%d*)%.?(%d*)") or 0 }
        end
        local r, l = split(remoteVersion), split(self.version)
        for i = 1, math.max(#r, #l) do
            local rv, lv = tonumber(r[i]) or 0, tonumber(l[i]) or 0
            if rv ~= lv then
                return rv > lv
            end
        end
        return false
    end,
    fetchNewScript = function(self, newVersion)
        WebRequest.get(self.scriptUrl, function(request)
            if request.response_code ~= 200 then
                self:error("Failed to fetch new script (" .. request.response_code .. ": " .. request.error .. ")")
                return
            end
            if request.text and #request.text > 0 then
                self.host.setLuaScript(request.text)
                self:print("Updated to version " .. newVersion)
                Wait.condition(function()
                    return not self.host or self.host.reload()
                end, function()
                    return not self.host or self.host.resting
                end)
            else
                self:error("New script is empty")
            end
        end)
    end,
    print = function(self, message)
        print(self.name .. ": " .. message)
    end,
    error = function(self, message)
        if self.debug then
            error(self.name .. ": " .. message)
        end
    end,
}

local config = {
    backURL = 'https://steamusercontent-a.akamaihd.net/ugc/1647720103762682461/35EF6E87970E2A5D6581E7D96A99F8A575B7A15F/',
    apiBaseURL = 'https://api.scryfall.com/cards/random?q=',
    defaultPackImage = "https://steamusercontent-a.akamaihd.net/ugc/12555777445170015064/1F22F21DA19B1C5D668D761C2CA447889AE98A2A/", -- same url used in packLua
    defaultSetCode = "???", -- same setCode used in packLua
    pollInterval = 0.25,
    maxDedupeAttempts = 8,
    requestRetryAttempts = 2,
    enableAutoUpdate = false,
}

local data = {
    setCode = "???",
    boosterCount = 0,
    timePassed = 0,
    lastDescription = "",
    requestQueue = {},
}

local packLua = [[
-- Any MTG Booster Generator by CoRNeRNoTe
-- Most recent script can be found on GitHub:
-- https://github.com/cornernote/tabletop_simulator-mtg_booster_generator/blob/main/lua/booster-generator.lua
local defaultSetCode = "???"
local defaultPack = "https://steamusercontent-a.akamaihd.net/ugc/12555777445170015064/1F22F21DA19B1C5D668D761C2CA447889AE98A2A/"
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
    if self.getCustomObject().diffuse == defaultPack then
        self.createButton({
            label = setCode and (setCode .. " Booster") or self.getName(),
            click_function = 'noop',
            function_owner = self,
            position = { 0, 0.2, -1.6 },
            rotation = { 0, 0, 0 },
            width = 1000,
            height = 200,
            font_size = 150,
            color = { 0, 0, 0, 95 },
            hover_color = { 0, 0, 0, 95 },
            press_color = { 0, 0, 0, 95 },
            font_color = { 1, 1, 1, 95 },
        })
    end
    if setCode ~= defaultSetCode and #self.getObjects() > 0 then
        self.createButton({
            label = "Unpack",
            click_function = "unpackDeck",
            function_owner = self,
            position = { 0, 0.2, 0 },
            rotation = { 0, 0, 0 },
            width = 600,
            height = 200,
            font_size = 150,
            color = { 0, 0, 0, 95 },
            font_color = { 1, 1, 1, 95 },
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
    local spacingX = 2.3
    local spacingZ = 3.2
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
                    card.setScale({ 1, 1, 1 })
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

-----------------------------------------------------------------------
-- BoosterUrls - builds URL lists for set types
-----------------------------------------------------------------------

BoosterUrls = { }

BoosterUrls.randomRarity = function(mythicChance, rareChance, uncommonChance)
    if math.random(1, mythicChance or 36) == 1 then
        return 'r:m'
    elseif math.random(1, rareChance or 8) == 1 then
        return 'r:r'
    elseif math.random(1, uncommonChance or 4) == 1 then
        return 'r:u'
    else
        return 'r:c'
    end
end

BoosterUrls.chooseMasterpieceReplacement = function(sets, urls)
    if type(sets) == "string" then
        sets = { sets }
    end

    local masterpieceSets = {
        bfz = 'exp',
        ogw = 'exp',
        kld = 'mps',
        aer = 'mps',
        akh = 'mp2',
        hou = 'mp2',
        stx = 'sta',
        tsp = 'tsb',
        mb1 = 'fmb1',
        mh2 = 'h1r',
    }

    for _, set in ipairs(sets) do
        local masterpieceSet = masterpieceSets[set]
        if masterpieceSet and math.random(1, 144) == 1 then
            urls[#urls] = BoosterUrls.makeUrl(BoosterUrls.makeSetQuery(masterpieceSet))
        end
    end
end

BoosterUrls.makeSetQuery = function(sets)
    if type(sets) == "string" then
        sets = { sets }
    end

    if #sets > 1 then
        local query = "("
        for i, set in ipairs(sets) do
            query = query .. "set:" .. set
            if i < #sets then
                query = query .. "+or+"
            end
        end
        return query .. ")"
    else
        return "set:" .. sets[1]
    end
end

BoosterUrls.makeUrl = function(setQuery, filter)
    return config.apiBaseURL .. setQuery .. "+" .. filter
end

BoosterUrls.basePackUrls = function(sets, includeBasics, extraCommons)
    local urls = {}
    local setQuery = BoosterUrls.makeSetQuery(sets)

    if includeBasics then
        table.insert(urls, BoosterUrls.makeUrl(setQuery, "t:basic+unique:prints"))
    else
        table.insert(urls, BoosterUrls.makeUrl(setQuery, "r:common+-t:basic"))
    end

    for c in ("wubrg"):gmatch(".") do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, "r:common+-t:basic+c>=" .. c))
    end

    extraCommons = extraCommons or 5
    for i = 1, extraCommons do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, "r:common+-t:basic"))
    end

    return urls
end


BoosterUrls.cloneTable = function(source)
    local copy = {}
    for i, value in ipairs(source) do
        copy[i] = value
    end
    return copy
end

BoosterUrls.makeFilterString = function(filters)
    if not filters or filters == "" then
        return ""
    end
    if type(filters) == "table" then
        return table.concat(filters, "+")
    end
    return tostring(filters)
end

BoosterUrls.appendFilters = function(url, filters)
    local filterString = BoosterUrls.makeFilterString(filters)
    if filterString == "" then
        return url
    end
    return url .. "+" .. filterString
end

BoosterUrls.replaceSlot = function(urls, slotIndex, newUrl)
    if urls[slotIndex] then
        urls[slotIndex] = newUrl
    end
    return urls
end

BoosterUrls.excludeFilters = function(urls, filters, skipIndex)
    for i, value in ipairs(urls) do
        if i ~= skipIndex then
            urls[i] = BoosterUrls.appendFilters(value, filters)
        end
    end
    return urls
end

BoosterUrls.buildPack = function(spec)
    local sets = spec.sets or spec.set or {}
    local includeBasics = (spec.includeBasics ~= false)
    local extraCommons = spec.extraCommons or 0
    local uncommons = spec.uncommons or 0
    local raritySlots = spec.raritySlots or {}
    local urls = BoosterUrls.basePackUrls(sets, includeBasics, extraCommons)
    local setQuery = BoosterUrls.makeSetQuery(sets)

    for i = 1, uncommons do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, "r:u"))
    end
    for _, rarityFilter in ipairs(raritySlots) do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, rarityFilter))
    end

    if spec.addCardType then
        urls = BoosterUrls.addCardTypeToPack(urls, spec.addCardType)
    end
    if spec.swapLandForCommon then
        urls = BoosterUrls.swapLandForCommon(urls)
    end
    if spec.masterpieces ~= false then
        BoosterUrls.chooseMasterpieceReplacement(sets, urls)
    end
    return urls
end

BoosterUrls.alphaCardPack = function(sets)
    local setQuery = BoosterUrls.makeSetQuery(sets)
    local urls = BoosterUrls.basePackUrls(sets, true, 10)

    for i = 1, 3 do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r:u'))
    end

    table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r:r'))

    BoosterUrls.chooseMasterpieceReplacement(sets, urls)
    return urls
end

BoosterUrls.default14CardPack = function(sets)
    local setQuery = BoosterUrls.makeSetQuery(sets)
    local urls = BoosterUrls.basePackUrls(sets, true, 1)

    for i = 1, 3 do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r:u'))
    end

    table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(8000, 300, 36)))
    table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(800, 30, 3)))
    table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(80, 3, 1)))
    table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(8, 1)))

    BoosterUrls.chooseMasterpieceReplacement(sets, urls)
    return urls
end

BoosterUrls.default15CardPack = function(sets)
    local setQuery = BoosterUrls.makeSetQuery(sets)
    local urls = BoosterUrls.basePackUrls(sets, true, 5)

    for i = 1, 3 do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r:u'))
    end

    table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(8, 1)))

    BoosterUrls.chooseMasterpieceReplacement(sets, urls)
    return urls
end

BoosterUrls.default16CardPack = function(sets)
    local setQuery = BoosterUrls.makeSetQuery(sets)
    local urls = BoosterUrls.basePackUrls(sets, true, 3)

    for i = 1, 3 do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r:u'))
    end

    table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(800, 30, 3)))
    table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(80, 3, 1)))

    for i = 1, 2 do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(8, 1)))
    end

    BoosterUrls.chooseMasterpieceReplacement(sets, urls)
    return urls
end

BoosterUrls.default20CardPack = function(sets)
    local setQuery = BoosterUrls.makeSetQuery(sets)
    local urls = BoosterUrls.basePackUrls(sets, false, 5)

    for i = 1, 5 do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r:u'))
    end

    table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(800, 30, 3)))
    table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(80, 3, 1)))

    for i = 1, 2 do
        table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(8, 1)))
    end

    BoosterUrls.chooseMasterpieceReplacement(sets, urls)
    return urls
end

BoosterUrls.addCardTypeToPack = function(pack, cardType)
    local randomIndex = math.random(#pack - 1, #pack)
    for i = 13, #pack do
        if randomIndex == i then
            pack[i] = pack[i] .. '+' .. cardType
        else
            pack[i] = pack[i] .. '+-(' .. cardType .. ')'
        end
    end
    return pack
end

BoosterUrls.createReplacementSlotPack = function(urls, sets, removeQuery, addQuery, slotIndex)
    local setQuery = BoosterUrls.makeSetQuery(sets)
    slotIndex = slotIndex or 7
    for i, v in ipairs(urls) do
        if i ~= slotIndex then
            urls[i] = BoosterUrls.appendFilters(v, removeQuery)
        else
            urls[i] = BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity() .. addQuery)
        end
    end
    return urls
end

BoosterUrls.swapLandForCommon = function(urls)
    urls[1] = urls[7]
    return urls
end

BoosterUrls.reverseTable = function(t)
    local rev = {}
    for i = #t, 1, -1 do
        table.insert(rev, t[i])
    end
    return rev
end

BoosterUrls.getSetUrls = function(setCode)
    local entry = setDefinitions[setCode]
    if entry and entry.getUrls then
        return BoosterUrls.reverseTable(entry.getUrls(setCode))
    end
    return BoosterUrls.reverseTable(BoosterUrls.default15CardPack(setCode))
end

-----------------------------------------------------------------------
-- PackBuilder - fetches card info and builds a booster pack
-----------------------------------------------------------------------

PackBuilder = {}

PackBuilder.cache = {}


PackBuilder.safeDecode = function(jsonString)
    if not jsonString or jsonString == "" then
        return nil
    end
    local ok, result = pcall(JSON.decode, jsonString)
    if ok then
        return result
    end
    return nil
end

PackBuilder.getRequestErrorMessage = function(request)
    local errorInfo = PackBuilder.safeDecode(request.text)
    if errorInfo and errorInfo.details then
        return errorInfo.details
    end
    if request.error and request.error ~= "" then
        return request.error
    end
    return request.text or "Unknown request error"
end

PackBuilder.getCardDedupKey = function(cardData)
    if not cardData then
        return nil
    end
    local memo = tostring(cardData.Memo or "")
    local nickname = tostring(cardData.Nickname or "")
    return memo .. "|" .. nickname
end

PackBuilder.enqueueRequest = function(url, callback, position)
    local entry = { url = url, callback = callback }
    if position == "start" then
        table.insert(data.requestQueue, 1, entry)
    else
        table.insert(data.requestQueue, entry)
    end
end

PackBuilder.processRequestQueue = function()
    if #data.requestQueue == 0 then
        return
    end
    local request = table.remove(data.requestQueue, 1)
    local headers = {
        ['User-Agent'] = AutoUpdater.name .. '/' .. AutoUpdater.version,
        ['Accept'] = 'application/json'
    }
    WebRequest.custom(request.url, "GET", true, nil, headers, request.callback)
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

    for j, url in ipairs(urls) do
        local i = replaceIndices and replaceIndices[j] or j
        PackBuilder.enqueueRequest(url, function(request)
            if request.response_code == 200 then
                local cardData = PackBuilder.createCardDataFromJSON(request.text, i)
                if cardData then
                    deck.ContainedObjects[i] = cardData
                    deck.DeckIDs[i] = cardData.CardID
                    deck.CustomDeck[i] = cardData.CustomDeck[i]
                end
            else
                local message = PackBuilder.getRequestErrorMessage(request)
                table.insert(requestErrors, { url = url, message = message })
            end
            requestsCompleted = requestsCompleted + 1
            local remaining = requestsPending - requestsCompleted
            local label = "remaining: " .. (remaining + 1)
            if attempts > 0 then
                label = "deduping: " .. (attempts + 1) .. ": " .. (remaining + 1)
            end
            if leaveObject then
                leaveObject.editButton({ index = 1, label = label })
            end
        end, existingDeck and "start" or "end")
    end

    Wait.condition(function()
        if leaveObject == null then
            return
        end
        local seen, dupes = {}, {}
        for i, card in ipairs(deck.ContainedObjects) do
            if card then
                local dedupKey = PackBuilder.getCardDedupKey(card)
                if dedupKey and seen[dedupKey] then
                    table.insert(dupes, i)
                else
                    seen[dedupKey] = true
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
            end, 0.1)
        else
            local boosterContents = {}
            if setCode == config.defaultSetCode then
                table.insert(boosterContents, PackBuilder.generateInstructionNotecard())
            else
                table.insert(boosterContents, deck)
            end

            for _, error in ipairs(requestErrors) do
                table.insert(boosterContents, PackBuilder.generateErrorNotecard(error))
            end

            PackBuilder.cache[boosterID] = boosterContents
        end
    end, function()
        return requestsPending == requestsCompleted
    end)
end

PackBuilder.generateErrorNotecard = function(error)
    return {
        Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1 },
        Name = "Notecard",
        Nickname = "Booster Generation Error",
        Description = "url: " .. error.url .. "\n\n" .. error.message,
        Grid = false, Snap = false
    }
end

PackBuilder.generateInstructionNotecard = function()
    local setsWithPackImages = {}
    for code, setData in pairs(setDefinitions) do
        if setData.packImage then
            table.insert(setsWithPackImages, code)
        end
    end
    return {
        Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1, },
        Name = "Notecard",
        Nickname = 'REPLACE "SET: ???" IN BOX DESCRIPTION',
        Description = "\nAlmost all sets are supported, see:"
                .. "\nhttps://scryfall.com/sets"
                .. "\n"
                .. "\nCustom pack images are available for:"
                .. "\n" .. table.concat(setsWithPackImages, ", "),
        Grid = false, Snap = false
    }
end

PackBuilder.createCardDataFromJSON = function(jsonString, cardIndex)
    local card = PackBuilder.safeDecode(jsonString)
    if not card or not card.name then
        error("Failed to decode JSON: " .. tostring(jsonString))
        return
    end

    local cardName, cardOracle, faceURL, backData
    local imageQuality = 'large'
    local cacheBuster = (card.image_status ~= 'highres_scan') and ('?' .. os.date("%Y%m%d")) or ""

    if card.card_faces then
        if card.image_uris then
            cardName = PackBuilder.formattedName(card.card_faces[1])
            cardOracle = ""
            for i, face in ipairs(card.card_faces) do
                cardOracle = cardOracle .. PackBuilder.formattedName(face) .. '\n' .. PackBuilder.getCardOracleText(face)
                if i < #card.card_faces then
                    cardOracle = cardOracle .. '\n'
                end
            end
            faceURL = card.image_uris.normal:gsub('%?.*', ''):gsub('normal', imageQuality) .. cacheBuster
        else
            local face, back = card.card_faces[1], card.card_faces[2]
            cardName = PackBuilder.formattedName(face, 'DFC')
            cardOracle = PackBuilder.getCardOracleText(face)
            faceURL = face.image_uris.normal:gsub('%?.*', ''):gsub('normal', imageQuality) .. cacheBuster
            local backURL = back.image_uris.normal:gsub('%?.*', ''):gsub('normal', imageQuality) .. cacheBuster
            local backCardIndex = cardIndex + 100
            backData = {
                Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1 },
                Name = "Card",
                Nickname = PackBuilder.formattedName(back, 'DFC'),
                Description = PackBuilder.getCardOracleText(back),
                Memo = card.oracle_id,
                CardID = backCardIndex * 100,
                CustomDeck = {
                    [backCardIndex] = {
                        FaceURL = backURL, BackURL = config.backURL, NumWidth = 1, NumHeight = 1,
                        Type = 0, BackIsHidden = true, UniqueBack = false
                    }
                }
            }
        end
    else
        cardName = PackBuilder.formattedName(card)
        cardOracle = PackBuilder.getCardOracleText(card)
        faceURL = card.image_uris.normal:gsub('%?.*', ''):gsub('normal', imageQuality) .. cacheBuster
    end

    local cardData = {
        Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1 },
        Name = "Card",
        Nickname = cardName,
        Description = cardOracle,
        Memo = card.oracle_id,
        CardID = cardIndex * 100,
        CustomDeck = {
            [cardIndex] = {
                FaceURL = faceURL, BackURL = config.backURL, NumWidth = 1, NumHeight = 1,
                Type = 0, BackIsHidden = true, UniqueBack = false
            }
        }
    }

    if backData then
        cardData.States = { [2] = backData }
    end
    return cardData
end

PackBuilder.formattedName = function(face, typeSuffix)
    return string.format(
            '%s\n%s %s CMC %s',
            face.name:gsub('"', ''),
            face.type_line,
            tostring(face.cmc or 0),
            typeSuffix or ""
    )            :gsub('%s$', '')
end

PackBuilder.getCardOracleText = function(cardFace)
    local powerToughness = ""
    if cardFace.power then
        powerToughness = '\n[b]' .. tostring(cardFace.power) .. '/' .. tostring(cardFace.toughness) .. '[/b]'
    elseif cardFace.loyalty then
        powerToughness = '\n[b]' .. tostring(cardFace.loyalty) .. '[/b]'
    end
    return (cardFace.oracle_text or "") .. powerToughness
end

PackBuilder.getRandomPackImage = function(setCode)
    local packImage = setDefinitions[setCode] and setDefinitions[setCode].packImage or config.defaultPackImage
    if type(packImage) == "table" then
        packImage = packImage[math.random(1, #packImage)]
    end
    return packImage
end

-----------------------------------------------------------------------
-- SetDefinitions - defines the booster set name, contents, etc
-----------------------------------------------------------------------


local function defaultSetEntry(def)
    local entry = {}
    for k, v in pairs(def or {}) do
        entry[k] = v
    end
    return entry
end

local function makePackDef(name, date, packImage, getUrls)
    return {
        name = name,
        date = date,
        packImage = packImage,
        getUrls = getUrls,
    }
end

setDefinitions = {
    TLA = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/18426860329109062848/8608CEB001CF861FC4A6AEB7DEFC99036DDCBC03/",
        name = "Avatar: The Last Airbender",
        date = "2025-11-21",
        getUrls = BoosterUrls.default14CardPack,
    },
    TLAC = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/16172442222396970495/9B571ECCFD4A01EE6287BD6BE1F00D38112F1303/",
        name = "Avatar: The Last Airbender Collector",
        date = "2025-11-21",
        getUrls = function(set)
            return BoosterUrls.default15CardPack({ "TLA", "TLE" })
        end,
    },
    SPM = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/11967831829609287872/6D168435BEFB1C1EE50A4F0B286BF4D8D9FEA7C8/",
        name = "Marvel's Spider-Man",
        date = "2025-09-26",
        getUrls = function(set)
            return BoosterUrls.default14CardPack({ "SPM", "MAR" })
        end,
    },
    SPMC = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/14447519524209323137/A7BC08D5AFE8EB8953D3E6F767C7259CDDAAEB34/",
        name = "Marvel's Spider-Man Collector",
        date = "2025-09-26",
        getUrls = function(set)
            return BoosterUrls.default15CardPack({ "SPM", "MAR", "SPE" })
        end,
    },
    FIN = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/16627771293824374075/C5699273F56C725E5F909A4CF68E0BBB40CB3212/",
        name = "Final Fantasy",
        date = "2025-06-13",
        getUrls = function(set)
            return BoosterUrls.default14CardPack({ "FIN", "FCA" })
        end,
    },
    FINC = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/12474440936943111473/5DD973A1A676B0AF1D27C63CB43CE0B91FD45134/",
        name = "Final Fantasy Collector",
        date = "2025-06-13",
        getUrls = function(set)
            return BoosterUrls.default15CardPack({ "FIN", "FCA", "FIC" })
        end,
    },
    TMT = makePackDef(
        "Teenage Mutant Ninja Turtles",
        "2026-03-06",
        "https://steamusercontent-a.akamaihd.net/ugc/10486510128165068236/F8124735459318D0D57BA6BB56A1E4EEE57F72B2/",
        function(set)
            return BoosterUrls.buildPack({
                sets = { "TMT", "PZA" },
                includeBasics = true,
                extraCommons = 1,
                uncommons = 3,
                raritySlots = {
                    BoosterUrls.randomRarity(8000, 300, 36),
                    BoosterUrls.randomRarity(800, 30, 3),
                    BoosterUrls.randomRarity(80, 3, 1),
                    BoosterUrls.randomRarity(8, 1),
                },
            })
        end
    ),
    TMTC = makePackDef(
        "Teenage Mutant Ninja Turtles Collector",
        "2026-03-06",
        "https://steamusercontent-a.akamaihd.net/ugc/14419565199248419732/6F98D7FFCD80045538360B4CA12D5AB9E406BF66/",
        function(set)
            return BoosterUrls.buildPack({
                sets = { "TMT", "PZA" },
                includeBasics = true,
                extraCommons = 5,
                uncommons = 3,
                raritySlots = {
                    BoosterUrls.randomRarity(800, 30, 3),
                    BoosterUrls.randomRarity(80, 3, 1),
                    BoosterUrls.randomRarity(8, 1),
                },
            })
        end
    ),
    TMTX = makePackDef(
        "Teenage Mutant Ninja Turtles Extended",
        "2026-03-06",
        "https://steamusercontent-a.akamaihd.net/ugc/10486510128165068236/F8124735459318D0D57BA6BB56A1E4EEE57F72B2/",
        function(set)
            return BoosterUrls.buildPack({
                sets = { "TMT", "PZA", "TMC" },
                includeBasics = true,
                extraCommons = 5,
                uncommons = 3,
                raritySlots = {
                    BoosterUrls.randomRarity(800, 30, 3),
                    BoosterUrls.randomRarity(80, 3, 1),
                    BoosterUrls.randomRarity(8, 1),
                },
            })
        end
    ),
    BOK = {
        packImage = "https://i.imgur.com/t6UP7lt.jpg",
        name = "Betrayers of Kamigawa",
        date = "2025-02-04",
        getUrls = function(set)
            local urls = BoosterUrls.swapLandForCommon(BoosterUrls.default15CardPack(set))
            urls[15] = urls[15]:gsub("r:m", "r:r")
            return urls
        end,
    },
    CHK = {
        packImage = "https://i.imgur.com/E7IW8Tv.jpg",
        name = "Champions of Kamigawa",
        date = "2024-10-01",
    },
    INR = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33314777894966905/8D9807FCC410A72E23B650DD45417ADE665B4E87/",
        name = "Innistrad Remaster",
        date = "2025-01-24",
        getUrls = BoosterUrls.default14CardPack,
    },
    DFT = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33315411545885589/0C728D0BDFAB373310773FA4546CC4E08B1B11A1/",
        name = "Aetherdrift",
        date = "2025-02-14",
        getUrls = BoosterUrls.default14CardPack,
    },
    EOE = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/15223391781034002798/18D4F50FA52D5739A7AAF47270CD89A8F3161F20/",
        name = "Edge of Eternities",
        date = "2025-08-01",
        getUrls = BoosterUrls.default14CardPack,
    },
    TDM = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33320655968555543/9ADDB19799EBAE44174466FE19E0C52F73EDDAE4/",
        name = "Tarkir: Dragonstorm",
        date = "2025-04-11",
        getUrls = BoosterUrls.default14CardPack,
    },
    FDN = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33313055666062860/0DFCD530284A8A4EC67CCEA18399BDE9405F3C3C/",
        name = "Foundations",
        date = "2024-11-15",
        getUrls = BoosterUrls.default14CardPack,
    },
    DSK = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33313055666215369/BFD6BBAC0DE7F1F5C810F4FFCA8EF5E50EC8A03E/",
        name = "Duskmourn: House of Horror",
        date = "2024-09-27",
        getUrls = BoosterUrls.default14CardPack,
    },
    BLB = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33313055666242938/FA118E357C5820C6BF4EC70CAECC88876B22DE41/",
        name = "Bloomburrow",
        date = "2024-08-12",
        getUrls = BoosterUrls.default14CardPack,
    },
    MH3 = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33313055666331598/112B58990D8AD19B704448588F6CC34A8BF0E2E9/",
        name = "Modern Horizons III",
        date = "2024-06-14",
        getUrls = BoosterUrls.default14CardPack,
    },
    MKM = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33313055666403145/D578E8D070D0F89BB866212A8C5FD97AE840F418/",
        name = "Murders at Karlov Manor",
        date = "2024-02-09",
        getUrls = BoosterUrls.default14CardPack,
    },
    OTJ = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33313055666361741/B40E45A8AE490D38D02C8D32295E71920362D781/",
        name = "Outlaws of Thunder Junction",
        date = "2024-04-19",
        getUrls = BoosterUrls.default14CardPack,
    },
    RVR = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/33313055666416970/8B9F38A1D618C5C025C45E8D484B097CA8F245EE/",
        name = "Ravnica Remastered",
        date = "2024-01-12",
        getUrls = function(set)
            return BoosterUrls.swapLandForCommon(BoosterUrls.default14CardPack(set))
        end,
    },
    XLN = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/861734852198387392/B81155A30E28760116D166987C221F946D37380E/",
        name = "Ixalan",
        date = "2023-11-17",
    },
    MID = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/1734441450308868762/12F6CE09A39E5FEC3B472EBE54562B92A7332027/",
        name = "Innistrad: Midnight Hunt",
        date = "2021-09-24",
        getUrls = function(set)
            local urls = BoosterUrls.default15CardPack(set)
            local transformIndex = math.random(#urls - 1, #urls)
            for i, v in pairs(urls) do
                local add = (i == 7 or (i == transformIndex))
                urls[i] = v .. (add and '+is:transform' or '+-is:transform')
            end
            return urls
        end,
    },
    STX = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/1734441184603578733/2009A7D782D40F1456733EFE30ACC064D12B5FFD/",
        name = "StrixHaven",
        date = "2021-04-23",
        getUrls = function(set)
            local urls = {}
            local setQuery = BoosterUrls.makeSetQuery('stx')
            local archiveSetQuery = BoosterUrls.makeSetQuery('sta')
            local mixedSetQuery = BoosterUrls.makeSetQuery({ 'stx', 'sta' })
            table.insert(urls, BoosterUrls.makeUrl(setQuery, 't:land'))
            for c in ('wubrg'):gmatch('.') do
                table.insert(urls, BoosterUrls.makeUrl(setQuery, '-t:basic+r<r+c:' .. c))
            end
            table.insert(urls, BoosterUrls.makeUrl(setQuery, '-t:basic+r<r'))
            table.insert(urls, BoosterUrls.makeUrl(mixedSetQuery, '-t:basic'))
            table.insert(urls, BoosterUrls.makeUrl(setQuery, '-t:basic'))
            table.insert(urls, BoosterUrls.makeUrl(setQuery, BoosterUrls.randomRarity(8, 1)))
            table.insert(urls, BoosterUrls.makeUrl(setQuery, 't:lesson'))
            table.insert(urls, BoosterUrls.makeUrl(archiveSetQuery, 'r>c+' .. (math.random(2) == 1 and 'lang:en' or 'lang:ja')))
            return urls
        end,
    },
    AFR = {
        name = "Adventures in the Forgotten Realms",
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/1734441262522564318/D44434D1C56BA4A590591606A3A50EE4C9F607B8/",
        date = "2021-07-23",
    },
    CMB1 = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/1871804141033719694/FE0CC0C11B5ADB27831BAAF0FF37E95852B6F454/",
        name = "Mystery Booster Playtest Cards 2019",
        date = "2019-11-07",
        getUrls = function(set)
            local urls = {}
            local setQuery = BoosterUrls.makeSetQuery('mb1')
            local url = BoosterUrls.makeUrl(setQuery, 's:mb1') -- seems to load s:plst (The List)
            for c in ('wubrg'):gmatch('.') do
                table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r<r+c=' .. c))
                table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r<r+c=' .. c))
            end
            table.insert(urls, BoosterUrls.makeUrl(setQuery, 'c:m+r<r'))
            table.insert(urls, BoosterUrls.makeUrl(setQuery, 'c:c+r<r'))
            table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r>=r+frame:2015'))
            table.insert(urls, BoosterUrls.makeUrl(setQuery, 'r>=r+-frame:2015'))
            table.insert(urls, BoosterUrls.makeUrl(BoosterUrls.makeSetQuery('cmb1'), ''))
            return urls
        end,
    },
    UST = {
        packImage = {
            "https://steamusercontent-a.akamaihd.net/ugc/1869553886384090159/B009BD275EAA4E4D327CABF6E9C287FCF974CAE0/",
            "https://steamusercontent-a.akamaihd.net/ugc/1869553886384088312/840D789FDE909D82F2943ADC26138DD838C6D3CD/",
            "https://steamusercontent-a.akamaihd.net/ugc/1869553610271665770/97276A7B7774EF057E915B9A0AB9AC3F81221ED2/",
        },
        name = "Unstable",
        date = "2017-12-08",
    },
    UGL = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/1869553610271718076/9F874EFF82054749352677189F63683DC038A17E/",
        name = "Unglued",
        date = "1998-08-11",
    },
    UNH = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/1869553610271611558/564F7D6B23A479883C84C4F5D90852CD4C056E9A/",
        name = "Unhinged",
        date = "2024-11-19",
    },
    VOW = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/2027238089146067515/FB7A98B9B0BE5C25098F63981C6C12BBE1036BA6/",
        name = "Inistrad: Crimson Vow",
        date = "2021-11-19",
    },
    UMA = {
        packImage = "https://i.imgur.com/4RylXgU.png",
        name = "Ultimate Masters",
        date = "2018-12-07",
    },
    CMM = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/2093668098031059945/BF91A05DA4A788ED5F5C01B05305F3E4ECE8CE52/",
        name = "Commander Masters",
        date = "2023-08-04",
        getUrls = BoosterUrls.default20CardPack,
    },
    MMA = {
        packImage = "https://i.imgur.com/CU7EL6h.png",
        name = "Modern Masters",
        date = "2013-06-07",
        getUrls = function(set)
            return BoosterUrls.swapLandForCommon(BoosterUrls.default15CardPack(set))
        end,
    },
    SOK = {
        packImage = "https://i.imgur.com/ctFTHkw.jpg",
        name = "Saviors of Kamigawa",
        date = "2005-06-03",
        getUrls = function(set)
            return BoosterUrls.swapLandForCommon(BoosterUrls.default15CardPack(set))
        end,
    },
    NEO = {
        packImage = "https://i.imgur.com/5FcGpqC.png",
        name = "Kamigawa: Neon Dynasty",
        date = "2022-02-18",
    },
    DOM = {
        name = "Dominaria",
        date = "2018-04-27",
        getUrls = function(set)
            return BoosterUrls.addCardTypeToPack(BoosterUrls.default15CardPack(set), 't:legendary')
        end,
    },
    WAR = {
        name = "War of the Spark",
        date = "2019-05-03",
        getUrls = function(set)
            return BoosterUrls.addCardTypeToPack(BoosterUrls.default15CardPack(set), 't:planeswalker')
        end,
    },
    ZNR = {
        name = "Zendikar Rising",
        date = "2020-09-25",
        getUrls = function(set)
            return BoosterUrls.addCardTypeToPack(BoosterUrls.default15CardPack(set), 't:land+(is:spell+or+pathway)')
        end,
    },
    CNS = {
        name = "Conspiracy",
        date = "2014-06-06",
        getUrls = function(set)
            return BoosterUrls.createReplacementSlotPack(BoosterUrls.default15CardPack(set), set, '+-wm:conspiracy', '+wm:conspiracy', 7)
        end,
    },
    CN2 = {
        name = "Conspiracy: Take the Crown",
        date = "2016-08-26",
        getUrls = function(set)
            return BoosterUrls.createReplacementSlotPack(BoosterUrls.default15CardPack(set), set, '+-wm:conspiracy', '+wm:conspiracy', 7)
        end,
    },
    ISD = {
        getUrls = function(set)
            return BoosterUrls.createReplacementSlotPack(BoosterUrls.default15CardPack(set), set, '+-is:transform', '+is:transform', 7)
        end,
    },
    DKA = {
        getUrls = function(set)
            return BoosterUrls.createReplacementSlotPack(BoosterUrls.default15CardPack(set), set, '+-is:transform', '+is:transform', 7)
        end,
    },
    SOI = {
        getUrls = function(set)
            return BoosterUrls.createReplacementSlotPack(BoosterUrls.default15CardPack(set), set, '+-is:transform', '+is:transform', 7)
        end,
    },
    EMN = {
        getUrls = function(set)
            return BoosterUrls.createReplacementSlotPack(BoosterUrls.default15CardPack(set), set, '+-is:transform', '+is:transform', 7)
        end,
    },
    ICE = {
        getUrls = function(set)
            return BoosterUrls.createReplacementSlotPack(BoosterUrls.default15CardPack(set), set, '', '+t:basic+t:snow+unique:prints')
        end,
    },
    ALL = {
        getUrls = function(set)
            return BoosterUrls.createReplacementSlotPack(BoosterUrls.default15CardPack(set), set, '', '+t:basic+t:snow+unique:prints')
        end,
    },
    CSP = {
        getUrls = function(set)
            local urls = BoosterUrls.default15CardPack(set)
            urls[15] = urls[15]:gsub('r:m', 'r:r')
            return BoosterUrls.createReplacementSlotPack(urls, set, '', 't:basic+t:snow+unique:prints')
        end,
    },
    MH1 = {
        getUrls = function(set)
            return BoosterUrls.createReplacementSlotPack(BoosterUrls.default15CardPack(set), set, '', '+t:basic+t:snow+unique:prints')
        end,
    },
    KHM = {
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/1734441450301159293/A7F7C010D0312D856CD8667678F5732BDB8F6EB2/",
        name = "Kaldheim",
        date = "2021-02-05",
    },
    LEA = {
        name = "Limited Edition Alpha",
        date = "1993-08-05",
        packImage = "https://steamusercontent-a.akamaihd.net/ugc/11233057164064068203/C3F6F1252903B67720C40A2DBBAE54B3F8F6FD7A/",
        getUrls = function(set)
            return BoosterUrls.alphaCardPack(set)
        end,
    },
}

-- any with names that cannot be lua keys can go below

setDefinitions['???'] = {
    getUrls = function(set)
        return {}
    end,
}

setDefinitions['2XM'] = {
    packImage = "https://steamusercontent-a.akamaihd.net/ugc/2027238089151521799/52EC298FBB89EA2A24DA024981161F96E3522645/",
    name = "Double Masters",
    date = "2020-08-07",
    getUrls = BoosterUrls.default16CardPack,
}

-----------------------------------------------------------------------
-- Main script
-----------------------------------------------------------------------


for code, setData in pairs(setDefinitions) do
    setData.code = code
    if not setData.name or setData.name == "" then
        setData.name = code
    end
end

local function getSortedSetDefinitions()
    local items = {}
    for code, setData in pairs(setDefinitions) do
        table.insert(items, {
            code = code,
            name = setData.name or code,
            date = setData.date or "",
            packImage = setData.packImage,
            getUrls = setData.getUrls,
        })
    end

    table.sort(items, function(a, b)
        if a.date == b.date then
            return a.code < b.code
        end
        return a.date > b.date
    end)

    return items
end

function onLoad()
    updateObject()
    data.lastDescription = self.getDescription()
    if data.setCode == config.defaultSetCode then
        self.addContextMenuItem("Spawn Boxes", spawnSupportedPacks)
    end

    if config.enableAutoUpdate then
        AutoUpdater:run(self)
    end
end

function onUpdate()
    data.timePassed = data.timePassed + Time.delta_time
    if data.timePassed >= config.pollInterval then
        data.timePassed = 0
        onUpdateTick()
    end
end

function onUpdateTick()
    if hasDescriptionChanged() then
        updateObject()
    end
    PackBuilder.processRequestQueue()
end

function onObjectLeaveContainer(container, leaveObject)
    if container ~= self then
        return
    end

    local setData = setDefinitions[data.setCode]
    if setData and setData.name then
        leaveObject.setName(setData.name .. " Booster (" .. data.setCode .. ")")
        leaveObject.setDescription("SET: " .. data.setCode .. (setData.date and "\nReleased: " .. setData.date or ""))
    else
        leaveObject.setName(data.setCode .. " Booster")
    end

    data.boosterCount = data.boosterCount + 1
    local currentBoosterID = data.boosterCount

    local urls = BoosterUrls.getSetUrls(data.setCode)
    PackBuilder.fetchDeckData(currentBoosterID, data.setCode, urls, leaveObject)

    leaveObject.createButton {
        label = "generating " .. data.setCode,
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
    }

    leaveObject.createButton {
        label = "remaining: " .. #urls,
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
    }

    leaveObject.setLuaScript("function tryObjectEnter() return false end")
    leaveObject.setCustomObject({ diffuse = PackBuilder.getRandomPackImage(data.setCode) })

    Wait.condition(
            function()
                Wait.condition(function()
                    if leaveObject == null then
                        return
                    end
                    local objectData = leaveObject.getData()
                    leaveObject.destruct()
                    objectData.ContainedObjects = PackBuilder.cache[currentBoosterID]
                    local generatedBooster = spawnObjectData({ data = objectData })
                    generatedBooster.setLuaScript(packLua)
                end, function()
                    return leaveObject == null or leaveObject.resting
                end)
            end,
            function()
                return PackBuilder.cache[currentBoosterID] ~= nil
            end
    )
end

function hasDescriptionChanged()
    local description = self.getDescription()
    if description ~= data.lastDescription then
        data.lastDescription = description
        return true
    end
end

function updateObject()
    data.setCode = string.upper(self.getDescription()):match("SET:%s*(%S+)") or config.defaultSetCode

    local packImage = PackBuilder.getRandomPackImage(data.setCode)
    if self.getCustomObject().diffuse ~= packImage then
        self.setCustomObject({ diffuse = packImage })
        Wait.time(function()
            self.reload()
        end, 0.1)
    end

    self.clearButtons()
    if packImage == config.defaultPackImage then
        self.createButton({
            label = data.setCode .. " Boosters",
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
            font_color = { 1, 1, 1, 95 }
        })
    end
end

function spawnSupportedPacks()
    local orderedSetCodes = {}
    for setCode, setData in pairs(setDefinitions) do
        if setData.packImage then
            table.insert(orderedSetCodes, {
                code = setCode,
                name = setData.name,
                date = setData.date,
            })
        end
    end
    table.sort(orderedSetCodes, function(a, b)
        if not a.date then
            return false
        end
        if not b.date then
            return true
        end
        return a.date < b.date
    end)
    local startPos = self.getPosition() + Vector(3, 0, 0)
    local cols, spacingX, spacingZ = 10, 3, 5
    for index, setData in ipairs(orderedSetCodes) do
        Wait.time(function()
            local row = math.floor((index - 1) / cols)
            local col = (index - 1) % cols
            local copy = self.clone({
                position = {
                    x = startPos.x + col * spacingX,
                    y = startPos.y,
                    z = startPos.z - row * spacingZ,
                },
                snap_to_grid = false,
            })
            if setData and setData.name then
                copy.setName(setData.name .. " Booster (" .. setData.code .. ")")
                copy.setDescription("SET: " .. setData.code .. (setData.date and "\nReleased: " .. setData.date or ""))
            else
                copy.setName(setData.code .. " Booster")
            end
        end, (index - 1) * 0.1)
    end
end

function noop()
end

-- Global.getVar('Encoder') -- comment needed to prevent mtg pi table falsely detecting this as a game-crashing or virus-infected object
