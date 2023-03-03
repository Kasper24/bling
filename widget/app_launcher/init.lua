local Gio = require("lgi").Gio
local awful = require("awful")
local gobject = require("gears.object")
local gtable = require("gears.table")
local gtimer = require("gears.timer")
local wibox = require("wibox")
local beautiful = require("beautiful")
local prompt_widget = require(... .. ".prompt")
local fzy = require(... .. ".fzy")
local dpi = beautiful.xresources.apply_dpi
local string = string
local table = table
local math = math
local ipairs = ipairs
local capi = { screen = screen, mouse = mouse }
local path = ...
local helpers = require(tostring(path):match(".*bling") .. ".helpers")

local app_launcher  = { mt = {} }

local KILL_OLD_INOTIFY_SCRIPT = [[ ps x | grep "inotifywait -e modify /usr/share/applications" | grep -v grep | awk '{print $1}' | xargs kill ]]
local INOTIFY_SCRIPT = [[ bash -c "while (inotifywait -e modify /usr/share/applications -qq) do echo; done" ]]
local AWESOME_SENSIBLE_TERMINAL_SCRIPT_PATH = debug.getinfo(1).source:match("@?(.*/)") ..
                                           "awesome-sensible-terminal"
local RUN_AS_ROOT_SCRIPT_PATH = debug.getinfo(1).source:match("@?(.*/)") ..
                                           "run-as-root.sh"

local function default_value(value, default)
    if value == nil then
        return default
    else
        return value
    end
end

local function string_levenshtein(str1, str2)
	local len1 = string.len(str1)
	local len2 = string.len(str2)
	local matrix = {}
	local cost = 0

    -- quick cut-offs to save time
	if (len1 == 0) then
		return len2
	elseif (len2 == 0) then
		return len1
	elseif (str1 == str2) then
		return 0
	end

    -- initialise the base matrix values
	for i = 0, len1, 1 do
		matrix[i] = {}
		matrix[i][0] = i
	end
	for j = 0, len2, 1 do
		matrix[0][j] = j
	end

    -- actual Levenshtein algorithm
	for i = 1, len1, 1 do
		for j = 1, len2, 1 do
			if (str1:byte(i) == str2:byte(j)) then
				cost = 0
			else
				cost = 1
			end

			matrix[i][j] = math.min(matrix[i-1][j] + 1, matrix[i][j-1] + 1, matrix[i-1][j-1] + cost)
		end
	end

    -- return the last value - this is the Levenshtein distance
	return matrix[len1][len2]
end

local function has_value(tab, val)
    for _, value in ipairs(tab) do
        if val:lower():find(value:lower(), 1, true) then
            return true
        end
    end
    return false
end

local function scroll(self, dir)
    if #self:get_grid().children < 1 then
        self._private.selected_app_widget = nil
        return
    end

    local next_app_index = nil
    local if_cant_scroll_func = nil

    if dir == "up" then
        next_app_index = self:get_grid():index(self:get_selected_app_widget()) - 1
        if_cant_scroll_func = function() self:page_backward("up") end
    elseif dir == "down" then
        next_app_index = self:get_grid():index(self:get_selected_app_widget()) + 1
        if_cant_scroll_func = function() self:page_forward("down") end
    elseif dir == "left" then
        next_app_index = self:get_grid():index(self:get_selected_app_widget()) - self:get_grid().forced_num_rows
        if_cant_scroll_func = function() self:page_backward("left") end
    elseif dir == "right" then
        next_app_index = self:get_grid():index(self:get_selected_app_widget()) + self:get_grid().forced_num_rows
        if_cant_scroll_func = function() self:page_forward("right") end
    end

    local next_app = self:get_grid().children[next_app_index]
    if next_app then
        next_app:select()
        self:emit_signal("scroll", dir)
    else
        if_cant_scroll_func()
    end
end

