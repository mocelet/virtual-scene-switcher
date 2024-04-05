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

  Originally it featured presetting/recalling scenes using persistent storage
  but it has been removed. According to the official documentation, persistent 
  storage should be almost avoided because "carries with it a cost in wear [of 
  the hub], as well as time delays associated with the writing and reading".
  
  Preset feature is now implemented using transient fields, meaning it will
  not survive restarts. However, there is a setting to specify the default scene used
  in that case and minimize the inconvenience.
    
  Capabilities and presentations have to be created with the command line, e.g.:
   smartthings capabilities:create -i switcher-capability.json
   smartthings capabilities:presentation:create -i switcher-presentation.json
]]

local DEFAULT_NAME = "Scene Switcher"
local MODEL = "Virtual Scene Switcher"
local PROFILE = "scene-switcher"
local DEFAULT_SCENES_COUNT = 4
local CURRENT_SCENE_FIELD = "scene.current"
local PRESET_SCENE_FIELD = "scene.memory"
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local lua_socket = require "socket"
local log = require "log"

local active_scene = capabilities["panelorange55982.activeScene"]
local create_switcher = capabilities["panelorange55982.createSwitcher"]

local autocycle = {}
local AUTOCYCLE_TIMER = "autocycle.timer"

local multitap = {}
local MULTITAP_TIMER = "multitap.timer"
local MULTITAP_COUNT = "multitap.count"
local MULTITAP_DEFAULT_DELAY_SEC = 0.5

local created = false
local random_seeded = false

local Actions = {
  NEXT = "next",
  PREV = "previous",
  SKIP_NEXT = "next2",
  SKIP_PREV = "previous2",
  REACTIVATE = "reactivate",
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
}

local CycleModes = {
  CIRCULAR = "circular",
  LINEAR = "linear"
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

local function random_seed_once()
  if not random_seeded then
    log.debug("Random generator seeded")
    random_seeded = true
    math.randomseed(os.time())
    math.random()
  end
end

local function current_scene(device)
  return device:get_field(CURRENT_SCENE_FIELD) or 1
end

local function preset_scene(device)
  return device:get_field(PRESET_SCENE_FIELD) or current_scene(device)
end

local function default_scene(device)
  return math.tointeger(device.preferences.defaultScene or 1)
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

local function max_autocycle_switches(device)
  local max_loops = device.preferences.autocycleMaxLoops or 1
  local max_switches = max_loops * scenes_count(device)
  local autostop_offset = autostop_behaviour(device) == AutostopBehaviour.MINUS_ONE and 0 or 1
  return max_switches + autostop_offset 
end

local function preset_mode_enabled(device)
  return device.preferences.presetRecallEnabled
end

local function reached_end(device, step)
  if cycle_mode(device) == CycleModes.CIRCULAR then
    return false
  end
  local next = current_scene(device) + step
  local max = scenes_count(device)
  return next < 1 or next > max
end

local function scene_in_range(device, scene_number)
  local cycle_mode = cycle_mode(device)
  local scenes_count = scenes_count(device)
  local result = scene_number

  if cycle_mode == CycleModes.LINEAR then
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
  device:emit_component_event(device.profile.components.main, active_scene.scene({value = target_scene}, {state_change = true}))
end

local function handle_activate_scene(driver, device, cmd)
  local autocycle_was_running = autocycle.running(device)
  autocycle.stop(device) -- Stopping autocycle with any action is convenient

  local action = cmd.args.scene
  if action == Actions.NEXT or action == Actions.PREV then
    local step = action == Actions.NEXT and 1 or -1
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
    local preset_mode = preset_mode_enabled(device)
    local target_scene = preset_mode and preset_scene(device) or current_scene(device)
    activate_scene(device, target_scene)
  elseif action == Actions.AUTOCYCLE_FORWARDS or action == Actions.AUTOCYCLE_BACKWARDS or action == Actions.AUTOCYCLE_RANDOM then
    if autocycle_was_running and device.preferences.autocycleStartStops then
      return -- not starting the auto-cycle
    end
    local random = action == Actions.AUTOCYCLE_RANDOM
    local delay = device.preferences.autocycleDelay and device.preferences.autocycleDelay / 1000 or 1
    local step = random and 0 or (action == Actions.AUTOCYCLE_FORWARDS and 1 or -1)
    autocycle.start(device, delay, step)
  elseif action == Actions.AUTOCYCLE_STOP then
    autocycle.stop(device)
  elseif action == Actions.TAP or action == Actions.DOUBLE_TAP then
    local taps = action == Actions.DOUBLE_TAP and 2 or 1
    multitap.handle_taps(device, taps, device.preferences.multiTapDelayMillis)
  else -- Actions "1", "2"...
    local scene_number = math.tointeger(action)
    local preset_mode = preset_mode_enabled(device)
    if scene_number and preset_mode then
      device:set_field(PRESET_SCENE_FIELD, scene_number) 
    elseif scene_number and not preset_mode then
      activate_scene(device, scene_number)
    end
  end
end

-- AUTO-CYCLE FEATURE

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

autocycle.callback = function(device, delay_seconds, step, switch_count, scene)
  return function()
    activate_scene(device, scene, true)
    local updated_switch_count = switch_count + 1
    local target_scene = step == 0 and random_scene(device) or current_scene(device) + step
    
    -- Stop conditions
    if reached_end(device, step) then
      log.debug("[Auto-cycle] Stopping. Reached end after cycling through " .. updated_switch_count .. " scenes")
      autocycle.stop(device)
      return
    elseif updated_switch_count >= max_autocycle_switches(device) then
      log.debug("[Auto-cycle] Stopping. Completed loop through " .. updated_switch_count .. " scenes")
      autocycle.stop(device)
      return
    end

    -- Prepare next switch
    local timer = device.thread:call_with_delay(delay_seconds, autocycle.callback(device, delay_seconds, step, updated_switch_count, target_scene))  
    device:set_field(AUTOCYCLE_TIMER, timer) 
  end
end

autocycle.start = function(device, delay_seconds, step)
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
  --log.debug(string.format("%s from scene %d. Step: %d. Delay: %f s", message, starting_scene, step, delay_seconds))

  local first_step = autocycle.callback(device, delay_seconds, step, 0, starting_scene)
  first_step()
end

autocycle.stop = function(device)
  local timer = device:get_field(AUTOCYCLE_TIMER)
  if timer then
    log.debug("[Auto-cycle] Stopped")
    device.thread:cancel_timer(timer)
    device:set_field(AUTOCYCLE_TIMER, nil)
  end
end

autocycle.running = function(device)
  return device:get_field(AUTOCYCLE_TIMER)
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
    timer = device.thread:call_with_delay(delay, multitap.callback(device))
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
    device_network_id = "v-" .. random_id(20),
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