gunslinger = {
	__stack = {},
	__guns = {},
	__types = {},
	__automatic = {},
	__scopes = {},
	__interval = {}
}

local config = {
	max_wear = 65534,
	projectile_speed = 500,
	base_dmg = 1,
	base_spread = 0.001,
	base_recoil = 0.001,
	lite = minetest.settings:get_bool("gunslinger.lite")
}

--
-- Internal API functions
--

local function rangelim(low, val, high, default)
	if not val and default then
		return default
	elseif low and val and high then
		return math.max(low, math.min(val, high))
	else
		error("gunslinger: Invalid rangelim invokation!", 2)
	end
end

local function get_eye_pos(player)
	if not player then
		return
	end

	local pos = player:get_pos()
	pos.y = pos.y + player:get_properties().eye_height
	return pos
end

local function get_pointed_thing(pos, dir, def)
	if not pos or not dir or not def then
		error("gunslinger: Invalid get_pointed_thing invocation" ..
				" (missing params)", 2)
	end

	local pos2 = vector.add(pos, vector.multiply(dir, def.range))
	local ray = minetest.raycast(pos, pos2)
	return ray:next()
end

local function play_sound(sound, player)
	minetest.sound_play(sound, {
		object = player,
		loop = false
	})
end

local function add_auto(name, def, stack)
	gunslinger.__automatic[name] = {
		def   = def,
		stack = stack
	}
end

local function validate_def(def)
	if type(def) ~= "table" then
		error("gunslinger.register_gun: Gun definition has to be a table!", 2)
	end

	if (def.mode == "automatic" or def.mode == "hybrid") and config.lite then
		error("gunslinger.register_gun: Attempting to register gun of " ..
				"type '" .. def.mode .. "' when lite mode is enabled", 2)
	end

	if not def.ammo then
		def.ammo = "gunslinger:ammo"
	end

	if def.mode == "burst" then
		def.burst = rangelim(2, def.burst, 5, 3)
	end

	def.dmg_mult = rangelim(1, def.dmg_mult, 100, 1)
	def.reload_time = rangelim(1, def.reload_time, 10, 2.5)
	def.spread_mult = rangelim(0, def.spread_mult, 500, 0)
	def.recoil_mult = rangelim(0, def.recoil_mult, 500, 0)
	def.pellets = rangelim(1, def.pellets, 20, 1)

	-- Initialize sounds
	do
		def.sounds = def.sounds or {}
		def.sounds.fire = def.sounds.fire or "gunslinger_fire"
		def.sounds.reload = def.sounds.reload or "gunslinger_reload"
		def.sounds.ooa = def.sounds.ooa or "gunslinger_ooa"
	end

	return def
end

--------------------------------

local function show_scope(player, scope, zoom)
	if not player then
		return
	end

	-- Create HUD overlay element
	gunslinger.__scopes[player:get_player_name()] = player:hud_add({
		hud_elem_type = "image",
		position = {x = 0.5, y = 0.5},
		alignment = {x = 0, y = 0},
		text = scope
	})
end

local function hide_scope(player)
	if not player then
		return
	end

	local name = player:get_player_name()
	player:hud_remove(gunslinger.__scopes[name])
	gunslinger.__scopes[name] = nil
end

--------------------------------

local function reload(stack, player)
	-- Check for ammo
	local inv = player:get_inventory()
	local def = gunslinger.__guns[stack:get_name()]
	local meta = stack:get_meta()

	if meta:contains("reloading") then
		return
	end

	local taken = inv:remove_item("main", def.ammo .. " " .. def.clip_size)
	if taken:is_empty() then
		play_sound(def.sounds.ooa, player)
	else
		local name = player:get_player_name()
		gunslinger.__interval[name] = gunslinger.__interval[name] - def.reload_time
		play_sound(def.sounds.reload, player)
		meta:set_string("reloading")
		local wear = math.floor(config.max_wear -
				(taken:get_count() / def.clip_size) * config.max_wear)
		minetest.after(def.reload_time, function(obj, rstack, twear, s_meta)
			rstack:set_wear(twear)
			s_meta:set_string("reloading", "")
			player:set_wielded_item(rstack)
		end, player, stack, wear, meta)
	end

	return stack
