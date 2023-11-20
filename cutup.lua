-- SWIM LIB -- reused functions from multiple swim scripts

-- memoize
function Memoize (f)
    local mem = {} -- memoizing table
    setmetatable(mem, {__mode = "kv"}) -- make it weak
    return function (x) -- new version of ’f’, with memoizing
        local r = mem[x]
        if r == nil then -- no previous result?
            r = f(x) -- calls original function
            mem[x] = r -- store result for reuse
        end
        return r
    end
end

-- queue object
List = {}
function List.new ()
  return {first = 0, last = -1}
end

function List.pushLeft(list, value)
  local first = list.first - 1
  list.first = first
  list[first] = value
end

function List.pushRight(list, value)
  local last = list.last + 1
  list.last = last
  list[last] = value
end

function List.popLeft(list)
  local first = list.first
  if first > list.last then error("list is empty") end
  local value = list[first]
  list[first] = nil        -- to allow garbage collection
  list.first = first + 1
  return value
end

function List.popRight(list)
  local last = list.last
  if list.first > last then error("list is empty") end
  local value = list[last]
  list[last] = nil         -- to allow garbage collection
  list.last = last - 1
  return value
end

function List.length(list)
    return list.last - list.first + 1
end

function RainbowColor(value)
    -- Calculate the hue value based on the numeric value
    local hue = math.floor(value % 360)

    -- Convert the hue value to RGB values
    local function hslToRgb(h, s, l)
        local r, g, b

        if s == 0 then
            r, g, b = l, l, l -- achromatic
        else
            local function hue2rgb(p, q, t)
                if t < 0 then t = t + 1 end
                if t > 1 then t = t - 1 end
                if t < 1 / 6 then return p + (q - p) * 6 * t end
                if t < 1 / 2 then return q end
                if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
                return p
            end

            local q = l < 0.5 and l * (1 + s) or l + s - l * s
            local p = 2 * l - q
            r = hue2rgb(p, q, h + 1 / 3)
            g = hue2rgb(p, q, h)
            b = hue2rgb(p, q, h - 1 / 3)
        end

        return r, g, b
    end

    local r, g, b = hslToRgb(hue / 360, 1, 0.5)
    return rgbm(r, g, b, 1)
end

function IsPlayerBetweenCars(car1, car2, player)

  -- Calculate the distances
  local distanceCar1ToPlayer = vec3.distance(car1.pos, player.pos)
  local distanceCar2ToPlayer = vec3.distance(car2.pos, player.pos)
  local distanceCar1ToCar2 = vec3.distance(car1.pos, car2.pos)

  if distanceCar1ToCar2 > 20 then return false end

  local tolerance = 0.5

  if math.abs((distanceCar1ToPlayer + distanceCar2ToPlayer) - distanceCar1ToCar2) <= tolerance then
    return true
  else
    return false
  end
end

--------------
-- GLOBAL VARS
local overtakeDistance = 5 -- max distance away from player for overtake to count
local playerDistance = 150 -- max distance from player for other players to count to the multiplier

-- event state
local timePassed = 0
local totalScore = 0
local highestScore = 0
local comboMeter = 1
local nearbyPlayers = -1
local playerMultiplier = 0
local carsState = {}
local totalPasses = 0

-- ui state
local messageQueue = List.new()
local drawWindow = true

function AddMessage(text, mood, duration)
    local message = { -- message object
        text = text,
        duration = duration, -- Display for 5 seconds
        color = rgbm.colors.white, -- White color by default
        alpha = 1
    }

    -- add a update function
    message.update = function(dt)
        message.duration = message.duration - dt
        message.alpha = math.max(0, message.alpha - dt / message.duration)
        if message.alpha <= 0 then
            -- Remove the message from the queue when it's no longer visible
            List.popLeft(messageQueue)
        end
    end

    -- set color
    if mood == 1 then
        message.color = rgbm.colors.green -- set color to green if mood 1
    elseif mood == -1 then
        message.color = rgbm.colors.red -- set color to red if mood -1
    end

    List.pushRight(messageQueue, message)
end

function AddCombo(amt)
    if comboMeter + amt > 10 then
        comboMeter = 10
    else
        comboMeter = comboMeter + amt
    end
end

function OnTeleportOrPits(carId)
    AddMessage("You teleported!", -1, 8)
    ResetPoints()
end

-- reset points, save highscore
function ResetPoints()
    if totalScore > highestScore then
        highestScore = math.floor(totalScore)
        ac.sendChatMessage('scored ' .. totalScore .. ' points!')
    end
    totalScore = 0
    comboMeter = 1
end

