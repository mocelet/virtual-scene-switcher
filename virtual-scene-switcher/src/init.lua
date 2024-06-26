-- 
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

--[[ mocelet 2024

  Helper to facilitate cycling through scenes in SmartThings, featuring 
  both manual and auto-cycling with customizable delay time, modes and
  other handy features like multi-tap emulation for buttons that do not
  feature multi-tap.

  Includes detection for unwanted side effects or potential infinite
  loops when used with routines to sync the state. A typical example would be
  synchronizing the scene number by changing it when the brightness changes. 
  If the scene action also changes the brightness, a loop could happen.

  Auto-cycle can store the timer information in persistent memory and restore
  it on initialisation.

    
  Capabilities and presentations have to be created with the command line, e.g.:
   smartthings capabilities:create -i switcher-capability.json
   smartthings capabilities:presentation:create -i switcher-presentation.json
]]

local DEFAULT_NAME = "Scene Switcher"
local MODEL = "Virtual Scene Switcher"
local PROFILE = "scene-switcher"
local DEFAULT_SCENES_COUNT = 4
local CURRENT_SCENE_FIELD = "scene.current"
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local lua_socket = require "socket"
local log = require "log"

local active_scene = capabilities["panelorange55982.activeScene"]
local create_switcher = capabilities["panelorange55982.createSwitcher"]

local autocycle = {}
local AUTOCYCLE_TIMER = "autocycle.timer"
local AUTOCYCLE_BACKUP_PERSISTENT_FIELD = "autocycle.backup"
local AUTOCYCLE_PERSISTED_FIELD = "autocycle.persisted"
local AUTOCYCLE_BACKUP_MIN_DELAY = 60 -- 1 minute

local multitap = {}
local MULTITAP_TIMER = "multitap.timer"
local MULTITAP_COUNT = "multitap.count"
local MULTITAP_DEFAULT_DELAY_SEC = 0.5

local LAST_ACTIVATION_TIME_FIELD = "activation.time"
local DEFAULT_SIDE_EFFECT_RELATIVE_WINDOW = 0
local DEFAULT_SIDE_EFFECT_TARGETED_WINDOW = 0.8

local SMART_REVERSE_DIRECTION_FIELD = "smart.reverse.step"

local PREVIOUS_PRESET_FIELD = "preset.previous"

local created = false
local random_seeded = false

local Actions = {
  NEXT = "next",
  PREV = "previous",
  SKIP_NEXT = "next2",
  SKIP_PREV = "previous2",
  REACTIVATE = "reactivate",
  RECALL = "recall",
  CONDITIONED_RECALL = "recallConditioned",
  FIRST = "first",
  LAST = "last",
  DEFAULT = "default",
  SURPRISE_ME = "surpriseme",
  AUTOCYCLE_FORWARDS = "autoForwards",
  AUTOCYCLE_BACKWARDS = "autoBackwards",
  AUTOCYCLE_RANDOM = "autoRandom",
  AUTOCYCLE_STOP = "autoStop",
  TAP = "tap",
  DOUBLE_TAP = "doubleTap",
  DASHBOARD = "mainAction",
  SMART_NEXT_PREV = "smartNextPrev"
}

local CycleModes = {
  CIRCULAR = "circular",
  LINEAR = "linear",
  LINEAR_REVERSING = "reversing"
}

local AutocycleStartingScene = {
  NEXT_PREV = "nextprev",
  CURRENT = "current",
  INITIAL = "initial",
  FINAL = "final",
  FINAL_INITIAL = "finalInitial",
  FIRST_SECOND = "firstSecond"
}

local AutostopBehaviour = {
  STARTING = "starting",
  MINUS_ONE = "minusone"
}

local DashboardMode = {
  NEXT = "next",
  LOOPING_NEXT = "loopingNext",
  SMART_REVERSE = "smartReverse",
  SMART_AUTO = "smartAuto",
  SMART_AUTO_RANDOM = "smartAutoRandom",
  SURPRISE = "surprise",
  MULTITAP = "multitap",
  DEFAULT_SCENE = "defaultScene",
  REACTIVATE = "reactivate",
  DISABLED = "disabled"
}

local DASHBOARD_BUTTON_MULTITAP_WINDOW = 1200 -- ms

local function random_seed_once()
  if not random_seeded then
    log.debug("Random generator seeded")
    random_seeded = true
    math.randomseed(os.time())
    -- Looks like it's not truly random right after seeding
    math.random()
    math.random()
    math.random()
  end