local function app_widget(self, app)
    local widget = nil

    if self.app_template == nil then
        widget = wibox.widget
        {
            widget = wibox.container.background,
            forced_width = dpi(300),
            forced_height = dpi(120),
            bg = self.app_normal_color,
            {
                widget = wibox.container.margin,
                margins = dpi(10),
                {
                    layout = wibox.layout.fixed.vertical,
                    spacing = dpi(10),
                    {
                        widget = wibox.container.place,
                        halign = "center",
                        valign = "center",
                        {
                            widget = wibox.widget.imagebox,
                            id = "icon_role",
                            forced_width = dpi(70),
                            forced_height = dpi(70),
                            image = app.icon
                        },
                    },
                    {
                        widget = wibox.container.place,
                        halign = "center",
                        valign = "center",
                        {
                            widget = wibox.widget.textbox,
                            id = "name_role",
                            markup = string.format("<span foreground='%s'>%s</span>", self.app_name_normal_color, app.name)
                        }
                    }
                }
            }
        }

        widget:connect_signal("mouse::enter", function()
            local widget = capi.mouse.current_wibox
            if widget then
                widget.cursor = "hand2"
            end
        end)

        widget:connect_signal("mouse::leave", function()
            local widget = capi.mouse.current_wibox
            if widget then
                widget.cursor = "left_ptr"
            end
        end)

        widget:connect_signal("button::press", function(app, _, __, button)
            if button == 1 then
                if app:is_selected() or not self.select_before_spawn then
                    app:run()
                else
                    app:select()
                end
            end
        end)
    else
        widget = self.app_template(app, self)
    end

    local app_launcher = self
    function widget:run()
        if app.terminal == true then
            local pid = awful.spawn.with_shell(AWESOME_SENSIBLE_TERMINAL_SCRIPT_PATH .. " -e " .. app.exec)
            local class = app.startup_wm_class or app.name
            awful.spawn.with_shell(string.format(
                [[xdotool search --sync --all --pid %s --name '.*' set_window --classname "%s" set_window --class "%s"]],
                pid,
                class,
                class
            ))
        else
            app:launch()
        end

        if app_launcher.hide_on_launch then
            app_launcher:hide()
        end
    end

    function widget:run_or_select()
        if self:is_selected() then
            self:run()
        else
            self:select()
        end
    end

    function widget:run_as_root()
        if app.terminal == true then
            local pid = awful.spawn.with_shell(
                AWESOME_SENSIBLE_TERMINAL_SCRIPT_PATH .. " -e " ..
                RUN_AS_ROOT_SCRIPT_PATH .. " " ..
                app.exec
            )
            local class = app.startup_wm_class or app.name
            awful.spawn.with_shell(string.format(
                [[xdotool search --sync --all --pid %s --name '.*' set_window --classname "%s" set_window --class "%s"]],
                pid,
                class,
                class
            ))
        else
            awful.spawn(RUN_AS_ROOT_SCRIPT_PATH .. " " .. app.exec)
        end

        if app_launcher.hide_on_launch then
            app_launcher:hide()
        end
    end

    function widget:select()
        if app_launcher:get_selected_app_widget() then
            app_launcher:get_selected_app_widget():unselect()
        end
        app_launcher._private.selected_app_widget = self
        self:emit_signal("select")
        self.selected = true

        if app_launcher.app_template == nil then
            widget.bg = app_launcher.app_selected_color
            local name_widget = self:get_children_by_id("name_role")[1]
            name_widget.markup = string.format("<span foreground='%s'>%s</span>", app_launcher.app_name_selected_color, name_widget.text)
        end
    end

    function widget:unselect()
        self:emit_signal("unselect")
        self.selected = false
        app_launcher._private.selected_app_widget = nil

        if app_launcher.app_template == nil then
            widget.bg = app_launcher.app_normal_color
            local name_widget = self:get_children_by_id("name_role")[1]
            name_widget.markup = string.format("<span foreground='%s'>%s</span>", app_launcher.app_name_normal_color, name_widget.text)
        end
    end

    function widget:is_selected()
        return app_launcher._private.selected_app_widget == self
    end

    function app:run() widget:run() end
    function app:run_or_select() widget:run_or_select() end
    function app:run_as_root() widget:run_as_root() end
    function app:select() widget:select() end
    function app:unselect() widget:unselect() end
    function app:is_selected() widget:is_selected() end

    return widget
