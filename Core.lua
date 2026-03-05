local addonName, ns = ...

------------------------------------------------------------------------
-- Saved Variables & Defaults
------------------------------------------------------------------------
local db
local DEFAULT_DB = {
    point = {"CENTER", nil, "CENTER", 0, 200},
    scale = 1.2,
    locked = false,
    alertSounds = true,
    stateLog = {},
    probeResults = nil,
    -- Auto-calibration from past hunts
    activitiesPerPhase = {},   -- event counts (for reference)
    pointsPerPhase = {},       -- weighted stack points (used for % calc)
}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local PREY_WIDGET_ID = 7663
local HUNT_AURA_SPELL_ID = 459731
local ANGUISH_CURRENCY_ID = 3392
local DEFAULT_ACTIVITIES_PER_PHASE = 5   -- event count default (display only)
local DEFAULT_POINTS_PER_PHASE = 10      -- weighted points default (for % calc)

-- Phase info
local PHASES = {
    [0] = {name = "FROID",    color = {0.4, 0.65, 1.0}},
    [1] = {name = "TIEDE",    color = {1.0, 0.85, 0.2}},
    [2] = {name = "CHAUD",    color = {1.0, 0.4, 0.1}},
    [3] = {name = "IMMINENT", color = {1.0, 0.1, 0.1}},
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local currentState = -1
local currentAuraStacks = 0
local preyQuestName = nil
local huntActive = false
local alertFired = {}
local testTicker = nil
local stateStartTime = 0
local phaseActivities = 0    -- event count in current phase (for display)
local phasePoints = 0        -- weighted points in current phase (for % calc)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function GetPhase(state)
    return PHASES[state] or PHASES[0]
end

local function GetPointsForPhase(phase)
    if db and db.pointsPerPhase and db.pointsPerPhase[tostring(phase)] then
        return db.pointsPerPhase[tostring(phase)]
    end
    return DEFAULT_POINTS_PER_PHASE
end

local function GetActivitiesForPhase(phase)
    if db and db.activitiesPerPhase and db.activitiesPerPhase[tostring(phase)] then
        return db.activitiesPerPhase[tostring(phase)]
    end
    return DEFAULT_ACTIVITIES_PER_PHASE
end

-- Phase ranges (non-linear, based on observed data)
-- Phases can be SKIPPED (e.g., Cold -> Hot directly)
-- IMMINENT = prey has spawned = 100%
local PHASE_BASE = {
    [0] = 0,    -- FROID: 0% start
    [1] = 40,   -- TIEDE: 40% start (may be skipped)
    [2] = 55,   -- CHAUD: 55% start
    [3] = 100,  -- IMMINENT: prey is here!
}
local PHASE_NEXT = {
    [0] = 40,   -- FROID fills up to 40%
    [1] = 55,   -- TIEDE fills up to 55%
    [2] = 95,   -- CHAUD fills up to 95%
    [3] = 100,  -- IMMINENT is always 100%
}

local function CalcPct(state, subProgress)
    if state >= 3 then return 100 end
    local base = PHASE_BASE[state] or 0
    local ceiling = PHASE_NEXT[state] or 100
    local range = ceiling - base
    local sub = math.min(subProgress, 0.95) * range
    return base + sub
end

local function PctColor(pct)
    if pct < 40 then
        return 0.4, 0.65, 1.0
    elseif pct < 55 then
        return 1.0, 0.85, 0.2
    elseif pct < 95 then
        return 1.0, 0.4, 0.1
    else
        return 1.0, 0.1, 0.1
    end
end

local function FormatTime(sec)
    if sec <= 0 or sec > 7200 then return "--" end
    local m = math.floor(sec / 60)
    local s = math.floor(sec % 60)
    if m > 0 then return string.format("%dm %02ds", m, s) end
    return string.format("%ds", s)
end

local function Msg(text)
    print("|cffff4444[MHT]|r " .. text)
end

------------------------------------------------------------------------
-- Main Frame
------------------------------------------------------------------------
local frame = CreateFrame("Frame", "MHTFrame", UIParent, "BackdropTemplate")
frame:SetSize(250, 88)
frame:SetPoint("CENTER", 0, 200)
frame:SetFrameStrata("HIGH")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)
frame:Hide()

frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = {left = 4, right = 4, bottom = 4, top = 4},
})
frame:SetBackdropColor(0.05, 0.02, 0.08, 0.90)
frame:SetBackdropBorderColor(0.7, 0.1, 0.1, 0.9)

frame:SetScript("OnDragStart", function(self)
    if not db or not db.locked then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if db then
        local p, _, rp, x, y = self:GetPoint()
        db.point = {p, nil, rp, x, y}
    end
end)

------------------------------------------------------------------------
-- Frame Elements
------------------------------------------------------------------------
-- Title
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetPoint("TOP", 0, -6)
title:SetText("|cffcc2222TRAQUE|r")

-- Big percentage text
local pctText = frame:CreateFontString(nil, "OVERLAY")
pctText:SetFont("Fonts\\FRIZQT__.TTF", 30, "OUTLINE")
pctText:SetPoint("TOP", 0, -17)
pctText:SetText("--")

-- Phase name under percentage
local phaseLabel = frame:CreateFontString(nil, "OVERLAY")
phaseLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
phaseLabel:SetPoint("TOP", pctText, "BOTTOM", 0, -1)
phaseLabel:SetText("")

-- Info line (quest name, timer, activities)
local infoText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
infoText:SetPoint("BOTTOM", 0, 22)
infoText:SetTextColor(0.65, 0.65, 0.65)

-- Continuous progress bar
local bar = CreateFrame("StatusBar", nil, frame)
bar:SetSize(230, 12)
bar:SetPoint("BOTTOM", 0, 7)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
bar:SetMinMaxValues(0, 100)
bar:SetValue(0)

local barBG = bar:CreateTexture(nil, "BACKGROUND")
barBG:SetAllPoints()
barBG:SetColorTexture(0.08, 0.05, 0.1, 0.9)

-- Phase markers on bar (at phase boundaries: 40%, 55%, 95%)
local markerPcts = {40, 55, 95}
for _, mpct in ipairs(markerPcts) do
    local marker = bar:CreateTexture(nil, "OVERLAY")
    marker:SetSize(1, 12)
    marker:SetPoint("LEFT", bar, "LEFT", (mpct / 100) * 230, 0)
    marker:SetColorTexture(1, 1, 1, 0.25)
end

local barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
barText:SetPoint("CENTER", bar, "CENTER", 0, 0)
barText:SetTextColor(1, 1, 1, 0.7)

------------------------------------------------------------------------
-- Glow animation
------------------------------------------------------------------------
local glow = frame:CreateTexture(nil, "ARTWORK")
glow:SetAllPoints()
glow:SetColorTexture(1, 0, 0, 0)
glow:SetBlendMode("ADD")

local glowAG = glow:CreateAnimationGroup()
glowAG:SetLooping("BOUNCE")
local glowAnim = glowAG:CreateAnimation("Alpha")
glowAnim:SetFromAlpha(0)
glowAnim:SetToAlpha(0.18)
glowAnim:SetDuration(0.4)

------------------------------------------------------------------------
-- Logging
------------------------------------------------------------------------
local function LogEvent(eventType, data)
    if not db then return end
    if not db.stateLog then db.stateLog = {} end
    table.insert(db.stateLog, {
        time = time(),
        gameTime = GetTime(),
        event = eventType,
        state = currentState,
        stacks = currentAuraStacks,
        activities = phaseActivities,
        points = phasePoints,
        data = data or "",
    })
    while #db.stateLog > 300 do
        table.remove(db.stateLog, 1)
    end
end

