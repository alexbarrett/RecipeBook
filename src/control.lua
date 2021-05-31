local event = require("__flib__.event")
local gui = require("__flib__.gui-beta")
local migration = require("__flib__.migration")
local translation = require("__flib__.translation")

local constants = require("constants")
local formatter = require("scripts.formatter")
local global_data = require("scripts.global-data")
local migrations = require("scripts.migrations")
local player_data = require("scripts.player-data")
local remote_interface = require("scripts.remote-interface")
local shared = require("scripts.shared")

local info_gui = require("scripts.gui.info.index")
local quick_ref_gui = require("scripts.gui.quick-ref")

-- -----------------------------------------------------------------------------
-- COMMANDS

commands.add_command("RecipeBook", {"rb-message.command-help"}, function(e)
  if e.parameter == "refresh-player-data" then
    local player = game.get_player(e.player_index)
    player.print{"rb-message.refreshing-player-data"}
    player_data.refresh(player, global.players[e.player_index])
  elseif e.parameter == "clear-memoizer-cache" then
    formatter.create_cache(e.player_index)
    local player = game.get_player(e.player_index)
    player.print{"rb-message.memoizer-cache-purged"}
  else
    game.get_player(e.player_index).print{"rb-message.invalid-command"}
  end
end)

-- TEMPORARY: FOR DEBUGGING ONLY

local function split(str, sep)
  local t = {}
  for substr in string.gmatch(str, "([^"..sep.."]+)") do
    table.insert(t, substr)
  end
  return t
end

commands.add_command("rb-set-option", nil, function(e)
  local player = game.get_player(e.player_index)
  local player_table = global.players[e.player_index]
  local parameters = split(e.parameter, " ")
  if #parameters ~= 2 then
    game.print("Invalid command")
  end
  player_table.settings[parameters[1]] = parameters[2] == "true" and true or false
  shared.refresh_contents(player, player_table)
end)

commands.add_command("rb-toggle-group", nil, function(e)
  local player = game.get_player(e.player_index)
  local player_table = global.players[e.player_index]
  local groups = player_table.settings.groups
  groups[e.parameter] = not groups[e.parameter]
  shared.refresh_contents(player, player_table)
end)

commands.add_command("rb-toggle-category", nil, function(e)
  local player = game.get_player(e.player_index)
  local player_table = global.players[e.player_index]
  local categories = player_table.settings.recipe_categories
  categories[e.parameter] = not categories[e.parameter]
  shared.refresh_contents(player, player_table)
end)

commands.add_command("rb-print-object", nil, function(e)
  local player = game.get_player(e.player_index)
  local player_table = global.players[e.player_index]
  local parameters = split(e.parameter, " ")
  if #parameters ~= 2 then
    game.print("Invalid command")
  end
  if __DebugAdapter then
    __DebugAdapter.print(global.recipe_book[parameters[1]][parameters[2]])
  else
    log(serpent.block(global.recipe_book[parameters[1]][parameters[2]]))
  end
end)

-- -----------------------------------------------------------------------------
-- EVENT HANDLERS

-- BOOTSTRAP

event.on_init(function()
  translation.init()

  global_data.init()
  global_data.build_recipe_book()
  global_data.check_forces()
  for i, player in pairs(game.players) do
    player_data.init(i)
    player_data.refresh(player, global.players[i])
  end
end)

event.on_load(function()
  formatter.create_all_caches()
end)

event.on_configuration_changed(function(e)
  if migration.on_config_changed(e, migrations) then
    translation.init()

    global_data.build_recipe_book()
    global_data.check_forces()

    for i, player in pairs(game.players) do
      player_data.refresh(player, global.players[i])
    end
  end
end)

-- FORCE

event.on_force_created(function(e)
  local force = e.force
  global_data.check_force(force)
end)

event.register({defines.events.on_research_finished, defines.events.on_research_reversed}, function(e)
  if not global.players then return end
  global_data.handle_research_updated(e.research, e.name == defines.events.on_research_finished and true or nil)

  -- refresh all GUIs to reflect finished research
  for _, player in pairs(e.research.force.players) do
    local player_table = global.players[player.index]
    if player_table and player_table.flags.can_open_gui then
      info_gui.update_all(player, player_table)
      quick_ref_gui.update_all(player, player_table)
    end
  end
end)

-- GUI

local function read_action(e)
  local msg = gui.read_action(e)
  if msg then
    if msg.gui == "info" then
      info_gui.handle_action(msg, e)
    elseif msg.gui == "quick_ref" then
      quick_ref_gui.handle_action(msg, e)
    end
    return true
  end
  return false
end

gui.hook_events(read_action)

event.on_gui_click(function(e)
  -- If clicking on the Factory Planner dimmer frame
  if not read_action(e) and e.element.style.name == "fp_frame_semitransparent" then
    -- Bring all GUIs to the front
    local player_table = global.players[e.player_index]
    if player_table.flags.can_open_gui then
      info_gui.bring_all_to_front(player_table)
      quick_ref_gui.bring_all_to_front(player_table)
    end
  end
end)

-- INTERACTION

event.on_lua_shortcut(function(e)
  if e.prototype_name == "rb-search" then
    local player = game.get_player(e.player_index)
    local player_table = global.players[e.player_index]

    -- TODO: Open search GUI
  end
end)