function GetCarAngle(car1, car2)
    local car1Tocar2 = (car1.pos - car2.pos):normalize()
    -- Calculate angles
    local car2Angle = math.acos(math.dot(car1Tocar2, car1.look)) * (180 / math.pi)
    -- Calculate cross products
    local crossProduct = math.cross(car1.look, car1Tocar2)
    -- Adjust angles based on the sign of the cross product
    if crossProduct.y < 0 then car2Angle = 360 - car2Angle end
    return car2Angle
end

---@diagnostic disable-next-line: duplicate-set-field
function script.prepare(dt)
    ac.onCarJumped(0, OnTeleportOrPits) -- If player teleports, callback registered once
    if dt > 0 then
        return true
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function script.update(dt)
    local player = ac.getCar(0) -- Get player state
    if player == nil then
        return
    end

	if player.isInPitlane then
		if List.length(messageQueue) > 0 then
        	if messageQueue[messageQueue.last].text == "Click End to hide script!" then
            	messageQueue[messageQueue.last].duration = 5
            else
                AddMessage("Click End to hide script!", 0, 10)
        	end
        else
        	AddMessage("Click End to hide script!", 0, 10)
    	end
	end

    local sim = ac.getSim() -- get sim state
    timePassed = timePassed + dt -- update time

    if sim.carsCount > #carsState then
        for i = 1, sim.carsCount do
            carsState[i] = {}
        end
    end

    -- handle totaled car (only works if server has damaged enabled)
    if player.engineLifeLeft < 1 then
        ResetPoints()
    end

    -- define combo fading rate
    local comboFadingRate = 0.05
    if player.speedKmh < 70 then
        comboMeter = 1
    else
	if comboMeter - comboFadingRate * dt < 1 then
	    comboMeter = 1
	else
            comboMeter = comboMeter - comboFadingRate * dt
        end
    end

    local angle = player.localAngularVelocity:length() / math.sqrt(3) -- calculates angle on a scale of 0 - 1
    playerMultiplier = 0 -- is increased for each car that is a nearby player
    nearbyPlayers = -1 -- reset nearby players
    local nearbyCars = {} -- nearby cars

    -- loop through the cars to check for overtakes, (near) collisions
    for i = 1, sim.carsCount do -- i = 1 because lua lists start at 1
        local car = ac.getCar(i-1) -- subtracting 1 beacuse getCar has a zero based index
        if car == nil then
            return
        end
        ---@diagnostic disable-next-line: undefined-field
        local distance = (car.pos - player.pos):length() -- distance between car and player
        ---@diagnostic disable-next-line: undefined-field
        local posDir = (car.pos - player.pos):normalize() -- relative position vector (normalized)
        local posDot = math.dot(posDir, car.look) -- dot product, where car is in relation to player
        local state = carsState[i] -- get state of nearby car

        -- nearby player score multiplier
        if distance < playerDistance then
            ---@diagnostic disable-next-line: param-type-mismatch
            if string.sub(ac.getDriverName(i-1), 1, 7) ~= "Traffic" then
		if playerMultiplier < 8 then playerMultiplier = playerMultiplier + 1 end
		nearbyPlayers = nearbyPlayers + 1
            end
        end

        if distance < 30 then
            table.insert(nearbyCars, car)
	end

        -- only check for collisions and overtakes if car is nearby
        if distance < 15 then

            -- check direction of travel
            local drivingAlong = math.dot(car.look, player.look) > 0.2

            -- check if state exists
            if state.maxPosDot == nil then
                state.collided = false
                state.overtaken = false
                state.maxPosDot = -1
		state.whitelined = false
		state.cut = false
		state.movin = false
            end

            -- check for collision with the player
            if car.collidedWith == 0 then
                if List.length(messageQueue) > 0 then
                    if messageQueue[messageQueue.last].text == "Collision!" then
                        messageQueue[messageQueue.last].duration = 5
                    else
                        AddMessage("Collision!", -1, 8)
                    end
                else
                    AddMessage("Collision!", -1, 8)
                end
                ResetPoints()
                state.collided = true
                collectgarbage("collect")
            end

            -- check for overtakes
            if not state.overtaken and not state.collided and drivingAlong then
	            state.maxPosDot = math.max(state.maxPosDot, posDot)
                if posDot < -0.2 and state.maxPosDot > 0.5 and distance < overtakeDistance then
                    AddMessage("Overtake!", 0, 2)
		    totalScore = totalScore + math.round(10 * comboMeter * playerMultiplier)
		    state.overtaken = true
                end
            end

        else
            state.maxPosDot = -1
            state.overtaken = false
            state.collided = false
	    state.whitelined = false
	    state.cut = false
	    state.movin = false
        end

    end

    for i, car1 in ipairs(nearbyCars) do
        local state1 = carsState[car1.index + 1]
        for j, car2 in ipairs(nearbyCars) do
	   local state2 = carsState[car2.index + 1]
	   if i == j then goto continue end
	   if state1.cut or state2.cut or state1.whitelined or state2.whitelined then goto continue end
	   if car1.index == 0 or car2.index == 0 then goto continue end
	   if IsPlayerBetweenCars(car1, car2, player) then
	       local car1Dot = math.dot((player.pos - car1.pos):normalize(), player.look)
	       local car2Dot = math.dot((player.pos - car2.pos):normalize(), player.look)
	       local car1ToCar2 = (car2.pos - car1.pos):normalize() -- Direction from car1 to car2
	       local dotProduct = math.dot(car1ToCar2, car1.look)
	       local aiDot = math.dot((car1.pos - car2.pos):normalize(), car1.look)
	       local distance = (car1.pos - car2.pos):length()
	       if car1Dot < 0.3 and car1Dot > -0.7 and car2Dot < 0.3 and car2Dot > -0.7 and distance < 6 then
	           AddMessage('Whiteline!', 1, 4)
		   totalScore = totalScore + math.round(100 * comboMeter * playerMultiplier)
		   AddCombo(3)
		   state2.whitelined = true
	       elseif ((car1Dot > 0.5 and car2Dot < -0.5) or (car2Dot > 0.5 and car1Dot < -0.5)) and dotProduct > 0.91 and distance < 18 then
	           AddMessage('Cut!', 1, 12)
		   totalScore = totalScore + math.round(50 * comboMeter * playerMultiplier)
		   state1.cut = true
		   state2.cut = true
		   AddCombo(1)
	       elseif state1.movin == false and state2.movin == false and dotProduct > 0.7 then
	           AddMessage('Movin!', 0, 4)
		   totalScore = totalScore + math.round(10 * comboMeter * playerMultiplier)
		   state1.movin = true
		   state2.movin = true
		   AddCombo(0.5)
	       end
           end
	   ::continue::
	end
    end

    for i = messageQueue.first, messageQueue.last do
        local message = messageQueue[i]
        if message then
            message.update(dt)
        end
    end

    -- print debug info
    ac.debug("overtakes", tostring(overtakes))
    ac.debug("total passes", tostring(totalPasses))
    ac.debug("angle", tostring(angle))
    ac.debug("score", tostring(totalScore))
    ac.debug("nearby players", tostring(nearbyPlayers))
    ac.debug("combo", tostring(comboMeter))
    ac.debug("fading combo", tostring(comboFadingRate))
    ac.debug("draw ui", tostring(drawWindow))

    collectgarbage("step")