------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------
local function ResetState()
    currentState = -1
    currentAuraStacks = 0
    phaseActivities = 0
    phasePoints = 0
    preyQuestName = nil
    huntActive = false
    stateStartTime = 0
    wipe(alertFired)
    if glowAG:IsPlaying() then glowAG:Stop() end
    glow:SetAlpha(0)
    pctText:SetText("--")
    pctText:SetTextColor(0.5, 0.5, 0.5)
    phaseLabel:SetText("")
    infoText:SetText("")
    barText:SetText("")
    bar:SetValue(0)
    bar:SetStatusBarColor(0.3, 0.3, 0.3)
    title:SetText("|cffcc2222TRAQUE|r")
end

local function UpdateDisplay(state, points, eventCount)
    local phase = GetPhase(state)
    local estPerPhase = GetPointsForPhase(state)
    local subProgress = estPerPhase > 0 and (points / estPerPhase) or 0
    local pct = CalcPct(state, subProgress)
    local r, g, b = PctColor(pct)

    -- IMMINENT = prey is here, special display
    if state >= 3 then
        pctText:SetTextColor(1, 0.1, 0.1)
        pctText:SetText("100%")
        phaseLabel:SetTextColor(1, 0.1, 0.1)
        phaseLabel:SetText("PROIE DISPONIBLE !")
        bar:SetValue(100)
        bar:SetStatusBarColor(1, 0.1, 0.1)
        barText:SetText("Ouvrez la carte !")
    else
        -- Normal % display
        pctText:SetTextColor(r, g, b)
        pctText:SetText(string.format("~%.0f%%", pct))

        local pr, pg, pb = unpack(phase.color)
        phaseLabel:SetTextColor(pr, pg, pb)
        phaseLabel:SetText(string.format("%s  (%d pts / %d acts)", phase.name, points, eventCount))

        bar:SetValue(pct)
        bar:SetStatusBarColor(r, g, b)
        barText:SetText(string.format("~%.0f%%", pct))
    end

    -- Info line
    local parts = {}
    if stateStartTime > 0 then
        parts[#parts + 1] = FormatTime(GetTime() - stateStartTime)
    end
    if preyQuestName then
        local short = preyQuestName:gsub("Traque : ", ""):gsub(" %(difficile%)", " (H)"):gsub(" %(normal%)", "")
        parts[#parts + 1] = short
    end
    infoText:SetText(table.concat(parts, "  |cff555555·|r  "))

    -- Title
    if state >= 3 then
        title:SetText("|cffff0000!! PROIE IMMINENTE !!|r")
    elseif state >= 2 then
        title:SetText("|cffff4400!! TRAQUE !!|r")
    else
        title:SetText("|cffcc2222TRAQUE|r")
    end

    -- Glow
    if pct >= 60 then
        if not glowAG:IsPlaying() then glowAG:Play() end
    else
        if glowAG:IsPlaying() then glowAG:Stop() end
        glow:SetAlpha(0)
    end

    -- Sound alerts on phase transitions
    if db and db.alertSounds then
        if state >= 3 and not alertFired[3] then
            alertFired[3] = true
            PlaySound(8959, "Master")
            if RaidNotice_AddMessage and RaidWarningFrame then
                RaidNotice_AddMessage(RaidWarningFrame,
                    "|cffFF0000LA PROIE EST IMMINENTE !|r",
                    ChatTypeInfo["RAID_WARNING"])
            end
            Msg("|cffff0000PHASE 4 — LA PROIE VA APPARAITRE !|r")
        elseif state >= 2 and not alertFired[2] then
            alertFired[2] = true
            PlaySound(12889, "Master")
            Msg("Phase 3 — La traque est |cffff4400CHAUDE|r !")
        elseif state >= 1 and not alertFired[1] then
            alertFired[1] = true
            PlaySound(3081, "Master")
            Msg("Phase 2 — La traque se |cffffff00rechauffe|r...")
        end
    end

    if not frame:IsShown() then frame:Show() end
    huntActive = true
end

------------------------------------------------------------------------
-- Data Sources
------------------------------------------------------------------------
local function GetWidgetData(widgetID)
    widgetID = widgetID or PREY_WIDGET_ID
    if not C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo then return nil end
    local ok, info = pcall(C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo, widgetID)
    if ok and info and type(info) == "table" and info.shownState == 1 then
        return {
            progressState = info.progressState,
            animID = info.scriptedAnimationEffectID,
            textureKit = info.textureKit,
            tooltip = info.tooltip,
            raw = info,
        }
    end
    return nil
end

local function GetActivePreyQuest()
    if C_QuestLog.GetActivePreyQuest then
        local ok, questID = pcall(C_QuestLog.GetActivePreyQuest)
        if ok and questID and questID > 0 then return questID end
    end
    return nil
end

local function GetHuntAuraStacks()
    -- Use GetPlayerAuraBySpellID to avoid taint issues with spellId comparison
    if C_UnitAuras.GetPlayerAuraBySpellID then
        local data = C_UnitAuras.GetPlayerAuraBySpellID(HUNT_AURA_SPELL_ID)
        if data then
            return data.applications or 0, data.name
        end
    end
    return 0, nil
end

local function GetAnguishCurrency()
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
        local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, ANGUISH_CURRENCY_ID)
        if ok and info then return info.quantity or 0, info.name or "?" end
    end
    return 0, "?"
end

local function DiscoverPreyWidget()
    local data = GetWidgetData(PREY_WIDGET_ID)
    if data then return PREY_WIDGET_ID, data end

    local vizType = Enum and Enum.UIWidgetVisualizationType and Enum.UIWidgetVisualizationType.PreyHuntProgress
    if not vizType then return nil end

    local setGetters = {"GetTopCenterWidgetSetID", "GetBelowMinimapWidgetSetID",
                        "GetObjectiveTrackerWidgetSetID", "GetPowerBarWidgetSetID"}
    for _, getter in ipairs(setGetters) do
        if C_UIWidgetManager[getter] then
            local ok, setID = pcall(C_UIWidgetManager[getter])
            if ok and setID and setID > 0 then
                local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(setID)
                if widgets then
                    for _, w in ipairs(widgets) do
                        if w.widgetType == vizType then
                            local wData = GetWidgetData(w.widgetID)
                            if wData then
                                PREY_WIDGET_ID = w.widgetID
                                return w.widgetID, wData
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

------------------------------------------------------------------------
-- Main Update
------------------------------------------------------------------------
local function DoUpdate()
    local widgetID, wData = DiscoverPreyWidget()
    local questID = GetActivePreyQuest()
    local auraStacks = GetHuntAuraStacks()

    -- Update quest name
    if questID then
        preyQuestName = C_QuestLog.GetTitleForQuestID(questID)
    end

    -- Detect activity (aura stack changed = player did something)
    -- Weight: positive delta reflects how much the activity contributed
    -- Negative delta (stack reset/cycle) = minimum 1 point
    if auraStacks ~= currentAuraStacks and currentState >= 0 then
        if currentAuraStacks > 0 or auraStacks > 0 then
            local delta = auraStacks - currentAuraStacks
            local weight = math.max(delta, 1)
            phaseActivities = phaseActivities + 1
            phasePoints = phasePoints + weight
            LogEvent("activity", string.format("stacks:%d->%d wt:+%d acts:%d pts:%d",
                currentAuraStacks, auraStacks, weight, phaseActivities, phasePoints))
        end
        currentAuraStacks = auraStacks
    elseif currentAuraStacks == 0 and auraStacks > 0 then
        currentAuraStacks = auraStacks
    end

    -- Primary: widget progressState
    if wData then
        local state = wData.progressState or 0

        -- Detect phase change
        if state ~= currentState then
            local oldState = currentState

            -- Save calibration: weighted points and event count this phase took
            if oldState >= 0 and phasePoints > 0 then
                if not db.pointsPerPhase then db.pointsPerPhase = {} end
                if not db.activitiesPerPhase then db.activitiesPerPhase = {} end
                local key = tostring(oldState)
                -- Weighted points calibration (primary, used for % calc)
                local prevPts = db.pointsPerPhase[key]
                if prevPts then
                    db.pointsPerPhase[key] = math.floor((prevPts + phasePoints) / 2 + 0.5)
                else
                    db.pointsPerPhase[key] = phasePoints
                end
                -- Event count calibration (for display/reference)
                local prevActs = db.activitiesPerPhase[key]
                if prevActs then
                    db.activitiesPerPhase[key] = math.floor((prevActs + phaseActivities) / 2 + 0.5)
                else
                    db.activitiesPerPhase[key] = phaseActivities
                end
                Msg(string.format("|cff00ff00Calibration:|r %s = %d pts / %d acts (estime: %d pts)",
                    GetPhase(oldState).name, phasePoints, phaseActivities, db.pointsPerPhase[key]))
            end

            currentState = state
            stateStartTime = GetTime()
            phaseActivities = 0  -- reset event counter for new phase
            phasePoints = 0      -- reset weighted points for new phase
            wipe(alertFired)

            if oldState >= 0 then
                LogEvent("phase", string.format("%d->%d", oldState, state))
                Msg(string.format("|cffffff00%s|r -> |cffffff00%s|r  (phase %d/4)",
                    GetPhase(oldState).name, GetPhase(state).name, state + 1))
            else
                LogEvent("init", string.format("state:%d stacks:%d quest:%s", state, auraStacks, tostring(questID)))
            end
        end

        UpdateDisplay(state, phasePoints, phaseActivities)
        return true
    end

    -- Fallback: quest active but no widget
    if questID and not wData then
        if not huntActive then
            huntActive = true
            phaseLabel:SetText("")
            pctText:SetText("...")
            pctText:SetTextColor(0.5, 0.5, 0.5)
            title:SetText("|cffcc2222TRAQUE|r")
            infoText:SetText(preyQuestName and preyQuestName:gsub("Traque : ", "") or "")
            frame:Show()
        end
        return false
    end

    -- No hunt detected
    if huntActive and not wData and not questID and auraStacks == 0 then
        Msg("Traque terminee ou quittee.")
        ResetState()
        frame:Hide()
    end

    return false
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("UPDATE_UI_WIDGET")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("UNIT_AURA")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:RegisterEvent("QUEST_ACCEPTED")
events:RegisterEvent("QUEST_REMOVED")

local refreshTicker = nil

events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            if not MidnightHuntTrackerDB then
                MidnightHuntTrackerDB = {}
                for k, v in pairs(DEFAULT_DB) do MidnightHuntTrackerDB[k] = v end
            end
            db = MidnightHuntTrackerDB
            for k, v in pairs(DEFAULT_DB) do
                if db[k] == nil then db[k] = v end
            end
            if type(db.stateLog) ~= "table" then db.stateLog = {} end
            if type(db.activitiesPerPhase) ~= "table" then db.activitiesPerPhase = {} end
            if type(db.pointsPerPhase) ~= "table" then db.pointsPerPhase = {} end

            frame:ClearAllPoints()
            frame:SetPoint(db.point[1], UIParent, db.point[3], db.point[4], db.point[5])
            frame:SetScale(db.scale)
            Msg("Midnight Hunt Tracker v5.1 charge. |cff888888/mht|r")
        end

    elseif event == "UPDATE_UI_WIDGET" then
        local widgetInfo = ...
        if not widgetInfo or not widgetInfo.widgetID then return end
        local vizType = Enum and Enum.UIWidgetVisualizationType and Enum.UIWidgetVisualizationType.PreyHuntProgress
        if (vizType and widgetInfo.widgetType == vizType) or widgetInfo.widgetID == PREY_WIDGET_ID then
            PREY_WIDGET_ID = widgetInfo.widgetID
            DoUpdate()
        end

    elseif event == "UNIT_AURA" then
        if ... == "player" then
            local stacks = GetHuntAuraStacks()
            -- Only update if stacks changed (= activity happened)
            if stacks ~= currentAuraStacks then
                DoUpdate()
            end
        end

    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" then
        DoUpdate()

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        C_Timer.After(2, function()
            DoUpdate()
            if not refreshTicker then
                refreshTicker = C_Timer.NewTicker(10, function()
                    if huntActive then
                        -- Refresh timer display
                        if currentState >= 0 then
                            UpdateDisplay(currentState, phasePoints, phaseActivities)
                        end
                    else
                        local q = GetActivePreyQuest()
                        if q then DoUpdate() end
                    end
                end)
            end
        end)
    end
end)

