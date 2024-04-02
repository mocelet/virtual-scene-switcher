
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
  both manual and auto-cycling with customizable delay time.
    
  Also allows to set scenes in advance without activating them and recall them later, 
  typical use case being pre-setting different scenes at different moments of the day 
  so when the light turns on it turns on at the pre-set scene without complex 
  time-checking routines.

  Capabilities and presentations have to be created with the command line, e.g.:
   smartthings capabilities:create -i switcher-capability.json
   smartthings capabilities:presentation:create -i switcher-presentation.json
]]

local LABEL = "Scene Switcher"
local PROFILE = "scene-switcher"
local DEFAULT_SCENES_COUNT = 4
local CURRENT_SCENE_FIELD = "scene.current"
local PRESET_SCENE_PERSISTENT_FIELD = "scene.preset"
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local lua_socket = require "socket"
local log = require "log"

local active_scene = capabilities["panelorange55982.activeScene"]
local create_switcher = capabilities["panelorange55982.createSwitcher"]

local autocycle = {}
local AUTOCYCLE_TIMER = "autocycle.timer"

local created = false

local Actions = {
  NEXT = "next",
  PREV = "previous",
  RECALL = "recall",
  FIRST = "first",
  LAST = "last",
  RESET = "reset",
  AUTOCYCLE_FORWARDS = "autoForwards",
  AUTOCYCLE_BACKWARDS = "autoBackwards",
  AUTOCYCLE_STOP = "autoStop"
}

local CycleModes = {
  CIRCULAR = "circular",
  LINEAR = "linear"
}

local AutostopBehaviour = {
  STARTING = "starting",
  PLUS_ONE = "plusone"
}

local function current_scene(device)
  return device:get_field(CURRENT_SCENE_FIELD) or 1
end

local function cycle_mode(device)
  return device.preferences.cycleMode == CycleModes.LINEAR and CycleModes.LINEAR or CycleModes.CIRCULAR
end

local function scenes_count(device)
  return device.preferences.scenesCount or DEFAULT_SCENES_COUNT
end

local function autostop_behaviour(device)
  return device.preferences.autostopBehaviour == AutostopBehaviour.PLUS_ONE and AutostopBehaviour.PLUS_ONE or AutostopBehaviour.STARTING
end

local function reached_end(device, step)
  local next = current_scene(device) + step
  local max = scenes_count(device)
  return cycle_mode(device) == CycleModes.LINEAR and (next < 1 or next > max)
end

local function scene_in_range(device, scene_number)
  local cycle_mode = cycle_mode(device)
  local scenes_count = scenes_count(device)
  local result = scene_number
  if scene_number > scenes_count then
    result = cycle_mode == CycleModes.CIRCULAR and 1 or scenes_count
  elseif scene_number < 1 then
    result = cycle_mode == CycleModes.CIRCULAR and scenes_count or 1
  end
  return math.tointeger(result)
end

local function default_scene(device)
  local default_scene = device:get_field(PRESET_SCENE_PERSISTENT_FIELD) or 1
  return scene_in_range(device, default_scene)
end

-- Emits the given scene activation
local function activate_scene(device, scene_number)
  local target_scene = scene_in_range(device, scene_number)
  device:emit_component_event(device.profile.components.main, active_scene.scene({value = target_scene}, {state_change = true}))
end

local function switch_to_scene(device, scene_number, activate) 
  local target_scene = scene_in_range(device, scene_number)
  device:set_field(CURRENT_SCENE_FIELD, target_scene)
  if activate then
    activate_scene(device, target_scene)
  else
    -- It is a pre-set scene, store it persistently to survive driver restarts
    -- and restore it when it is initialized
    device:set_field(PRESET_SCENE_PERSISTENT_FIELD, target_scene, { persist = true })
  end
end

