--[[ tally.lua — Tally counter for GNOME ]]--

local lib = require "tallylib"

local lgi = require "lgi"
local Adw = lgi.require "Adw"
local Gtk = lgi.require "Gtk"

local app_id = lib.get_app_id()
local is_devel = lib.get_devel()
local app = Adw.Application {
	application_id = app_id,
}

-- Tally counter row widget

local tally = {}
local tally_mt = { __index = tally }

function tally:update()
	self.row.title = self.name
	self.row.value = self.value
end

local function new_tallycounter(name)
	local t = setmetatable({
		value = 0,
		name = name,
		row = Adw.SpinRow(),
	}, tally_mt)
	local namerow = Adw.EntryRow {
		text = name,
		title = "Name",
	}
	local valuerow = Adw.EntryRow {
		text = t.value,
		title = "Count",
	}
	local haserror = {
		[namerow] = false,
		[valuerow] = false,
	}
	local savebtn = Gtk.Button.new_with_label "Apply"
	local function refresh_button()
		for _, val in pairs(haserror) do
			if val then
				savebtn.sensitive = false
				return
			end
		end
		savebtn.sensitive = true
	end
	function namerow:on_changed()
		if #self.text == 0 then
			self:add_css_class "error"
			haserror[self] = true
		else
			self:remove_css_class "error"
			haserror[self] = false
		end
		refresh_button()
	end
	function valuerow:on_changed()
		if #self.text == 0 or type(tonumber(self.text)) ~= "number" then
			self:add_css_class "error"
			haserror[self] = true
			self.subtitle = "must be a number"
		else
			self:remove_css_class "error"
			haserror[self] = false
			self.subtitle = ""
		end
		refresh_button()
	end
	function savebtn:on_clicked()
		t.name = namerow.text
		t.value = math.floor(tonumber(valuerow.text))
	end
	local popover = Gtk.Popover()
	local menubtn = Gtk.MenuButton {
		icon_name = "view-more-horizontal-symbolic",
		popover = popover,
	}
	menubtn:add_css_class "flat"
	t:update()
	return t
end

-- Window management

local function new_window()
	-- Force the window to be unique.
	if app.active_window then return app.active_window end
	local header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle("Tally", ""),
	}
	local
	local tbview = Adw.ToolbarView {

	}
	local window = Adw.ApplicationWindow {
		application = app,
		height_request = 300,
		width_request = 400,
	}
	return window
end

-- App management

function app:on_activate()
	if app.active_window then app.active_window:present() end
end

function app:on_startup()
	return new_window():present()
end

return app:run()