end

local function generate_apps(self)
    self._private.all_apps = {}
    self._private.matched_apps = {}

    local app_info = Gio.AppInfo
    local apps = app_info.get_all()
    for _, app in ipairs(apps) do
        if app:should_show() then
            local id = app:get_id()
            local desktop_app_info = Gio.DesktopAppInfo.new(id)
            local name = desktop_app_info:get_string("Name")
            local exec = desktop_app_info:get_string("Exec")

            -- Check if this app should be skipped, depanding on the skip_names / skip_commands table
            if not has_value(self.skip_names, name) and not has_value(self.skip_commands, exec) then
                -- Check if this app should be skipped becuase it's iconless depanding on skip_empty_icons
                local icon = helpers.icon_theme.get_gicon_path(app_info.get_icon(app), self.icon_theme, self.icon_size)
                if icon ~= "" or self.skip_empty_icons == false then
                    if icon == "" then
                        if self.default_app_icon_name ~= nil then
                            icon = helpers.icon_theme.get_icon_path(self.default_app_icon_name, self.icon_theme, self.icon_size)
                        elseif self.default_app_icon_path ~= nil then
                            icon = self.default_app_icon_path
                        else
                            icon = helpers.icon_theme.choose_icon(
                                {"application-all", "application", "application-default-icon", "app"},
                                self.icon_theme, self.icon_size)
                        end
                    end

                    table.insert(self._private.all_apps, {
                        desktop_app_info = desktop_app_info,
                        path = desktop_app_info:get_filename(),
                        id = id,
                        name = name,
                        generic_name = desktop_app_info:get_string("GenericName"),
                        startup_wm_class = desktop_app_info:get_startup_wm_class(),
                        keywords = desktop_app_info:get_string("Keywords"),
                        icon = icon,
                        icon_name = desktop_app_info:get_string("Icon"),
                        terminal = desktop_app_info:get_string("Terminal") == "true" and true or false,
                        exec = exec,
                        launch = function()
                            app:launch()
                        end
                    })
                end
            end
        end
    end

    self:sort_apps()
end

local function build_widget(self)
    local widget = self.widget_template
    if widget == nil then
        self._private.prompt = wibox.widget
        {
            widget = prompt_widget,
            always_on = true,
            reset_on_stop = self.reset_on_hide,
            icon_font = self.prompt_icon_font,
            icon_size = self.prompt_icon_size,
            icon_color = self.prompt_icon_color,
            icon = self.prompt_icon,
            label_font = self.prompt_label_font,
            label_size = self.prompt_label_size,
            label_color = self.prompt_label_color,
            label = self.prompt_label,
            text_font = self.prompt_text_font,
            text_size = self.prompt_text_size,
            text_color = self.prompt_text_color,
        }
        self._private.grid = wibox.widget
        {
            layout = wibox.layout.grid,
            orientation = "horizontal",
            homogeneous = true,
            spacing = dpi(30),
            forced_num_cols = self.apps_per_column,
            forced_num_rows = self.apps_per_row,
        }
        widget = wibox.widget
        {
            layout = wibox.layout.fixed.vertical,
            {
                widget = wibox.container.background,
                forced_height = dpi(120),
                bg = self.prompt_bg_color,
                {
                    widget = wibox.container.margin,
                    margins = dpi(30),
                    {
                        widget = wibox.container.place,
                        halign = "left",
                        valign = "center",
                        self._private.prompt
                    }
                }
            },
            {
                widget = wibox.container.margin,
                margins = dpi(30),
                self._private.grid
            }
        }
    else
        self._private.prompt = widget:get_children_by_id("prompt_role")[1]
        self._private.grid = widget:get_children_by_id("grid_role")[1]
    end

    self._private.widget = awful.popup
    {
        screen = self.screen,
        type = self.type,
        visible = false,
        ontop = true,
        placement = self.placement,
        border_width = self.border_width,
        border_color = self.border_color,
        shape = self.shape,
        bg =  self.bg,
        widget = widget
    }

    self:get_grid():connect_signal("button::press", function(_, lx, ly, button, mods, find_widgets_result)
        if button == 4 then
            self:scroll_up()
        elseif button == 5 then
            self:scroll_down()
        end
    end)

    self:get_prompt():connect_signal("text::changed", function(_, text)
        if text == self:get_text() then
            return
        end

        self._private.text = text
        self._private.search_timer:again()
    end)

    self:get_prompt():connect_signal("key::release", function(_, mod, key, cmd)
        if key == "Escape" then
            self:hide()
        end
        if key == "Return" then
            if self:get_selected_app_widget() ~= nil then
                self:get_selected_app_widget():run()
            end
        end
        if key == "Up" then
            self:scroll_up()
        end
        if key == "Down" then
            self:scroll_down()
        end
        if key == "Left" then
            self:scroll_left()
        end
        if key == "Right" then
            self:scroll_right()
        end
    end)

    self._private.max_apps_per_page = self:get_grid().forced_num_cols * self:get_grid().forced_num_rows
    self._private.apps_per_page = self._private.max_apps_per_page