end

---@diagnostic disable-next-line: duplicate-set-field
function script.drawUI()
    local uiState = ac.getUI()

    -- start defining the colors
    ---@diagnostic disable-next-line: param-type-mismatch
    local colorRGB = RainbowColor(totalScore + math.floor(timePassed * 10 % 360))

    -- start drawing the ui
    ui.beginTransparentWindow('overtakeScore', vec2(uiState.windowSize.x * 0.5 - 600, 100), vec2(400, 400), false)
    ui.beginOutline()
	
	-- check if drawWindow
    if ui.keyboardButtonPressed(ui.KeyIndex.End) then
        -- Toggle window visibility
        drawWindow = not drawWindow
    end

	if not drawWindow then
		-- end drawing UI
		ui.endOutline(rgbm(0, 0, 0, 0.3))
		ui.endTransparentWindow()
		return
	end

    -- swim> title
    ui.pushStyleVar(ui.StyleVar.Alpha, 1)
    ui.pushFont(ui.Font.Huge)
    ui.textColored('swim>', colorRGB)
    ui.popFont()
    ui.popStyleVar()

    -- current score, multiplier and nearby players
    ui.pushFont(ui.Font.Huge)
    ui.text(totalScore .. ' pts')
    ui.text(math.round(comboMeter, 1) .. 'x')
    ui.sameLine(0, 40)
    ui.text(nearbyPlayers .. 'p(' .. tostring(playerMultiplier) .. 'x)')
    ui.popFont()

    -- Draw messages
    local messagePosY = 200
    if List.length(messageQueue) > 0 then
        while List.length(messageQueue) > 4 or messageQueue[messageQueue.first].alpha < 0 do
            List.popLeft(messageQueue)
        end
    end
    for i = messageQueue.first, messageQueue.last do
        local message = messageQueue[i]
        if message then
            local color = message.color
            color.mult = message.alpha
            ui.textColored(message.text, color)
            messagePosY = messagePosY + 30
        end
    end

    -- end drawing UI
    ui.endOutline(rgbm(0, 0, 0, 0.3))
    ui.endTransparentWindow()

end