end

local function current_scene(device)
  return device:get_field(CURRENT_SCENE_FIELD) or 1
end

local function default_scene(device)
  return math.tointeger(device.preferences.defaultScene or 1)
end

local function preset_scene(device)
  return device:get_latest_state("main", active_scene.ID, active_scene.preset.NAME, default_scene(device))
end

local function cycle_mode(device)
  local cycle_mode_pref = device.preferences.cycleMode
  if not cycle_mode_pref then
    return CycleModes.CIRCULAR
  end
  return cycle_mode_pref
end

local function scenes_count(device)
  return device.preferences.scenesCount or DEFAULT_SCENES_COUNT
end

local function scene_out_of_bounds(device, scene_number)
  return not scene_number or scene_number < 1 or scene_number > scenes_count(device)
end

-- Returns a random scene different than the current one
local function random_scene(device)
  random_seed_once()
  local scene_count = scenes_count(device)
  local current_scene = current_scene(device)
  local random_scene = current_scene
  while scene_count > 1 and random_scene == current_scene do
    random_scene = math.random(1, scene_count)
  end
  return random_scene
end

local function autostop_behaviour(device)
  return device.preferences.autostopBehaviour == AutostopBehaviour.MINUS_ONE and AutostopBehaviour.MINUS_ONE or AutostopBehaviour.STARTING
end

local function autostop_on_any_action(device)
  return device.preferences.autoStopCondition ~= "none"
end

local function max_autocycle_switches(device)
  local max_loops = device.preferences.autocycleMaxLoops or 1
  local scenes_count = scenes_count(device)
  if scenes_count == 1 then
    return max_loops
  end

  local period = scenes_count
  if cycle_mode(device) == CycleModes.LINEAR_REVERSING then
    period = 2 * (scenes_count - 1)
  end
  local max_switches = max_loops * period
  local autostop_offset = autostop_behaviour(device) == AutostopBehaviour.MINUS_ONE and 0 or 1
  return max_switches + autostop_offset 
end

local function reached_end(device, step)
  if cycle_mode(device) == CycleModes.CIRCULAR then
    return false
  end
  local next = current_scene(device) + step
  return scene_out_of_bounds(device, next)
end

local function scene_in_range(device, scene_number)
  local cycle_mode = cycle_mode(device)
  local scenes_count = scenes_count(device)
  if scenes_count == 1 then
    return 1
  end

  local result = scene_number
  if cycle_mode == CycleModes.LINEAR or cycle_mode == CycleModes.LINEAR_REVERSING then
    if scene_number > scenes_count then
      result = scenes_count
    elseif scene_number < 1 then
      result = 1
    end
  elseif cycle_mode == CycleModes.CIRCULAR then
    local modulo = scene_number % scenes_count 
    result = modulo == 0 and scenes_count or modulo
  end

  return math.tointeger(result)
end

local function activate_scene(device, scene_number)
  local target_scene = scene_in_range(device, scene_number)
  device:set_field(CURRENT_SCENE_FIELD, target_scene)
  device:set_field(LAST_ACTIVATION_TIME_FIELD, lua_socket.gettime()) -- side effect detection
  device:emit_component_event(device.profile.components.main, active_scene.scene({value = target_scene}, {state_change = true}))
end

-- SIDE_EFFECT DETECTION
-- Using the Switcher in certain automations to sync states can lead to unwanted results.
-- There are two windows, a smaller one for actions usually tied to a button that are expected to be invoked
-- multiple times in a row (like next/prev) and a larger one for actions targetting specific scenes.

local function is_preset_action(action)
  local scene_number = math.tointeger(action)
  return scene_number and scene_number < 0
end

local function specific_scene_target(action)
  return action == Actions.FIRST or action == Actions.LAST or action == Actions.DEFAULT or math.tointeger(action)
end

local function within_delay(timestamp, delay)
  local now = lua_socket.gettime()
  if timestamp then
    local elapsed = now - timestamp
    return elapsed >= 0 and elapsed <= delay
  else
    return false
  end
end

local function last_activation_within_delay(device, delay)
  return within_delay(device:get_field(LAST_ACTIVATION_TIME_FIELD), delay)
end

local function any_action_window(device)
  return device.preferences.sideEffectNoTargetWindow and device.preferences.sideEffectNoTargetWindow / 1000 or DEFAULT_SIDE_EFFECT_RELATIVE_WINDOW
end