end

function app_launcher:sort_apps(sort_fn)
    table.sort(self._private.all_apps, sort_fn or self.sort_fn or function(a, b)
        local is_a_favorite = has_value(self.favorites, a.id)
        local is_b_favorite = has_value(self.favorites, b.id)

        -- Sort the favorite apps first
        if is_a_favorite and not is_b_favorite then
            return true
        elseif not is_a_favorite and is_b_favorite then
            return false
        end

        -- Sort alphabetically if specified
        if self.sort_alphabetically then
            return a.name:lower() < b.name:lower()
        elseif self.reverse_sort_alphabetically then
            return b.name:lower() > a.name:lower()
        else
            return true
        end
    end)
end

function app_launcher:set_favorites(favorites)
    self.favorites = favorites
    self:sort_apps()
    self:refresh()
end

function app_launcher:refresh()
    local max_app_index_to_include = self._private.apps_per_page * self:get_current_page()
    local min_app_index_to_include = max_app_index_to_include - self._private.apps_per_page

    self:get_grid():reset()
    collectgarbage("collect")

    for index, app in ipairs(self._private.matched_apps) do
        -- Only add widgets that are between this range (part of the current page)
        if index > min_app_index_to_include and index <= max_app_index_to_include then
            self:get_grid():add(app_widget(self, app))
        end
    end
end

