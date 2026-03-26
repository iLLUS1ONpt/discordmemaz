-- ============================================================
-- Flash Race Challenge - CSP Online Lua Script
-- Flash high beams at a car to challenge them!
-- Turn on hazards to accept a challenge.
-- ============================================================

-- ── State machine ────────────────────────────────────────────
local State = {
    IDLE        = 0,
    CHALLENGING = 1,  -- we sent a challenge, waiting for accept
    CHALLENGED  = 2,  -- we received a challenge, waiting for hazards
    COUNTDOWN   = 3,
    RACING      = 4,
    FINISHED    = 5,
}
local currentState = State.IDLE

-- ── Race variables ───────────────────────────────────────────
local rivalIndex      = -1
local rivalName       = ""
local ownHealth       = 1.0
local rivalHealth     = 1.0
local raceStartTimeMs = 0
local raceEndTimeMs   = 0
local finishMessage   = ""

-- ── Config ───────────────────────────────────────────────────
local CFG = {
    flashWindow       = 2500,  -- ms window to count beam toggles
    flashThreshold    = 2,     -- toggles needed to send challenge
    targetRange       = 60,    -- max meters to find a target car
    targetFov         = 0.5,   -- min dot product (roughly 60° cone)
    countdownMs       = 3000,  -- countdown before race starts
    challengeTimeout  = 15000, -- ms before unanswered challenge expires
    behindThreshold   = 3,     -- meters behind before losing health
    healthLossRate    = 0.07,  -- base health/sec when behind
    healthSyncMs      = 400,   -- how often to broadcast our health
    finishShowMs      = 5000,  -- how long to show result before auto-reset
}

-- ── Input state ──────────────────────────────────────────────
local prevHighBeam     = false
local flashCount       = 0
local flashWindowStart = 0
local prevHazards      = false
local lastHealthSync   = 0
local challengeStartTime = 0

-- ── Helpers ──────────────────────────────────────────────────
local function now()
    return ac.getSim().currentSessionTimeMs
end

local function findTargetCar()
    local me     = ac.getCar(0)
    local myPos  = me.position
    local myLook = me.look
    local best   = -1
    local bestDot = CFG.targetFov

    for i = 1, ac.getSim().carsCount - 1 do
        local car = ac.getCar(i)
        if car and car.isConnected then
            local tocar = car.position - myPos
            local dist  = tocar:length()
            if dist > 1 and dist < CFG.targetRange then
                local dot = myLook:dot(tocar / dist)
                if dot > bestDot then
                    bestDot = dot
                    best    = i
                end
            end
        end
    end
    return best
end