local function targeted_action_window(device)
  return device.preferences.sideEffectTargetWindow and device.preferences.sideEffectTargetWindow / 1000 or DEFAULT_SIDE_EFFECT_TARGETED_WINDOW
end

local function may_reset_window(device, action)
  -- The window resets upon receiving a scene number that does not belong to the range
  -- and will not activate anything. Useful to build event suppression mechanisms.
  local scene_number = math.tointeger(action)
  if scene_number and scene_out_of_bounds(device, scene_number) then
    log.debug("[Side-effect] Window reset")
    device:set_field(LAST_ACTIVATION_TIME_FIELD, 0)
    return false
  end
end

local function side_effect_detected(device, action)
  if is_preset_action(action) then
    return false -- Preset actions do not trigger scenes
  end

  if specific_scene_target(action) then
    return last_activation_within_delay(device, targeted_action_window(device))
  else
    return last_activation_within_delay(device, any_action_window(device))
  end
end

-- MAIN HANDLING

local function dashboard_target_action(device, autocycle_was_running)
  local mode = device.preferences.dashboardMode or DashboardMode.SMART_REVERSE

  if mode == DashboardMode.NEXT then
    return Actions.NEXT
  elseif mode == DashboardMode.LOOPING_NEXT then
    return reached_end(device, 1) and Actions.FIRST or Actions.NEXT
  elseif mode == DashboardMode.SMART_REVERSE then
    return Actions.SMART_NEXT_PREV
  elseif mode == DashboardMode.SMART_AUTO then
    return autocycle_was_running and Actions.AUTOCYCLE_STOP or Actions.AUTOCYCLE_FORWARDS
  elseif mode == DashboardMode.SMART_AUTO_RANDOM then
    return autocycle_was_running and Actions.AUTOCYCLE_STOP or Actions.AUTOCYCLE_RANDOM    
  elseif mode == DashboardMode.SURPRISE then
    return Actions.SURPRISE_ME
  elseif mode == DashboardMode.DEFAULT_SCENE then
    return Actions.DEFAULT
  elseif mode == DashboardMode.REACTIVATE then
    return Actions.REACTIVATE
  elseif mode == DashboardMode.MULTITAP then
    multitap.handle_taps(device, 1, DASHBOARD_BUTTON_MULTITAP_WINDOW)
    return nil
  else
    return nil -- disabled
  end
end

local function handle_activate_scene(driver, device, cmd)
  local autocycle_was_running = autocycle.running(device)

  if autostop_on_any_action(device) then
    autocycle.stop(device)
  end
  
  local action = cmd.args.scene
  if side_effect_detected(device, action) then
    log.debug("[Side-effect] Ignored command to switch scene right after activating scene")
    may_reset_window(device, action)
    return
  end

  -- Dashboard button is smart and its actual action depends on the state and settings
  if action == Actions.DASHBOARD then
    action = dashboard_target_action(device, autocycle_was_running)
    if not action then
      return -- Dashboard action is disabled or already handled
    end
  end

  if action == Actions.NEXT or action == Actions.PREV then
    local step = action == Actions.NEXT and 1 or -1
    activate_scene(device, current_scene(device) + step)
  elseif action == Actions.SMART_NEXT_PREV then
    local direction = device:get_field(SMART_REVERSE_DIRECTION_FIELD) or 1
    direction = reached_end(device, direction) and direction * -1 or direction
    device:set_field(SMART_REVERSE_DIRECTION_FIELD, direction)
    local step = direction < 0 and -1 or 1
    activate_scene(device, current_scene(device) + step)
  elseif action == Actions.SKIP_NEXT or action == Actions.SKIP_PREV then
    local step = action == Actions.SKIP_NEXT and 2 or -2
    activate_scene(device, current_scene(device) + step)    
  elseif action == Actions.FIRST then
    activate_scene(device, 1)
  elseif action == Actions.LAST then
    activate_scene(device, scenes_count(device))
  elseif action == Actions.DEFAULT then
    activate_scene(device, default_scene(device))
  elseif action == Actions.SURPRISE_ME then
    activate_scene(device, random_scene(device))
  elseif action == Actions.REACTIVATE then
    activate_scene(device, current_scene(device))
  elseif action == Actions.RECALL then
    activate_scene(device, preset_scene(device))
  elseif action == Actions.CONDITIONED_RECALL then
    local previous_preset = device:get_field(PREVIOUS_PRESET_FIELD)
    if not previous_preset or previous_preset == current_scene(device) then
      activate_scene(device, preset_scene(device))
    end
  elseif action == Actions.AUTOCYCLE_FORWARDS or action == Actions.AUTOCYCLE_BACKWARDS or action == Actions.AUTOCYCLE_RANDOM then
    if autocycle_was_running and device.preferences.autocycleStartStops then
      autocycle.stop(device)
      return
    end
    local random = action == Actions.AUTOCYCLE_RANDOM
    local step = random and 0 or (action == Actions.AUTOCYCLE_FORWARDS and 1 or -1)
    autocycle.start(device, step)
  elseif action == Actions.AUTOCYCLE_STOP then
    autocycle.stop(device)
  elseif action == Actions.TAP or action == Actions.DOUBLE_TAP then
    local taps = action == Actions.DOUBLE_TAP and 2 or 1
    multitap.handle_taps(device, taps, device.preferences.multiTapDelayMillis)
  else -- Actions "1", "2"... for activate, "-1", "-2"... for preset
    local raw_number = math.tointeger(action)
    local preset = raw_number and raw_number < 0
    local scene_number = preset and raw_number * -1 or raw_number

    if scene_out_of_bounds(device, scene_number) then
      log.debug("Scene out of bounds")
      return -- Ignore action
    end

    if preset then
      local previous_preset = device:get_latest_state("main", active_scene.ID, active_scene.preset.NAME)
      device:set_field(PREVIOUS_PRESET_FIELD, previous_preset)
      device:emit_component_event(device.profile.components.main, active_scene.preset({value = scene_number}))
    else
      activate_scene(device, scene_number)
    end   
  end