event.register("rb-search", function(e)
  local player = game.get_player(e.player_index)
  local player_table = global.players[e.player_index]

  -- Open the selected prototype
  if player_table.flags.can_open_gui then
    local selected_prototype = e.selected_prototype
    if selected_prototype then
      local class = constants.derived_type_to_class[selected_prototype.base_type]
        or constants.derived_type_to_class[selected_prototype.derived_type]
      -- Not everything will have a Recipe Book entry
      if class then
        local name = selected_prototype.name
        local obj_data = global.recipe_book[class][name]
        if obj_data then
          local context = {class = class, name = name}
          shared.open_page(player, player_table, context)
          return
        end
      end

      -- If we're here, the selected object has no page in RB
      player.create_local_flying_text{
        text = {"message.rb-object-has-no-page"},
        create_at_cursor = true
      }
      player.play_sound{path = "utility/cannot_build"}
    else
      -- TODO: Open search GUI
    end
  end
end)

event.register({"rb-navigate-backward", "rb-navigate-forward", "rb-return-to-home", "rb-jump-to-front"}, function(e)
  local player_table = global.players[e.player_index]
  if player_table.flags.can_open_gui and player_table.flags.gui_open and not player_table.flags.technology_gui_open then
    local event_properties = constants.nav_event_properties[e.input_name]
    -- TODO: Find a way to handle these shortcuts
    -- main_gui.handle_action(
    --   {gui = "main", action = event_properties.action_name},
    --   {player_index = e.player_index, shift = event_properties.shift}
    -- )
  end
end)

-- PLAYER

event.on_player_created(function(e)
  player_data.init(e.player_index)
  local player = game.get_player(e.player_index)
  local player_table = global.players[e.player_index]
  player_data.refresh(player, player_table)
  formatter.create_cache(e.player_index)
end)

event.on_player_removed(function(e)
  player_data.remove(e.player_index)
end)

event.on_player_joined_game(function(e)
  local player_table = global.players[e.player_index]
  if player_table.flags.translate_on_join then
    player_table.flags.translate_on_join = false
    player_data.start_translations(e.player_index)
  end
end)

event.on_player_left_game(function(e)
  if translation.is_translating(e.player_index) then
    translation.cancel(e.player_index)
    global.players[e.player_index].flags.translate_on_join = true
  end
end)

-- TICK

event.on_tick(function(e)
  if translation.translating_players_count() > 0 then
    translation.iterate_batch(e)
  end
end)

-- TRANSLATIONS

-- TODO: Revisit translations system as a whole in flib
event.on_string_translated(function(e)
  local names, finished = translation.process_result(e)
  if names then
    local player_table = global.players[e.player_index]
    local translations = player_table.translations
    for dictionary_name, internal_names in pairs(names) do
      local is_name = not string.find(dictionary_name, "description")
      local dictionary = translations[dictionary_name]
      for i = 1, #internal_names do
        local internal_name = internal_names[i]
        local result = e.translated and e.result or (is_name and internal_name or nil)
        dictionary[internal_name] = result
      end
    end
  end
  if finished then
    local player = game.get_player(e.player_index)
    local player_table = global.players[e.player_index]
    -- show message if needed
    if player_table.flags.show_message_after_translation then
      player.print{'rb-message.can-open-gui'}
    end
    -- create GUI
    -- TODO: Create search GUI - info GUIs are created on demand
    -- main_gui.build(player, player_table)
    -- update flags
    player_table.flags.can_open_gui = true
    player_table.flags.translate_on_join = false -- not really needed, but is here just in case
    player_table.flags.show_message_after_translation = false
    -- enable shortcut
    player.set_shortcut_available("rb-search", true)
  end
end)

-- -----------------------------------------------------------------------------
-- REMOTE INTERFACE

remote.add_interface("RecipeBook", remote_interface)

-- -----------------------------------------------------------------------------
-- SHARED FUNCTIONS

function shared.open_page(player, player_table, context)
  local existing_id = info_gui.find_open_context(player_table, context)[1]
  if existing_id then
    info_gui.handle_action({id = existing_id, action = "bring_to_front"}, {player_index = player.index})
  else
    info_gui.build(player, player_table, context)
  end
end

function shared.toggle_quick_ref(player, player_table, recipe_name)
  if player_table.guis.quick_ref[recipe_name] then
    quick_ref_gui.destroy(player_table, recipe_name)
    shared.update_header_button(player, player_table, {class = "recipe", name = recipe_name}, "quick_ref_button", false)
  else
    quick_ref_gui.build(player, player_table, recipe_name)
    shared.update_header_button(player, player_table, {class = "recipe", name = recipe_name}, "quick_ref_button", true)
  end
end

function shared.update_header_button(player, player_table, context, button, to_state)
  for _, id in pairs(info_gui.find_open_context(player_table, context)) do
    info_gui.handle_action(
      {id = id, action = "update_header_button", button = button, to_state = to_state},
      {player_index = player.index}
    )
  end
end

function shared.refresh_contents(player, player_table)
  formatter.create_cache(player.index)
  info_gui.update_all(player, player_table)
  quick_ref_gui.update_all(player, player_table)
end

function shared.update_global_history(global_history, new_context)
  player_data.update_global_history(global_history, new_context)
end

