local Gio = require("lgi").Gio
local Gtk = require("lgi").Gtk
local gobject = require("gears.object")
local gtable = require("gears.table")
local setmetatable = setmetatable
local ipairs = ipairs

local icon_theme = { mt = {} }

local name_lookup =
{
    ["jetbrains-studio"] = "android-studio"
}

function icon_theme:get_client_icon_path(client, default_icon_name)
    local icon_name = client.icon_name and client.icon_name:lower() or nil
    for _, app in ipairs(Gio.AppInfo.get_all()) do
        if icon_name ~= nil then
            local name = app:get_name():lower()
            if name:match(icon_name) then
                return self:get_gicon_path(app:get_icon())
            end
        end
    end

    local class = name_lookup[client.class] or client.class:lower()

    -- Try to remove dash
    local class_1 = class:gsub("[%-]", "")

    -- Try to replace dash with dot
    local class_2 = class:gsub("[%-]", ".")

    -- Try to match only the first word
    local class_3 = class:match("(.-)-") or class
    class_3 = class_3:match("(.-)%.") or class_3
    class_3 = class_3:match("(.-)%s+") or class_3

    local possible_icon_names = { class, class_3, class_2, class_1 }
    for _, app in ipairs(Gio.AppInfo.get_all()) do
        local id = app:get_id():lower()
        for _, possible_icon_name in ipairs(possible_icon_names) do
            if id:match(possible_icon_name) then
                return self:get_gicon_path(app:get_icon())
            end
        end
    end

    return self:get_icon_path(default_icon_name or "gnome-window-manager")
end

function icon_theme:choose_icon(icons_names)
    local icon_info = Gtk.IconTheme.choose_icon(self.gtk_theme, icons_names, self.icon_size, 0);
    if icon_info then
        local icon_path = Gtk.IconInfo.get_filename(icon_info)
        if icon_path then
            return icon_path
        end
    end

    return ""
end

function icon_theme:get_gicon_path(gicon)
    if gicon == nil then
        return ""
    end

    local icon_info = Gtk.IconTheme.lookup_by_gicon(self.gtk_theme, gicon, self.icon_size, 0);
    if icon_info then
        local icon_path = Gtk.IconInfo.get_filename(icon_info)
        if icon_path then
            return icon_path
        end
    end

    return ""
end

function icon_theme:get_icon_path(icon_name)
    local icon_info = Gtk.IconTheme.lookup_icon(self.gtk_theme, icon_name, self.icon_size, 0);
    if icon_info then
        local icon_path = Gtk.IconInfo.get_filename(icon_info)
        if icon_path then
            return icon_path
        end
    end

    return ""
end

local function new(theme_name, icon_size)
    local ret = gobject{}
    gtable.crush(ret, icon_theme, true)

    ret.name = theme_name or nil
    ret.icon_size = icon_size or 48

    if theme_name then
        ret.gtk_theme = Gtk.IconTheme.new()
        Gtk.IconTheme.set_custom_theme(ret.gtk_theme, theme_name);
    else
        ret.gtk_theme = Gtk.IconTheme.get_default()
    end

    return ret
end

function icon_theme.mt:__call(...)
    return new(...)
end

return setmetatable(icon_theme, icon_theme.mt)