end

-- AUTO-CYCLE FEATURE

local function autocycle_emit_started(device)
  if active_scene.autocycle then
    device:emit_component_event(device.profile.components.main, active_scene.autocycle({value = "started"}))
  end
end

local function autocycle_emit_stopped(device)
  if active_scene.autocycle then
    device:emit_component_event(device.profile.components.main, active_scene.autocycle({value = "stopped"}))
  end
end

local function autocycle_delay(device) 
  -- Mind that long auto-cycle settings (minutes) override the standard ones (millis) if non-zero
  local standard_delay = device.preferences.autocycleDelay and device.preferences.autocycleDelay / 1000 or 1
  local long_delay = device.preferences.autocycleDelayMinutes and device.preferences.autocycleDelayMinutes * 60 or 0
  local delay = long_delay > 0 and long_delay or standard_delay

  local max_random_offset = device.preferences.autocycleRandomMinutes and device.preferences.autocycleRandomMinutes * 60 or 0  
  if max_random_offset > 0 then
    random_seed_once()
    return delay + math.random(0, max_random_offset)
  else
    return delay
  end
end

local function autocycle_starting_scene(device, step)
  local starting_pref = device.preferences.autocycleStartingScene
  if starting_pref == AutocycleStartingScene.INITIAL then
    return 1
  elseif starting_pref == AutocycleStartingScene.FINAL then
    return scenes_count(device)
  elseif starting_pref == AutocycleStartingScene.CURRENT then
    return current_scene(device)
  elseif starting_pref == AutocycleStartingScene.FINAL_INITIAL then
    return step < 0 and scenes_count(device) or 1
  elseif starting_pref == AutocycleStartingScene.FIRST_SECOND then
      return step < 0 and 1 or 2
  else
    return current_scene(device) + step
  end
end

local function autocycle_start_timer(device, delay, step, switch_count, target_scene)
  local timer = device.thread:call_with_delay(delay, autocycle.callback(device, step, switch_count, target_scene))  
  device:set_field(AUTOCYCLE_TIMER, timer) 
  autocycle.may_backup(device, delay, step, switch_count, target_scene)
end