function app_launcher:search()
    local text = self:get_text()
    local old_pos = self:get_grid():get_widget_position(self:get_selected_app_widget())

    -- Reset all the matched apps
    self._private.matched_apps = {}
    -- Remove all the grid widgets
    self:get_grid():reset()
    collectgarbage("collect")

    if text == "" then
        self._private.matched_apps = self._private.all_apps
    else
        for _, app in ipairs(self._private.all_apps) do
            text = text:gsub( "%W", "" )

            -- Filter with fzy
            if fzy.has_match(text:lower(), app.name) or (self.search_commands and fzy.has_match(text:lower(), app.exec)) then
                table.insert(self._private.matched_apps, app)
            end
        end

        -- Sort by string similarity
        table.sort(self._private.matched_apps, function(a, b)
            if self.search_commands then
                return  string_levenshtein(text, a.name) + string_levenshtein(text, a.exec) <
                        string_levenshtein(text, b.name) + string_levenshtein(text, b.exec)
            else
                return string_levenshtein(text, a.name) < string_levenshtein(text, b.name)
            end
        end)
    end
    for _, app in ipairs(self._private.matched_apps) do
        -- Only add the widgets for apps that are part of the first page
        if #self:get_grid().children + 1 <= self._private.max_apps_per_page then
            self:get_grid():add(app_widget(self, app))
        end
    end

    -- Recalculate the apps per page based on the current matched apps
    self._private.apps_per_page = math.min(#self._private.matched_apps, self._private.max_apps_per_page)

    -- Recalculate the pages count based on the current apps per page
    self._private.pages_count = math.ceil(math.max(1, #self._private.matched_apps) / math.max(1, self._private.apps_per_page))

    -- Page should be 1 after a search
    self._private.current_page = 1

    -- This is an option to mimic rofi behaviour where after a search
    -- it will reselect the app whose index is the same as the app index that was previously selected
    -- and if matched_apps.length < current_index it will instead select the app with the greatest index
    if self.try_to_keep_index_after_searching then
        if self:get_grid():get_widgets_at(old_pos.row, old_pos.col) == nil then
            local app = self:get_grid().children[#self:get_grid().children]
            app:select()
        else
            local app = self:get_grid():get_widgets_at(old_pos.row, old_pos.col)[1]
            app:select()
        end
    -- Otherwise select the first app on the list
    elseif #self:get_grid().children > 0 then
        local app = self:get_grid():get_widgets_at(1, 1)[1]
        app:select()
    end

    self:emit_signal("search", self:get_text(), self:get_current_page(), self:get_pages_count())
end

function app_launcher:scroll_up()
    scroll(self, "up")
end

function app_launcher:scroll_down()
    scroll(self, "down")
end

function app_launcher:scroll_left()
    scroll(self, "left")
end

function app_launcher:scroll_right()
    scroll(self, "right")
end

function app_launcher:page_forward(dir)
    local min_app_index_to_include = 0
    local max_app_index_to_include = self._private.apps_per_page

    if self:get_current_page() < self:get_pages_count() then
        min_app_index_to_include = self._private.apps_per_page * self:get_current_page()
        self._private.current_page = self:get_current_page() + 1
        max_app_index_to_include = self._private.apps_per_page * self:get_current_page()
    elseif self.wrap_page_scrolling and #self._private.matched_apps >= self._private.max_apps_per_page then
        self._private.current_page = 1
        min_app_index_to_include = 0
        max_app_index_to_include = self._private.apps_per_page
    elseif self.wrap_app_scrolling then
        local app = self:get_grid():get_widgets_at(1, 1)[1]
        app:select()
        return
    else
        return
    end

    local pos = self:get_grid():get_widget_position(self:get_selected_app_widget())

    -- Remove the current page apps from the grid
    self:get_grid():reset()
    collectgarbage("collect")

    for index, app in ipairs(self._private.matched_apps) do
        -- Only add widgets that are between this range (part of the current page)
        if index > min_app_index_to_include and index <= max_app_index_to_include then
            self:get_grid():add(app_widget(self, app))
        end
    end

    if self:get_current_page() > 1 or self.wrap_page_scrolling then
        local app = nil
        if dir == "down" then
            app = self:get_grid():get_widgets_at(1, 1)[1]
        elseif dir == "right" then
            app = self:get_grid():get_widgets_at(pos.row, 1)
            if app then
                app = app[1]
            end
            if app == nil then
                app = self:get_grid().children[#self:get_grid().children]
            end
        end
        app:select()
    end

    self:emit_signal("page::forward", dir, self:get_current_page(), self:get_pages_count())
end

function app_launcher:page_backward(dir)
    if self:get_current_page() > 1 then
        self._private.current_page = self:get_current_page() - 1
    elseif self.wrap_page_scrolling and #self._private.matched_apps >= self._private.max_apps_per_page then
        self._private.current_page = self:get_pages_count()
    elseif self.wrap_app_scrolling then
        local app = self:get_grid().children[#self:get_grid().children]
        app:select()
        return
    else
        return
    end

    local pos = self:get_grid():get_widget_position(self:get_selected_app_widget())

    -- Remove the current page apps from the grid
    self:get_grid():reset()
    collectgarbage("collect")

    local max_app_index_to_include = self._private.apps_per_page * self:get_current_page()
    local min_app_index_to_include = max_app_index_to_include - self._private.apps_per_page

    for index, app in ipairs(self._private.matched_apps) do
        -- Only add widgets that are between this range (part of the current page)
        if index > min_app_index_to_include and index <= max_app_index_to_include then
            self:get_grid():add(app_widget(self, app))
        end
    end

    local app = nil
    if self:get_current_page() < self:get_pages_count() then
        if dir == "up" then
            app = self:get_grid().children[#self:get_grid().children]
        else
            -- Keep the same row from last page
            local _, columns = self:get_grid():get_dimension()
            app = self:get_grid():get_widgets_at(pos.row, columns)[1]
        end
    elseif self.wrap_page_scrolling then
        app = self:get_grid().children[#self:get_grid().children]
    end
    app:select()

    self:emit_signal("page::backward", dir, self:get_current_page(), self:get_pages_count())
end

function app_launcher:show()
    if self.show_on_focused_screen then
        self:get_widget().screen = awful.screen.focused()
    end

    self:get_widget().visible = true
    self:get_prompt():start()
    self:emit_signal("visibility", true)
end

function app_launcher:hide()
    if self:get_widget().visible == false then
        return
    end

    if self.reset_on_hide == true then
        self:reset()
    end

    self:get_widget().visible = false
    self:get_prompt():stop()
    self:emit_signal("visibility", false)
end

function app_launcher:toggle()
    if self:get_widget().visible then
        self:hide()
    else
        self:show()
    end
end

function app_launcher:reset()
    self:get_grid():reset()
    self._private.matched_apps = self._private.all_apps
    self._private.apps_per_page = self._private.max_apps_per_page
    self._private.pages_count = math.ceil(#self._private.all_apps / self._private.apps_per_page)
    self._private.current_page = 1

    for index, app in ipairs(self._private.all_apps) do
        -- Only add the apps that are part of the first page
        if index <= self._private.apps_per_page then
            self:get_grid():add(app_widget(self, app))
        else
            break
        end
    end

    local app = self:get_grid():get_widgets_at(1, 1)[1]
    app:select()

    self:get_prompt():set_text("")
end

function app_launcher:get_widget()
    return self._private.widget
end

function app_launcher:get_prompt()
    return self._private.prompt
end

function app_launcher:get_grid()
    return self._private.grid
end

function app_launcher:get_pages_count()
    return self._private.pages_count
end

function app_launcher:get_current_page()
    return self._private.current_page
end

function app_launcher:get_text()
    return self._private.text
end

function app_launcher:get_selected_app_widget()
    return self._private.selected_app_widget
end

local function new(args)
    args = args or {}

    args.sort_fn = default_value(args.sort_fn, nil)
    args.favorites = default_value(args.favorites, {})
    args.search_commands = default_value(args.search_commands, true)
    args.skip_names = default_value(args.skip_names, {})
    args.skip_commands = default_value(args.skip_commands, {})
    args.skip_empty_icons = default_value(args.skip_empty_icons, false)
    args.sort_alphabetically = default_value(args.sort_alphabetically, true)
    args.reverse_sort_alphabetically = default_value(args.reverse_sort_alphabetically, false)
    args.select_before_spawn = default_value(args.select_before_spawn, true)
    args.hide_on_left_clicked_outside = default_value(args.hide_on_left_clicked_outside, true)
    args.hide_on_right_clicked_outside = default_value(args.hide_on_right_clicked_outside, true)
    args.hide_on_launch = default_value(args.hide_on_launch, true)
    args.try_to_keep_index_after_searching = default_value(args.try_to_keep_index_after_searching, false)
    args.reset_on_hide = default_value(args.reset_on_hide, true)
    args.wrap_page_scrolling = default_value(args.wrap_page_scrolling, true)
    args.wrap_app_scrolling = default_value(args.wrap_app_scrolling, true)

    args.type = default_value(args.type, "dock")
    args.show_on_focused_screen = default_value(args.show_on_focused_screen, true)
    args.screen = default_value(args.screen, capi.screen.primary)
    args.placement = default_value(args.placement, awful.placement.centered)
    args.bg = default_value(args.bg, "#000000")
    args.border_width = default_value(args.border_width, beautiful.border_width or dpi(0))
    args.border_color = default_value(args.border_color, beautiful.border_color or "#FFFFFF")
    args.shape = default_value(args.shape, nil)

    args.default_app_icon_name = default_value(args.default_app_icon_name, nil)
    args.default_app_icon_path = default_value(args.default_app_icon_path, nil)
    args.icon_theme = default_value(args.icon_theme, nil)
    args.icon_size = default_value(args.icon_size, nil)

    args.apps_per_row = default_value(args.apps_per_row, 5)
    args.apps_per_column = default_value(args.apps_per_column, 3)

    args.prompt_bg_color = default_value(args.prompt_bg_color, "#000000")
    args.prompt_icon_font = default_value(args.prompt_icon_font, beautiful.font)
    args.prompt_icon_size = default_value(args.prompt_icon_size, 12)
    args.prompt_icon_color = default_value(args.prompt_icon_color, "#FFFFFF")
    args.prompt_icon = default_value(args.prompt_icon, "")
    args.prompt_label_font = default_value(args.prompt_label_font, beautiful.font)
    args.prompt_label_size = default_value(args.prompt_label_size, 12)
    args.prompt_label_color = default_value(args.prompt_label_color, "#FFFFFF")
    args.prompt_label = default_value(args.prompt_label, "<b>Search</b>: ")
    args.prompt_text_font = default_value(args.prompt_text_font, beautiful.font)
    args.prompt_text_size = default_value(args.prompt_text_size, 12)
    args.prompt_text_color = default_value(args.prompt_text_color, "#FFFFFF")

    args.app_normal_color = default_value(args.app_normal_color, "#000000")
    args.app_selected_color = default_value(args.app_selected_color, "#FFFFFF")
    args.app_name_normal_color = default_value( args.app_name_normal_color, "#FFFFFF")
    args.app_name_selected_color = default_value(args.app_name_selected_color, "#000000")

    local ret = gobject {}
    gtable.crush(ret, app_launcher, true)
    gtable.crush(ret, args, true)

    ret._private = {}
    ret._private.text = ""
    ret._private.pages_count = 0
    ret._private.current_page = 1
    ret._private.search_timer = gtimer {
        timeout = 0.05,
        call_now = false,
        autostart = false,
        single_shot = true,
        callback = function()
            ret:search()
        end
    }

    if ret.hide_on_left_clicked_outside then
        awful.mouse.append_client_mousebinding(
            awful.button({ }, 1, function (c)
                ret:hide()
            end)
        )

        awful.mouse.append_global_mousebinding(
            awful.button({ }, 1, function (c)
                ret:hide()
            end)
        )
    end
    if ret.hide_on_right_clicked_outside then
        awful.mouse.append_client_mousebinding(
            awful.button({ }, 3, function (c)
                ret:hide()
            end)
        )

        awful.mouse.append_global_mousebinding(
            awful.button({ }, 3, function (c)
                ret:hide()
            end)
        )
    end

    awful.spawn.easy_async_with_shell(KILL_OLD_INOTIFY_SCRIPT, function()
        awful.spawn.with_line_callback(INOTIFY_SCRIPT, {stdout = function()
            generate_apps(ret)
        end})
    end)

    build_widget(ret)
    generate_apps(ret)
    ret:reset()

    return ret
end

function app_launcher.mt:__call(...)
    return new(...)
end

return setmetatable(app_launcher, app_launcher.mt)