local function handle_scene_change(device, cmd, activate)
  local autocycle_was_running = autocycle.running(device)
  autocycle.stop(device) -- Always stop autocycle when receiving any scene command

  local action = cmd.args.scene
  if action == Actions.NEXT or action == Actions.PREV then
    local step = action == Actions.NEXT and 1 or -1
    switch_to_scene(device, current_scene(device) + step, activate)
  elseif action == Actions.FIRST then
    switch_to_scene(device, 1, activate)
  elseif action == Actions.LAST then
    switch_to_scene(device, scenes_count(device), activate)
  elseif action == Actions.RECALL then
    activate_scene(device, current_scene(device))
  elseif action == Actions.RESET then
    local preset = device:get_field(PRESET_SCENE_PERSISTENT_FIELD) or current_scene(device)
    device:set_field(CURRENT_SCENE_FIELD, preset)
  elseif action == Actions.AUTOCYCLE_FORWARDS or action == Actions.AUTOCYCLE_BACKWARDS then
    if autocycle_was_running and device.preferences.autocycleStartStops then
      return -- not starting the auto-cycle
    end
    local delay = device.preferences.autocycleDelay and device.preferences.autocycleDelay / 1000 or 1
    local step = action == Actions.AUTOCYCLE_FORWARDS and 1 or -1 
    autocycle.start(device, delay, step)
  elseif action == Actions.AUTOCYCLE_STOP then
    autocycle.stop(device)
  else
    local scene_number = math.tointeger(action)
    if scene_number then
      switch_to_scene(device, scene_number, activate)
    end
  end
end

-- Changes current scene and also activates it
local function handle_activate_scene(driver, device, cmd)
	handle_scene_change(device, cmd, true)
end

-- Changes current scene but does not activate it
local function handle_preset_scene(driver, device, cmd)
	handle_scene_change(device, cmd, false)
end

-- AUTO-CYCLE FEATURE

autocycle.callback = function(device, delay_seconds, step, switch_count)
  return function()
    switch_to_scene(device, current_scene(device) + step, true)

    -- Stop conditions
    local autostop_offset = autostop_behaviour(device) == AutostopBehaviour.PLUS_ONE and 1 or 0
    local max_switches_count = scenes_count(device) + autostop_offset
    if reached_end(device, step) then
      log.debug("[Auto-cycle] Stopping. Reached end after cycling through " .. switch_count .. " scenes")
      autocycle.stop(device)
      return
    elseif switch_count >= max_switches_count then
      log.debug("[Auto-cycle] Stopping. Completed loop through " .. switch_count .. " scenes")
      autocycle.stop(device)
      return
    end

    -- Prepare next switch
    local timer = device.thread:call_with_delay(delay_seconds, autocycle.callback(device, delay_seconds, step, switch_count + 1))  
    device:set_field(AUTOCYCLE_TIMER, timer) 
  end
end

autocycle.start = function(device, delay_seconds, step)
  autocycle.stop(device)
  log.debug("[Auto-cycle] Started with delay " .. delay_seconds)
  local first_step = autocycle.callback(device, delay_seconds, step, 1)
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

-- VIRTUAL DEVICE CREATION AND LIFECYCLE HANDLING

local function create_device(driver)
  local create_device_msg = {
    type = "LAN",
    device_network_id = 'vswitcher-' .. lua_socket.gettime(),
    label = LABEL,
    profile = PROFILE,
    manufacturer = "SmartThings Community",
    model = "vswitcher",
    vendor_provided_label = LABEL,
  }
                      
  assert (driver:try_create_device(create_device_msg))

end

local function discovery_handler(driver, _, should_continue)
  if not created then
    log.debug("Discovered")
    create_device(driver)
  end
end

--[[
  Called when:
   1) the driver just started up and needs to create the objects for existing devices and 
   2) a device was newly added to the driver.
]]
local function device_init(driver, device)
  log.debug("Init")
  created = true
  local default_scene = default_scene(device)
  device:set_field(CURRENT_SCENE_FIELD, default_scene)
  -- Setting value to 0 on initialization to avoid triggering user defined scenes.
  -- While SmartThings has a state_change attribute, documentation says 
  -- that "state_change = false is not guaranteed to be treated as not a state change"
  device:emit_component_event(device.profile.components.main, active_scene.scene({value = 0}))
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

local function handle_create(driver, device, command)
	create_device(driver)
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
      [active_scene.commands.presetScene.NAME] = handle_preset_scene
    }
  }
})
switcher:run()