end

local function fire(stack, player)
	if not stack then
		return
	end

	local def = gunslinger.__guns[stack:get_name()]
	if not def then
		return stack
	end

	local wear = stack:get_wear()
	if wear == config.max_wear then
		gunslinger.__automatic[player:get_player_name()] = nil
		return reload(stack, player)
	end

	-- Play gunshot sound
	play_sound(def.sounds.fire, player)

	--[[
		Perform "deferred raycasting" to mimic projectile entities, without
		actually using entities:
			- Perform initial raycast to get position of target if it exists
			- Calculate time taken for projectile to travel from gun to target
			- Perform actual raycast after the calculated time

		This process throws in a couple more calculations and an extra raycast,
		but the vastly improved realism at the cost of a negligible performance
		hit is always great to have.
	]]
	local time = 0.1 -- Default to 0.1s

	local dir = player:get_look_dir()

	local pos1 = get_eye_pos(player)
	pos1 = vector.add(pos1, dir)
	local initial_pthing = get_pointed_thing(pos1, dir, def)
	if initial_pthing then
		local pos2 = minetest.get_pointed_thing_position(initial_pthing)
		time = vector.distance(pos1, pos2) / config.projectile_speed
	end

	local random = PcgRandom(os.time())

	for i = 1, def.pellets do
		-- Mimic inaccuracy by applying randomised miniscule deviations
		if def.spread_mult ~= 0 then
			dir = vector.apply(dir, function(n)
				return n + random:next(-def.spread_mult, def.spread_mult) * config.base_spread
			end)
		end

		minetest.after(time, function(obj, pos, look_dir, gun_def)
			local pointed = get_pointed_thing(pos, look_dir, gun_def)
			if pointed and pointed.type == "object" then
				local target = pointed.ref
				if target:get_player_name() ~= obj:get_player_name() then
					local point = pointed.intersection_point
					local dmg = config.base_dmg * gun_def.dmg_mult

					-- Add 50% damage if headshot
					if point.y > target:get_pos().y + 1.2 then
						dmg = dmg * 1.5
					end

					-- Add 20% more damage if player using scope
					if gunslinger.__scopes[obj:get_player_name()] then
						dmg = dmg * 1.2
					end

					target:punch(obj, nil, {damage_groups = {fleshy = dmg}})
				end
			elseif pointed and pointed.type == "node" and gun_def.type == "phaser" then
				local pos2 = minetest.get_pointed_thing_position(pointed) 
				local nodeTarget = minetest.get_node(pos2)
				if nodeTarget.name ~= "ignore" and minetest.get_item_group(nodeTarget.name, "no_pew_pew") < 1 and nodeTarget.name ~= "default:steelblock" then
					--minetest.chat_send_all(minetest.get_node(pos2).name)
					minetest.node_dig(pos2, nodeTarget, player)
				end	
			end
		end, player, pos1, dir, def)

		-- Projectile particle
		minetest.add_particle({
			pos = pos1,
			velocity = vector.multiply(dir, config.projectile_speed),
			acceleration = {x = 0, y = 0, z = 0},
			expirationtime = 3,
			size = 3,
			collisiondetection = true,
			collision_removal = true,
			object_collision = true,
			glow = 10
		})
	end

	-- Simulate recoil
	local offset = config.base_recoil * def.recoil_mult
	local look_vertical = player:get_look_vertical() - offset
	look_vertical = rangelim(-math.pi / 2, look_vertical, math.pi / 2)
	player:set_look_vertical(look_vertical)

	-- Update wear
	wear = stack:get_wear() + def.unit_wear
	if wear > config.max_wear then
		wear = config.max_wear
	end
	stack:set_wear(wear)

	return stack
end

local function burst_fire(stack, player)
	local def = gunslinger.__guns[stack:get_name()]
	for i = 1, def.burst do
		minetest.after(i / def.fire_rate, function(...)
			-- Use global var to store stack, because the stack
			-- can't be directly accessed outside minetest.after
			gunslinger.__stack[arg[2]:get_player_name()] = fire(arg[1], arg[2])
		end, stack, player)
	end

	return gunslinger.__stack[player:get_player_name()]