------------------------------------------------------------------------
-- Probe
------------------------------------------------------------------------
local function RunProbe()
    Msg("=== PROBE ===")
    local results = {}

    local mapID = C_Map.GetBestMapForUnit("player")
    local mapInfo = mapID and C_Map.GetMapInfo(mapID)
    results.zone = {mapID = mapID, name = mapInfo and mapInfo.name or "?"}
    Msg(string.format("Zone: %s (mapID: %s)", results.zone.name, tostring(mapID)))

    local widgetID, wData = DiscoverPreyWidget()
    if wData then
        results.widget = {widgetID = widgetID, progressState = wData.progressState,
            animID = wData.animID, textureKit = wData.textureKit, tooltip = wData.tooltip}
        if wData.raw then
            results.widgetRaw = {}
            for k, v in pairs(wData.raw) do
                if type(v) ~= "table" then results.widgetRaw[k] = tostring(v) end
            end
        end
        Msg(string.format("Widget: ID:%d  |cffffff00%s|r (state:%d)  anim:%d",
            widgetID, GetPhase(wData.progressState).name, wData.progressState, wData.animID or 0))
    else
        Msg("Widget: |cff888888non trouve|r")
    end

    local pqID = GetActivePreyQuest()
    if pqID then
        results.preyQuest = {questID = pqID, title = C_QuestLog.GetTitleForQuestID(pqID)}
        Msg(string.format("Quete: %s (ID:%d)", results.preyQuest.title or "?", pqID))
    else
        Msg("Quete: |cff888888aucune|r")
    end

    local stacks, auraName = GetHuntAuraStacks()
    results.aura = {stacks = stacks, name = auraName}
    Msg(string.format("Aura: %s  stacks:%d", auraName or "inactive", stacks))

    local qty, cName = GetAnguishCurrency()
    results.currency = {quantity = qty, name = cName}
    Msg(string.format("Monnaie: %s %d", cName, qty))

    local estPts = GetPointsForPhase(currentState)
    Msg(string.format("Phase: %d (%s)  pts: %d/%d  acts: %d  pct: ~%.0f%%",
        currentState, currentState >= 0 and GetPhase(currentState).name or "?",
        phasePoints, estPts, phaseActivities,
        currentState >= 0 and CalcPct(currentState, phasePoints / estPts) or 0))

    Msg("--- Calibration ---")
    if db.pointsPerPhase and next(db.pointsPerPhase) then
        for k, v in pairs(db.pointsPerPhase) do
            local phaseName = PHASES[tonumber(k)] and PHASES[tonumber(k)].name or k
            local acts = db.activitiesPerPhase and db.activitiesPerPhase[k] or "?"
            Msg(string.format("  %s: ~%d pts (~%s acts)", phaseName, v, tostring(acts)))
        end
    elseif db.activitiesPerPhase and next(db.activitiesPerPhase) then
        for k, v in pairs(db.activitiesPerPhase) do
            local phaseName = PHASES[tonumber(k)] and PHASES[tonumber(k)].name or k
            Msg(string.format("  %s: ~%d acts (ancien format, sera recalibre)", phaseName, v))
        end
    end
    Msg(string.format("  (defaut si pas de donnees: %d pts/phase)", DEFAULT_POINTS_PER_PHASE))

    results.enum = {}
    if Enum and Enum.PreyHuntProgressState then
        for k, v in pairs(Enum.PreyHuntProgressState) do results.enum[tostring(k)] = v end
    end

    results.widgetSets = {}
    for _, pair in ipairs({
        {"TopCenter", "GetTopCenterWidgetSetID"}, {"BelowMinimap", "GetBelowMinimapWidgetSetID"},
        {"ObjectiveTracker", "GetObjectiveTrackerWidgetSetID"}, {"PowerBar", "GetPowerBarWidgetSetID"},
    }) do
        if C_UIWidgetManager[pair[2]] then
            local ok, setID = pcall(C_UIWidgetManager[pair[2]])
            if ok and setID and setID > 0 then
                local w = C_UIWidgetManager.GetAllWidgetsBySetID(setID)
                results.widgetSets[pair[1]] = {setID = setID, widgetCount = w and #w or 0}
            end
        end
    end

    db.probeResults = results
    Msg("=== FIN === (sauve apres /reload)")
end

------------------------------------------------------------------------
-- Slash Commands
------------------------------------------------------------------------
SLASH_MHT1 = "/mht"
SLASH_MHT2 = "/traque"

SlashCmdList["MHT"] = function(msg)
    msg = (msg or ""):lower():trim()

    if msg == "" or msg == "help" then
        Msg("Midnight Hunt Tracker v5.1 :")
        Msg("  |cff00ccff/mht probe|r - Scan complet")
        Msg("  |cff00ccff/mht diag|r - Diagnostic rapide")
        Msg("  |cff00ccff/mht log|r - Historique")
        Msg("  |cff00ccff/mht cal|r - Voir la calibration (points/phase)")
        Msg("  |cff00ccff/mht lock|r - Verrouiller/deverrouiller")
        Msg("  |cff00ccff/mht scale 0.5-3|r - Taille")
        Msg("  |cff00ccff/mht sound|r - Sons on/off")
        Msg("  |cff00ccff/mht test|r - Simulation")
        Msg("  |cff00ccff/mht reset|r - Reinitialiser")
        Msg("  |cff00ccff/mht show|r / |cff00ccff/mht hide|r")

    elseif msg == "probe" then
        RunProbe()

    elseif msg == "diag" then
        Msg("=== DIAG ===")
        local wID, wData = DiscoverPreyWidget()
        if wData then
            Msg(string.format("Widget: ID:%d  |cffffff00%s|r (state:%d)  anim:%d",
                wID, GetPhase(wData.progressState).name, wData.progressState, wData.animID or 0))
        else
            Msg("Widget: |cff888888non trouve|r")
        end
        local pq = GetActivePreyQuest()
        if pq then
            Msg(string.format("Quete: %s (ID:%d)", C_QuestLog.GetTitleForQuestID(pq) or "?", pq))
        end
        local stacks = GetHuntAuraStacks()
        Msg(string.format("Aura stacks: %d", stacks))
        local estPts = GetPointsForPhase(currentState)
        local pct = currentState >= 0 and CalcPct(currentState, phasePoints / estPts) or 0
        Msg(string.format("Phase: %d (%s)  pts: %d/%d  acts: %d  ~%.0f%%",
            currentState, currentState >= 0 and GetPhase(currentState).name or "?",
            phasePoints, estPts, phaseActivities, pct))

    elseif msg == "cal" or msg == "calibration" then
        Msg("=== CALIBRATION ===")
        if db.pointsPerPhase and next(db.pointsPerPhase) then
            for k, v in pairs(db.pointsPerPhase) do
                local phaseName = PHASES[tonumber(k)] and PHASES[tonumber(k)].name or "phase " .. k
                local acts = db.activitiesPerPhase and db.activitiesPerPhase[k] or "?"
                Msg(string.format("  %s: |cffffff00%d|r pts (~%s acts) pour completer", phaseName, v, tostring(acts)))
            end
        elseif db.activitiesPerPhase and next(db.activitiesPerPhase) then
            for k, v in pairs(db.activitiesPerPhase) do
                local phaseName = PHASES[tonumber(k)] and PHASES[tonumber(k)].name or "phase " .. k
                Msg(string.format("  %s: |cffffff00%d|r acts (ancien, sera recalibre)", phaseName, v))
            end
        else
            Msg("  |cff888888Pas encore de donnees. Joue une traque complete !|r")
        end
        Msg(string.format("  Defaut si pas de donnees: %d pts/phase", DEFAULT_POINTS_PER_PHASE))
        Msg("  Les pts prennent en compte le poids des activites.")
        Msg("  La calibration s'ameliore a chaque traque.")

    elseif msg == "log" then
        Msg("=== LOG ===")
        if db.stateLog and #db.stateLog > 0 then
            local start = math.max(1, #db.stateLog - 25)
            for i = start, #db.stateLog do
                local e = db.stateLog[i]
                local phaseName = e.state >= 0 and GetPhase(e.state).name or "?"
                Msg(string.format("  [%s] %s  %s  stacks:%d  acts:%d  pts:%d  %s",
                    date("%H:%M:%S", e.time),
                    e.event or "?", phaseName,
                    e.stacks or 0, e.activities or 0, e.points or 0,
                    e.data or ""))
            end
            Msg(string.format("(%d entrees)", #db.stateLog))
        else
            Msg("  |cff888888Vide.|r")
        end

    elseif msg == "lock" then
        db.locked = not db.locked
        Msg("Cadre " .. (db.locked and "verrouille." or "deverrouille."))

    elseif msg == "sound" then
        db.alertSounds = not db.alertSounds
        Msg("Sons " .. (db.alertSounds and "actives." or "desactives."))

    elseif msg:match("^scale%s+([%d%.]+)") then
        local s = tonumber(msg:match("^scale%s+([%d%.]+)"))
        if s and s >= 0.5 and s <= 3 then
            db.scale = s; frame:SetScale(s)
            Msg("Echelle : " .. s)
        end

    elseif msg == "test" then
        ResetState()
        if testTicker then testTicker:Cancel() end
        local state = 0
        local acts = 0
        local pts = 0
        stateStartTime = GetTime()
        currentState = state
        Msg("Simulation...")
        frame:Show()
        UpdateDisplay(state, pts, acts)
        testTicker = C_Timer.NewTicker(0.8, function()
            acts = acts + 1
            local w = math.random(1, 5)  -- simulate variable weight
            pts = pts + w
            if acts > 4 then
                -- Phase transition
                state = state + 1
                if state > 3 then
                    C_Timer.After(3, function()
                        ResetState()
                        frame:Hide()
                        Msg("Simulation terminee.")
                    end)
                    if testTicker then testTicker:Cancel(); testTicker = nil end
                    return
                end
                currentState = state
                stateStartTime = GetTime()
                wipe(alertFired)
                acts = 0
                pts = 0
            end
            phaseActivities = acts
            phasePoints = pts
            UpdateDisplay(state, pts, acts)
        end)

    elseif msg == "reset" then
        ResetState()
        db.point = {"CENTER", nil, "CENTER", 0, 200}
        db.stateLog = {}
        db.activitiesPerPhase = {}
        db.pointsPerPhase = {}
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
        frame:Hide()
        Msg("Reinitialise (calibration effacee).")

    elseif msg == "clearlog" then
        db.stateLog = {}
        Msg("Logs effaces (calibration conservee).")

    elseif msg == "show" then
        frame:Show()
        DoUpdate()

    elseif msg == "hide" then
        frame:Hide()

    else
        Msg("Commande inconnue. |cff00ccff/mht|r")
    end
end