autocycle.callback = function(device, step, switch_count, scene)
  return function()
    local target_scene
    local updated_step = step
    if switch_count == -1 then
      -- First step has to be delayed too, do not activate now
      target_scene = step == 0 and random_scene(device) or scene
    else
      activate_scene(device, scene)
      if cycle_mode(device) == CycleModes.LINEAR_REVERSING then
        if scene_out_of_bounds(device, current_scene(device) + updated_step) then
          updated_step = updated_step * -1
        end
      end
      target_scene = step == 0 and random_scene(device) or current_scene(device) + updated_step
    end

    local updated_switch_count = switch_count + 1    
    
    -- Stop conditions
    local stopped = false
    if updated_switch_count == 1 and device.preferences.autocycleSwitchOnce then
      log.debug("[Auto-cycle] Stopping after one switch")
      stopped = true
    elseif updated_switch_count > 0 and reached_end(device, updated_step) then
      log.debug("[Auto-cycle] Stopping. Reached end after switching " .. updated_switch_count .. " scenes")
      stopped = true
    elseif updated_switch_count >= max_autocycle_switches(device) then
      log.debug("[Auto-cycle] Stopping. Completed loop through " .. updated_switch_count .. " scenes")
      stopped = true
    end

    if stopped then
      autocycle.stop(device)
      autocycle_emit_stopped(device)
    else
      local delay = autocycle_delay(device)
      autocycle_start_timer(device, delay, updated_step, updated_switch_count, target_scene)
      if updated_switch_count <= 1 then
        autocycle_emit_started(device)
      end
    end
  end
end

autocycle.start = function(device, step)
  autocycle.stop(device)
 
  local message
  local starting_scene
  if step == 0 then
    message = "[Auto-cycle] Started random cycling"
    starting_scene = random_scene(device)
  else
    message = "[Auto-cycle] Started sequential cycling"
    starting_scene = autocycle_starting_scene(device, step)
  end
  local initial_switch_count = device.preferences.autocycleDelayedStart and -1 or 0
  local first_step = autocycle.callback(device, step, initial_switch_count, starting_scene)
  first_step()
end

autocycle.stop = function(device)
  local timer = device:get_field(AUTOCYCLE_TIMER)
  if timer then
    log.debug("[Auto-cycle] Stopped")
    device.thread:cancel_timer(timer)
    device:set_field(AUTOCYCLE_TIMER, nil)
    autocycle.delete_backup(device)
    autocycle_emit_stopped(device)
  end
end

autocycle.running = function(device)
  return device:get_field(AUTOCYCLE_TIMER)
end

autocycle.delete_backup = function(device)
  local persisted = device:get_field(AUTOCYCLE_PERSISTED_FIELD)
  if not persisted then
    return
  end
  log.debug("[Auto-cycle] Timer backup deleted")
  device:set_field(AUTOCYCLE_PERSISTED_FIELD, nil)
  device:set_field(AUTOCYCLE_BACKUP_PERSISTENT_FIELD, nil, { persist = true })  
end

autocycle.may_backup = function(device, delay, step, switch_count, target_scene)
  if delay < AUTOCYCLE_BACKUP_MIN_DELAY then
    return
  end

  local version = 1
  local starting_time = os.time()
  local serialized = version .. " " .. starting_time .. " " .. delay .. " " .. step .. " " .. switch_count .. " " .. target_scene
  log.debug("[Auto-cycle] Backing up long spanned cycle: " .. serialized)
  device:set_field(AUTOCYCLE_PERSISTED_FIELD, starting_time)
  device:set_field(AUTOCYCLE_BACKUP_PERSISTENT_FIELD, serialized, { persist = true }) 
end

autocycle.restore = function(device)
  local serialized_backup = device:get_field(AUTOCYCLE_BACKUP_PERSISTENT_FIELD)
  if not serialized_backup then
    autocycle_emit_stopped(device)
    return
  end

  device:set_field(AUTOCYCLE_BACKUP_PERSISTENT_FIELD, nil, { persist = true })

  local numbers = {} 
  for part in serialized_backup:gmatch("%S+") do
    local number_value = tonumber(part)
    if not number_value then
      log.debug("[Auto-cycle] Wrong backup value")
      autocycle_emit_stopped(device)
      return
    end
    table.insert(numbers, number_value)
  end

  if #numbers ~= 6 then
    log.debug("[Auto-cycle] Wrong backup format")
    autocycle_emit_stopped(device)
    return
  end

  local version = numbers[1]
  local starting_time = numbers[2]
  local restored_delay = numbers[3]
  local step = numbers[4]
  local switch_count = numbers[5]
  local target_scene = numbers[6]

  local elapsed_seconds = os.time() - starting_time
  log.debug("[Auto-cycle] Elapsed time since backup: " .. elapsed_seconds .. " s")
  local relaunch_delay = restored_delay - elapsed_seconds
  if elapsed_seconds < 0 or relaunch_delay < 0 then
    log.debug("[Auto-cycle] Backup out of time")
    autocycle_emit_stopped(device)
    return
  end

  log.debug("[Auto-cycle] Timer restored. Switching scene in: " .. relaunch_delay .. " s")
  autocycle_start_timer(device, relaunch_delay, step, switch_count, target_scene)
  autocycle_emit_started(device)