local function getGapAhead()
    -- Returns meters rival is ahead of me (positive = they're in front)
    if rivalIndex < 0 then return 0 end
    local me    = ac.getCar(0)
    local rival = ac.getCar(rivalIndex)
    if not rival then return 0 end
    return (rival.position - me.position):dot(me.look)
end

local function resetRace()
    currentState  = State.IDLE
    rivalIndex    = -1
    rivalName     = ""
    ownHealth     = 1.0
    rivalHealth   = 1.0
    finishMessage = ""
end

-- ── Online Events (forward declared so closures resolve correctly) ──
local challengeEvent, acceptEvent, startEvent, healthEvent, lostEvent

challengeEvent = ac.OnlineEvent({
    targetSessionId = ac.StructItem.int32(),
}, function(sender, data)
    if sender == nil then return end
    if data.targetSessionId ~= ac.getCar(0).sessionID then return end
    if currentState ~= State.IDLE then return end

    rivalIndex         = sender.index
    rivalName          = ac.getDriverName(sender.index)
    currentState       = State.CHALLENGED
    challengeStartTime = now()
    ac.setMessage(rivalName .. " is challenging you! Turn on hazards to accept.", 6)
end)

acceptEvent = ac.OnlineEvent({
    dummy = ac.StructItem.byte(),
}, function(sender, data)
    if sender == nil then return end
    if currentState ~= State.CHALLENGING then return end
    if sender.index ~= rivalIndex then return end

    -- We challenged and they accepted — we own the start time
    raceStartTimeMs = now() + CFG.countdownMs
    ownHealth       = 1.0
    rivalHealth     = 1.0
    currentState    = State.COUNTDOWN
    startEvent{ startTimeMs = raceStartTimeMs }
    ac.setMessage(rivalName .. " accepted! Get ready...", 3)
end)

startEvent = ac.OnlineEvent({
    startTimeMs = ac.StructItem.int64(),
}, function(sender, data)
    if sender == nil then return end
    if currentState ~= State.CHALLENGED then return end
    if sender.index ~= rivalIndex then return end

    raceStartTimeMs = data.startTimeMs
    ownHealth       = 1.0
    rivalHealth     = 1.0
    currentState    = State.COUNTDOWN
    ac.setMessage("Race starting! Get ready...", 3)
end)

healthEvent = ac.OnlineEvent({
    health = ac.StructItem.float(),
}, function(sender, data)
    if sender == nil then return end
    if sender.index ~= rivalIndex then return end
    if currentState ~= State.RACING and currentState ~= State.FINISHED then return end
    rivalHealth = data.health
end)

lostEvent = ac.OnlineEvent({
    dummy = ac.StructItem.byte(),
}, function(sender, data)
    if sender == nil then return end
    if currentState ~= State.RACING then return end
    if sender.index ~= rivalIndex then return end

    currentState  = State.FINISHED
    raceEndTimeMs = now()
    finishMessage = "You won! 🏆"
end)

-- ── Update loop ──────────────────────────────────────────────
function script.update(dt)
    local me          = ac.getCar(0)
    local currentTime = now()

    -- High beam flash detection
    local hb = me.highBeams
    if hb and not prevHighBeam then  -- only count OFF → ON transitions
        if currentTime - flashWindowStart > CFG.flashWindow then
            flashCount = 1
            flashWindowStart = currentTime
        else
            flashCount = flashCount + 1
        end
    
        if flashCount >= CFG.flashThreshold and currentState == State.IDLE then
            flashCount = 0
            local target = findTargetCar()
            if target >= 0 then
                rivalIndex         = target
                rivalName          = ac.getDriverName(target)
                currentState       = State.CHALLENGING
                challengeStartTime = currentTime
                challengeEvent{ targetSessionId = ac.getCar(target).sessionID }
                ac.setMessage("Challenge sent to " .. rivalName .. "!", 4)
            else
                ac.setMessage("No car in range to challenge.", 3)
            end
        end
    end
    prevHighBeam = hb

    -- Hazard press to accept
    local hz = me.hazardLights
    if hz and not prevHazards and currentState == State.CHALLENGED then
        acceptEvent{ dummy = 0 }
        ac.setMessage("Accepted! Waiting for countdown...", 3)
    end
    prevHazards = hz

    -- Challenge timeout (both sides)
    if currentState == State.CHALLENGING or currentState == State.CHALLENGED then
        if currentTime - challengeStartTime > CFG.challengeTimeout then
            local msg = currentState == State.CHALLENGING
                and "Challenge timed out — no response."
                or  "Challenge expired."
            resetRace()
            ac.setMessage(msg, 4)
        end
    end

    -- Countdown → Racing
    if currentState == State.COUNTDOWN and currentTime >= raceStartTimeMs then
        currentState = State.RACING
    end

    -- Race logic
    if currentState == State.RACING then
        local gap = getGapAhead()
        if gap > CFG.behindThreshold then
            local scale = math.min((gap - CFG.behindThreshold) / 25, 2.0)
            ownHealth = math.max(ownHealth - CFG.healthLossRate * scale * dt, 0)
        end

        -- Broadcast our health to rival periodically
        if currentTime - lastHealthSync > CFG.healthSyncMs then
            lastHealthSync = currentTime
            healthEvent{ health = ownHealth }
        end

        -- Check if we lost
        if ownHealth <= 0 then
            currentState  = State.FINISHED
            raceEndTimeMs = currentTime
            finishMessage = "You lost."
            lostEvent{ dummy = 0 }
        end
    end

    -- Auto-reset after finish screen
    if currentState == State.FINISHED then
        if currentTime - raceEndTimeMs > CFG.finishShowMs then
            resetRace()
        end
    end
end

-- ── UI ────────────────────────────────────────────────────────
local colBg  = rgbm(0.1, 0.1, 0.1, 0.75)
local colBar = rgbm(1, 1, 1, 1)

local function drawHealthBar(size, progress, rtl)
    progress = math.clamp(progress, 0, 1)
    colBar:setLerp(rgbm.colors.red, rgbm(0.25, 0.85, 0.25, 1), progress)

    local cur = ui.getCursor()
    ui.drawRectFilled(cur, cur + size, colBg)

    local p1 = rtl and cur + vec2(size.x * (1 - progress), 0) or cur
    local p2 = rtl and cur + size or cur + vec2(size.x * progress, size.y)
    ui.drawRectFilled(p1, p2, colBar)
    ui.dummy(size)
end

local function drawCentered(text, yOff)
    local ws = ac.getUI().windowSize
    ui.transparentWindow('flashRaceMsg',
        vec2(ws.x / 2 - 300, ws.y / 2 + (yOff or -80)),
        vec2(600, 70),
    function()
        ui.pushFont(ui.Font.Huge)
        local sz = ui.measureText(tostring(text))
        ui.setCursorX(ui.getCursorX() + ui.availableSpaceX() / 2 - sz.x / 2)
        ui.text(tostring(text))
        ui.popFont()
    end)
end

function script.drawUI()
    local ws          = ac.getUI().windowSize
    ui.transparentWindow('flashRaceDebug', vec2(10, 10), vec2(400, 30), function()
    ui.pushFont(ui.Font.Main)
    ui.text("Race challenge plugin loaded!")
    ui.popFont()
    local currentTime = now()

    -- Countdown
    if currentState == State.COUNTDOWN then
        local msLeft = raceStartTimeMs - currentTime
        drawCentered(msLeft > 0 and math.ceil(msLeft / 1000) or "GO!")
    end

    -- Race HUD (health bars + timer)
    if currentState == State.RACING or currentState == State.FINISHED then
        local elapsed = (currentState == State.FINISHED and raceEndTimeMs or currentTime) - raceStartTimeMs

        ui.toolWindow('flashRaceHUD', vec2(ws.x / 2 - 480, 18), vec2(960, 108), function()
            ui.pushFont(ui.Font.Title)

            ui.columns(3)
            ui.text("YOU")
            ui.nextColumn()
            local ts  = ac.lapTimeToString(math.max(elapsed, 0))
            local tsz = ui.measureText(ts)
            ui.setCursorX(ui.getCursorX() + ui.availableSpaceX() / 2 - tsz.x / 2)
            ui.text(ts)
            ui.nextColumn()
            ui.textAligned("RIVAL", ui.Alignment.End, vec2(-1, 0))

            ui.columns(2)
            drawHealthBar(vec2(ui.availableSpaceX(), 28), ownHealth, true)
            ui.textAligned(ac.getDriverName(0), ui.Alignment.Start, vec2(-1, 0))
            ui.nextColumn()
            drawHealthBar(vec2(ui.availableSpaceX(), 28), rivalHealth, false)
            ui.textAligned(rivalName, ui.Alignment.End, vec2(-1, 0))

            ui.popFont()
        end)

        if currentState == State.FINISHED and finishMessage ~= "" then
            drawCentered(finishMessage, 60)
        end
    end

    -- Bottom hint when challenged
    if currentState == State.CHALLENGED then
        local timeLeft = math.max(0, CFG.challengeTimeout - (currentTime - challengeStartTime))
        ui.transparentWindow('flashChallengeHint',
            vec2(ws.x / 2 - 280, ws.y - 130),
            vec2(560, 45),
        function()
            ui.pushFont(ui.Font.Main)
            ui.text("⚡ " .. rivalName .. " challenges you! Hazards to accept (" .. math.ceil(timeLeft / 1000) .. "s)")
            ui.popFont()
        end)
    end
end