end

--------------------------------

local function on_lclick(stack, player)
	if not stack or not player then
		return
	end

	local def = gunslinger.__guns[stack:get_name()]
	if not def then
		return
	end

	local name = player:get_player_name()
	if gunslinger.__interval[name] and gunslinger.__interval[name] < def.unit_time then
		return
	end
	gunslinger.__interval[name] = 0

	if def.mode == "automatic" and not gunslinger.__automatic[name] then
		stack = fire(stack, player)
		add_auto(name, def, stack)
	elseif def.mode == "hybrid"
			and not gunslinger.__automatic[name] then
		if gunslinger.__scopes[name] then
			stack = burst_fire(stack, player)
		else
			add_auto(name, def)
		end
	elseif def.mode == "burst" then
		stack = burst_fire(stack, player)
	elseif def.mode == "semi-automatic" then
		stack = fire(stack, player)
	elseif def.mode == "manual" then
		local meta = stack:get_meta()
		local loaded = meta:get("loaded")
		if not loaded then
			if def.sounds.load then
				play_sound(def.sounds.load, player)
			end

			meta:set_string("loaded", "true")
			stack = reload(stack, player)
		else
			meta:set_string("loaded", "")
			stack = fire(stack, player)
		end
	end

	return stack
end

local function on_rclick(stack, player)
	local def = gunslinger.__guns[stack:get_name()]
	if not def then
		return
	end
	if gunslinger.__scopes[player:get_player_name()] then
		hide_scope(player)
	else
		if def.scope then
			show_scope(player, def.scope, def.gunslinger.__scopes)
		end
	end
end

--------------------------------

minetest.register_globalstep(function(dtime)
	for name in pairs(gunslinger.__interval) do
		gunslinger.__interval[name] = gunslinger.__interval[name] + dtime
	end
	if not config.lite then
		for name, info in pairs(gunslinger.__automatic) do
			local player = minetest.get_player_by_name(name)
			if not player or player:get_hp() <= 0 then
				gunslinger.__automatic[name] = nil
			elseif gunslinger.__interval[name] > info.def.unit_time then
				if player:get_player_control().LMB and
						player:get_wielded_item():get_name() ==
						info.stack:get_name() then
					-- If LMB pressed, fire
					info.stack = fire(info.stack, player)
					player:set_wielded_item(info.stack)
					if gunslinger.__automatic[name] then
						gunslinger.__automatic[name].stack = info.stack
					end
					gunslinger.__interval[name] = 0
				else
					gunslinger.__automatic[name] = nil
				end
			end
		end
	end
end)

--
-- External API functions
--

function gunslinger.get_def(name)
	return gunslinger.__guns[name]
end

function gunslinger.register_type(name, def)
	assert(type(name) == "string" and type(def) == "table",
	      "gunslinger.register_type: Invalid params!")
	assert(not gunslinger.__types[name], "gunslinger.register_type:" ..
	      " Attempt to register a type with an existing name!")

	gunslinger.__types[name] = def
end

function gunslinger.register_gun(name, def)
	assert(type(name) == "string" and type(def) == "table",
	      "gunslinger.register_gun: Invalid params!")
	assert(not gunslinger.__guns[name], "gunslinger.register_gun: " ..
	      "Attempt to register a gun with an existing name!")

	-- Import type defaults if def.type specified
	if def.type then
		assert(gunslinger.__types[def.type], "gunslinger.register_gun: Invalid type!")

		for attr, val in pairs(gunslinger.__types[def.type]) do
			def[attr] = val
		end
	end

	def = validate_def(def)

	-- Add additional helper fields for internal use
	def.unit_wear = math.ceil(config.max_wear / def.clip_size)
	def.unit_time = 1 / def.fire_rate

	-- Register gun
	gunslinger.__guns[name] = def

	def.itemdef.on_use = on_lclick
	def.itemdef.on_secondary_use = nil
	def.itemdef.on_place = nil

	-- Register tool
	minetest.register_tool(name, def.itemdef)
end