end


--[[ MULTI-TAP EMULATION MODE

Makes any button able to run actions with double-tap, triple-tap, etc. 
Even buttons with native double-tap can be extended!

Each scene activated represents the type, for instance 1 single-tap, 2 double-tap, 
3 tripe-tap and so on.

User only needs to Register Pressed or Double events in their button. For buttons
with native double-tap, the delay should be larger than the native window.

]]

multitap.finish = function(device)
  local tap_count = device:get_field(MULTITAP_COUNT) or 0
  local target_scene = math.min(tap_count, scenes_count(device))
  device:set_field(MULTITAP_TIMER, nil)
  device:set_field(MULTITAP_COUNT, nil)
  activate_scene(device, target_scene)
end

multitap.stop_timer = function(device)
  local timer = device:get_field(MULTITAP_TIMER)
  if timer then
    device.thread:cancel_timer(timer)
    device:set_field(MULTITAP_TIMER, nil)
  end
end

multitap.callback = function(device)
  return function()
    -- No taps during waiting period
    multitap.finish(device)
  end
end

multitap.handle_taps = function(device, taps, multitap_window_millis)
  multitap.stop_timer(device)
  local max_taps = scenes_count(device)
  local previous_tap_count = device:get_field(MULTITAP_COUNT) or 0
  local tap_count = previous_tap_count + taps
  device:set_field(MULTITAP_COUNT, tap_count)
  if tap_count >= max_taps then
    multitap.finish(device)
  else
    local delay = multitap_window_millis and multitap_window_millis / 1000 or MULTITAP_DEFAULT_DELAY_SEC
    local timer = device.thread:call_with_delay(delay, multitap.callback(device))
    device:set_field(MULTITAP_TIMER, timer)
  end
end

-- VIRTUAL DEVICE CREATION AND LIFECYCLE HANDLING

local function random_id(length)
  random_seed_once()
  local id = ""
  for i = 1, length do
    id = id .. string.format('%x', math.random(0, 0xf))    
  end
  return id
end

local function create_device(driver, device_name)
  local create_device_msg = {
    type = "LAN",
    device_network_id = "v-" .. random_id(4) .. lua_socket.gettime(), -- Lua random is not always random even seeded
    label = device_name,
    profile = PROFILE,
    manufacturer = "SmartThings Community",
    model = MODEL,
    vendor_provided_label = device_name,
  }
                      
  assert (driver:try_create_device(create_device_msg))

end

-- Add device: scan nearby
local function discovery_handler(driver, _, should_continue)
  if not created then
    log.debug("Discovered")
    create_device(driver, DEFAULT_NAME)
  end
end

-- Create button
local function handle_create(driver, device, command)
	local device_count = #driver:get_devices()
  local device_name = string.format("%s %d", DEFAULT_NAME, device_count + 1)
  create_device(driver, device_name)
end

--[[
  Called when:
   1) the driver just started up and needs to create the objects for existing devices and 
   2) a device was newly added to the driver.
]]
local function device_init(driver, device)
  created = true
  local default_scene = default_scene(device)
  local current_scene = device:get_latest_state("main", active_scene.ID, active_scene.scene.NAME, default_scene)
  log.debug("Initializing with scene: " .. current_scene)
  device:set_field(CURRENT_SCENE_FIELD, current_scene)
  autocycle.restore(device)
end

--[[
  A device was newly added to this driver. This represents when the device is, for the first time, 
  assigned to run with this driver.
]]
local function device_added(driver, device)
  log.debug("Added")
  local default_scene = default_scene(device)
  device:set_field(CURRENT_SCENE_FIELD, default_scene)
  device:emit_component_event(device.profile.components.main, active_scene.scene({value = 0}))
end

--[[
  This represents a device being removed from this driver.
]]
local function device_removed(driver, device)
  log.debug("Removed")
  local devices = driver:get_devices()
  if #devices == 0 then
    log.debug("Last device removed")
    created = false
  end
end

local switcher = Driver("virtual-scene-switcher", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    removed = device_removed
  },
  capability_handlers = {
    [create_switcher.ID] = {
      [create_switcher.commands.create.NAME] = handle_create,
    },
    [active_scene.ID] = {
      [active_scene.commands.activateScene.NAME] = handle_activate_scene,
    }
  }
})
switcher:run()