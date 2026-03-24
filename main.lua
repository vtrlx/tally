--[[ main.lua (Tally counter GNOME app)
Copyright © 2024–2026 Victoria Lacroix
This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
You should have received a copy of the GNU General Public License along with this program.  If not, see <https://www.gnu.org/licenses/>. ]]--

-- SECTION: Support library

local lib = require "mainlib"

local function fileexists(path)
	local ok, err, code = os.rename(path, path)
	if not ok and code == 13 then
		-- In Linux, error code 13 when moving a file means that it failed because the directory cannot be made its own child. Any other error means the file does not exist.
		return true
	end
	return ok
end

local function isdir(path)
	if path == "/" then return true end
	-- If the given path points to a directory, then adding a "/" suffix will show the file as still existing.
	return fileexists(path .. "/")
end

local function mkdir(path)
	assert(type(path) == "string")
	local cmd = ("mkdir %q"):format(path)
	os.execute(cmd)
end

-- Make gettext available through the name expected by xgettext.
local _ = lib.gettext

function lib.getcolorname(color)
	if not color or color == "system" then
		return _ "No color"
	elseif color == "red" then
		return _ "Red"
	elseif color == "orange" then
		return _ "Orange"
	elseif color == "yellow" then
		return _ "Yellow"
	elseif color == "green" then
		return _ "Green"
	elseif color == "blue" then
		return _ "Blue"
	elseif color == "purple" then
		return _ "Purple"
	end
end

-- Simple class implementation without inheritance.
function lib.newclass(init)
	local c = {}
	local mt = {}
	c.__index = c

	function mt:__call(...)
		local obj = setmetatable({}, c)
		init(obj, ...)
		return obj
	end

	function c:isa(klass)
		return getmetatable(self) == klass
	end

	return setmetatable(c, mt)
end

-- SECTION: Imports and app initialization

do -- Update package paths so they only use Flatpak
	local vernum = _VERSION:gsub("Lua ", "")
	package.cpath = ("/app/lib/lua/%s/?.so"):format(vernum)
	package.path = ("/app/share/lua/%s/?.lua;/app/share/lua/%s/?/init.lua"):format(vernum, vernum)
end

local LuaGObject = require "LuaGObject"
local Adw = LuaGObject.require "Adw"
local Gtk = LuaGObject.require "Gtk"
local Gdk = LuaGObject.require "Gdk"
local GObject = LuaGObject.require "GObject"
local GLib = LuaGObject.require "GLib"
local Gio = LuaGObject.require "Gio"

local app_id = lib.get_app_id()
local is_devel = lib.get_is_devel()
lib.app = Adw.Application {
	application_id = app_id,
	resource_base_path = "/ca/vlacroix/Tally", -- Needs to be hardcoded.
}
local app = lib.app
app:set_accels_for_action("win.shortcuts", { "<Ctrl><Shift>question" })
app:set_accels_for_action("win.about", { "F1" })
app:set_accels_for_action("win.close", { "<Ctrl>W" })
app:set_accels_for_action("app.quit", { "<Ctrl>Q" })

local quit_action = Gio.SimpleAction.new "quit"
function quit_action:on_activate()
	app:quit()
end
quit_action.enabled = true
app:add_action(quit_action)

-- SECTION: GResources

do -- Load and register GResource.
	local resource, err = Gio.Resource.load "/app/data/tally.gresource"
	if resource then
		Gio.resources_register(resource)
	else
		print("Failed to load resource", err)
	end
end -- Load and register GResource.

-- SECTION: Tally counter class

local tally, tallies, tallyrows = table.unpack(lib.load_counter())

-- SECTION: Saving/loading

local cfgdir = os.getenv "XDG_CONFIG_HOME"
local tallydir = cfgdir .. "/tally"
local tallyfile = tallydir .. "/tally"
local tallynext = tallydir .. "/tallynext"

local app_window
local saved_data = {}
local queued_write_count = 0

local cfg_pattern = [[
return {
	%s
}
]]

local function writecfg()
	queued_write_count = 0
	local width = app_window.window.default_width
	local height = app_window.window.default_height
	local maximized = app_window.window:is_maximized()
	local cfg = ""
	cfg = cfg .. ("width = %d,\n"):format(width)
	cfg = cfg .. ("height = %d,\n"):format(height)
	cfg = cfg .. ("maximized = %q,\n"):format(maximized)
	for _, t in ipairs(tallies) do
		cfg = cfg .. t:serialize()
	end
	cfg = cfg_pattern:format(cfg)
	-- Write to a backup file first…
	io.open(tallynext, "w"):write(cfg):close()
	-- …then, move the backup to the destination. This is a clean operation which should prevent unfinished disk writes from clobbering data. In practice, this doesn't matter.
	os.rename(tallynext, tallyfile)
end

-- Writes the config file 10 seconds from when this function is called. If another write is queued or if a write is successful, this also aborts.
function lib.queuewrite()
	queued_write_count = queued_write_count + 1
	-- Try to write in 1 second, if another write hasn't already been queued.
	GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, function()
		-- Already wrote, no need to write again.
		if queued_write_count == 0 then return end
		queued_write_count = queued_write_count - 1
		if queued_write_count == 0 then
			writecfg()
		end
	end)
end

local function readcfg()
	local cfg, f, err
	-- If temporary config still exists, try reading from it first.
	if fileexists(tallynext) then
		cfg = io.open(tallynext):read "a"
		f, err = load(cfg)
		-- If there's a syntax error, then the config is broken, so the old config should be loaded instead.
		if not f then cfg = nil end
	end
	if not cfg then
		cfg = io.open(tallyfile):read "a"
		f, err = load(cfg)
		-- If the config file doesn't exist, return.
		if not f then return end
	end
	saved_data = f()
	assert(type(saved_data) == "table")
	for _, v in ipairs(saved_data) do
		local t = tally(v)
		table.insert(tallies, t)
		tallyrows[t.row] = t
	end
end

do -- Initialize configuration if it doesn't exist, load if it does.
	if fileexists(tallydir) and not isdir(tallydir) then
		-- Tally configuration is broken due to external influence. Because this app runs in a Flatpak sandbox, any files inside of it should be expected to be under control of the app, so deleting it shouldn't violate any expectations.
		os.remove(tallydir)
	end
	if not fileexists(tallydir) then mkdir(tallydir) end
	if not fileexists(tallyfile) then
		io.open(tallyfile, "w"):write("return {}\n"):close()
	end
	readcfg()
end

-- SECTION: Window construction

local aboutwin = Adw.AboutDialog {
	application_icon = app_id,
	application_name = _ "Tally",
	copyright = "Copyright © 2024–2025 Victoria Lacroix",
	developer_name = "Victoria Lacroix",
	issue_url = "https://github.com/vtrlx/tally/issues/",
	license_type = "GPL_3_0",
	release_notes_version = lib.get_app_ver(),
	translator_credits = _ "translator-credits",
	version = lib.get_app_ver(),
	website = "https://www.vlacroix.ca/apps/tally/",
}
aboutwin:add_link(_ "Translate this app!", "https://github.com/vtrlx/tally?tab=readme-ov-file#localization")
aboutwin:add_link(_ "Support this app!", "https://liberapay.com/vtrlx/")
aboutwin.release_notes = [[
<p>In-app icons are now supplied by Tally, fixing a bug where icons would not be shown if not provided by the user's operating system.</p>
]]

local function newshortcutwindow(parent)
	local maingroup = Gtk.ShortcutsGroup { title = _ "Main Window" }
	maingroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "app.quit",
		title = _ "Quit Application",
		accelerator = "<Ctrl>Q",
	})
	maingroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.shortcuts",
		title = _ "Keyboard Shortcuts",
		accelerator = "<Ctrl><Shift>question",
	})
	maingroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "app.about",
		title = _ "About Tally",
		accelerator = "F1",
	})

	local countergroup = Gtk.ShortcutsGroup { title = _ "Counter Window" }
	countergroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "app.quit",
		title = _ "Quit Application",
		accelerator = "<Ctrl>Q",
	})
	countergroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.close",
		title = _ "Close Window",
		accelerator = "<Ctrl>W",
	})

	local shortsection = Gtk.ShortcutsSection { title = app_title }
	shortsection:add_group(maingroup)
	shortsection:add_group(countergroup)

	local shortcutwin = Gtk.ShortcutsWindow()
	shortcutwin:add_section(shortsection)
	shortcutwin.transient_for = parent
	shortcutwin.modal = true
	shortcutwin.application = app

	return shortcutwin
end

local tallymenu = Gio.Menu()
tallymenu:append(_ "Keyboard Shortcuts", "win.shortcuts")
tallymenu:append(_ "About Tally", "win.about")

local window = lib.newclass(function(self)
	-- Force the window to be unique.
	if app.active_window then return app.active_window end

	local newbtn = Gtk.Button {
		icon_name = "plus-large-symbolic",
		tooltip_text = _ "Create a new counter",
		on_clicked = function() self:tallydialog() end,
	}
	local delbtn = Gtk.Button {
		icon_name = "delete-symbolic",
		tooltip_text = _ "Delete selected counters",
		visible = false,
		extra_css_classes = { "destructive-action" },
	}
	local searchbtn = Gtk.ToggleButton {
		icon_name = "loupe-large-symbolic",
		tooltip_text = _ "Filter counters by name and/or color",
	}
	local menubtn = Gtk.MenuButton {
		icon_name = "menu-large-symbolic",
		menu_model = tallymenu,
		tooltip_text = _ "Menu",
	}
	self.checkbtn = Gtk.ToggleButton {
		icon_name = "check-round-outline-symbolic",
		tooltip_text = _ "Select counters to delete",
	}

	local header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle.new(_ "Tally", ""),
	}
	header:pack_start(newbtn)
	header:pack_start(delbtn)
	header:pack_start(self.checkbtn)
	header:pack_end(menubtn)
	header:pack_end(searchbtn)

	local searchentry = Gtk.SearchEntry {
		placeholder_text = _ "Filter by name…",
	}

	local searchcolorbox = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
		extra_css_classes = { "colorselector" },
	}

	local filtcolors = {}
	local searchcolorchecks = {}

	local searchbox = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 6,
		margin_top = 6,
		margin_bottom = 6,
		searchentry,
		searchcolorbox,
	}

	local searchbar = Gtk.SearchBar {
		child = searchbox,
	}
	searchbar:connect_entry(searchentry)
	searchbar:bind_property("search-mode-enabled", searchbtn, "active", "BIDIRECTIONAL")
	-- Despite mapping property names with underscores and providing a lovely syntax for defining signal event handlers, LuaGObject doesn't do both at the same time, so listening to notify requires this syntax.
	searchbar.on_notify["search-mode-enabled"] = function()
		for _, cb in ipairs(searchcolorchecks) do cb.active = false end
	end

	self.lbox = Gtk.ListBox {
		selection_mode = "NONE",
		valign = "START",
		visible = false,
		extra_css_classes = { "tally-list", "boxed-list" },
	}
	self.lbox:set_filter_func(function(row)
		if not searchbar.search_mode_enabled then return true end
		if #searchentry.text == 0 and not filtcolors.active then return true end
		local t = tallyrows[row]
		local title = t.name:lower()
		local entry = searchentry.text:lower()
		local showcolor = true
		if filtcolors.active then
			showcolor = filtcolors[t:getcolor()]
		end
		return showcolor and (title:find(entry, 1, true))
	end)
	for _, c in ipairs { "system", "red", "orange", "yellow", "green", "blue", "purple" } do
		local checkbtn = Gtk.CheckButton {
			tooltip_text = lib.getcolorname(c),
		}
		checkbtn:add_css_class(c)
		function checkbtn.on_notify.active()
			filtcolors[c] = checkbtn.active
			filtcolors.active = filtcolors.system or filtcolors.red or filtcolors.orange or
				filtcolors.yellow or filtcolors.green or filtcolors.blue or filtcolors.purple
			self.lbox:invalidate_filter()
		end
		table.insert(searchcolorchecks, checkbtn)
		searchcolorbox:append(checkbtn)
	end

	function self.checkbtn.on_notify.active()
		if self.checkbtn.active then
			self.checkbtn.tooltip_text = _ "Stop selecting without deleting anything"
			newbtn.visible = false
			delbtn.visible = true
		else
			self.checkbtn.tooltip_text = _ "Select counters to delete"
			newbtn.visible = true
			delbtn.visible = false
		end
		for _, t in ipairs(tallies) do
			t:setcheckmode(self.checkbtn.active)
		end
	end
	function delbtn.on_clicked()
		if not self.checkbtn.active then return end
		local count = #tallies -- Cache the length because it's about to shrink.
		for i = 1, count do
			local idx = 1 + count - i
			local t = tallies[idx]
			if t.checked then t:delete() end
		end
		writecfg()
		self.checkbtn.active = false
		self:refreshtoolbar()
	end
	function searchentry:on_search_changed()
		self.lbox:invalidate_filter()
	end
	function self.lbox:on_row_activated(row)
		local t = tallyrows[row]
		if t.checkmode then
			t.checkbox.active = t.checkbox.active ~= true
		end
	end

	-- Place loaded tallies into the list.
	for _, t in ipairs(tallies) do
		self.lbox:append(t.row)
	end
	if #tallies > 0 then self.lbox.visible = true end

	local clamp = Adw.Clamp {
		child = Adw.LayoutSlot.new "list",
		maximum_size = 600,
		margin_start = 24,
		margin_end = 24,
		margin_top = 12,
		margin_bottom = 12,
	}

	local biglayout = Adw.Layout.new(clamp)
	local smalllayout = Adw.Layout.new(Adw.LayoutSlot.new "list")

	local multi = Adw.MultiLayoutView()
	multi:set_child("list", self.lbox)
	multi:add_layout(biglayout)
	multi:add_layout(smalllayout)

	self.scrolledwin = Gtk.ScrolledWindow {
		hscrollbar_policy = "NEVER",
		child = multi,
	}

	for _, t in ipairs(tallies) do
		t.viewport = self.scrolledwin:get_child()
	end

	self.statuspage = Adw.StatusPage {
		title = _ "No Counters",
		icon_name = "tally-symbolic",
		child = Gtk.Button {
			extra_css_classes = { "suggested-action", "pill" },
			label = _ "Create Counter",
			margin_start = 40,
			margin_end = 40,
			on_clicked = function()
				self:tallydialog()
			end,
		},
	}

	self.toolbarview = Adw.ToolbarView {
		content = self.scrolledwin,
	}
	self.toolbarview:add_top_bar(header)
	self.toolbarview:add_top_bar(searchbar)

	local function enlarge()
		multi.layout = biglayout
		self.lbox:remove_css_class "separators"
		self.lbox:add_css_class "boxed-list"
		self.toolbarview.top_bar_style = "FLAT"
	end

	local function shrink()
		multi.layout = smalllayout
		self.lbox:remove_css_class "boxed-list"
		self.lbox:add_css_class "separators"
		self.toolbarview.top_bar_style = "RAISED_BORDER"
	end

	self.window = Adw.ApplicationWindow {
		application = app,
		title = _ "Tally",
		content = self.toolbarview,
		default_height = 600,
		default_width = 500,
		height_request = 294,
		width_request = 360,
	}
	if saved_data.maximized then
		self.window:maximize()
	end
	if saved_data.width and saved_data.height then
		self.window.default_width = saved_data.width
		self.window.default_height = saved_data.height
	end

	local bpcond = Adw.BreakpointCondition.new_length("MAX_WIDTH", 400, "PX")
	local breakpoint = Adw.Breakpoint.new(bpcond)
	breakpoint.on_apply = shrink
	breakpoint.on_unapply = enlarge
	self.window:add_breakpoint(breakpoint)

	searchbar.key_capture_widget = window
	if is_devel then
		self.window:add_css_class "devel"
	end

	function self.window:on_close_request()
		for _, t in ipairs(tallies) do
			if t.zoomwin then
				t.zoomwin:close()
			end
		end
	end

	local shortcuts_action = Gio.SimpleAction.new "shortcuts"
	function shortcuts_action.on_activate()
		newshortcutwindow(self.window):present()
	end
	shortcuts_action.enabled = true
	self.window:add_action(shortcuts_action)

	local about_action = Gio.SimpleAction.new "about"
	function about_action.on_activate()
		aboutwin:present(self.window)
	end
	about_action.enabled = true
	self.window:add_action(about_action)

	self:refreshtoolbar()
	menubtn:grab_focus()
end)

function window:scrollbottom()
	GLib.timeout_add(GLib.PRIORITY_DEFAULT, 20, function()
		self.scrolledwin.vadjustment.value =
			self.scrolledwin.vadjustment.upper
	end)
end

function window:tallydialog()
	local newtallycolor
	local createbtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "plus-large-symbolic",
			label = _ "Add to List",
		},
		tooltip_text = _ "Add this counter to the list",
		halign = "CENTER",
		sensitive = false,
		extra_css_classes = { "suggested-action" },
	}

	local nameentry = Gtk.Entry {
		placeholder_text = _ "Name",
		halign = "FILL",
	}
	function nameentry:on_changed()
		if #self.text == 0 then
			self:add_css_class "error"
			createbtn.sensitive = false
		else
			self:remove_css_class "error"
			createbtn.sensitive = true
		end
	end
	local tallycolorbox = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
		extra_css_classes = { "colorselector" },
	}
	local newsystemcheckbtn = Gtk.CheckButton {
		tooltip_text = lib.getcolorname(), -- Defaults to "No color"
	}
	tallycolorbox:append(newsystemcheckbtn)
	function newsystemcheckbtn.on_notify.active()
		newtallycolor = nil
	end
	for _, c in ipairs { "red", "orange", "yellow", "green", "blue", "purple" } do
		local checkbtn = Gtk.CheckButton {
			group = newsystemcheckbtn,
			tooltip_text = lib.getcolorname(c),
		}
		checkbtn:add_css_class(c)
		function checkbtn.on_notify.active()
			if checkbtn.active then
				newtallycolor = c
			end
		end
		tallycolorbox:append(checkbtn)
	end

	local pbox = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 12,
		margin_top = 12,
		margin_bottom = 12,
		margin_start = 12,
		margin_end = 12,
		nameentry,
		tallycolorbox,
		createbtn,
	}

	local toolbarview = Adw.ToolbarView {
		content = pbox,
		top_bars = { Adw.HeaderBar() },
	}
	local dialog = Adw.Dialog {
		child = toolbarview,
		title = _ "New Counter",
	}
	local function do_create()
		if #nameentry.text == 0 then return end
		local t = tally {
			name = nameentry.text,
			color = newtallycolor,
		}
		t.viewport = self.scrolledwin:get_child()
		table.insert(tallies, t)
		tallyrows[t.row] = t
		writecfg()
		self.lbox:append(t.row)
		if not self.lbox.visible then self.lbox.visible = true end
		self:scrollbottom()
		t.row:grab_focus()
		self:refreshtoolbar()
		dialog:close()
	end
	createbtn.on_clicked = do_create

	dialog:present(self.window)
end

function window:refreshtoolbar()
	if #tallies == 0 then
		self.checkbtn.visible = false
		self.toolbarview.top_bar_style = "FLAT"
		self.toolbarview.content = self.statuspage
	else
		self.checkbtn.visible = true
		self.toolbarview.top_bar_style = "RAISED_BORDER"
		self.toolbarview.content = self.scrolledwin
	end
end

-- SECTION: Styles

local cssbase = [[
.colorselector checkbutton {
	padding: 0;
	min-height: 28px;
	min-width: 28px;
	padding: 1px;
	background-clip: content-box;
	border-radius: 9999px;
	box-shadow: inset 0 0 0 1px @borders;
	background: linear-gradient(-45deg, black 49.99%, white 50.01%);
}
.colorselector checkbutton:checked {
	box-shadow: inset 0 0 0 2px @accent_bg_color;
}
.colorselector checkbutton radio, .colorselector checkbutton check {
	-gtk-icon-source: none;
	border: none;
	box-shadow: none;
	min-width: 8px;
	min-height: 8px;
	transform: translate(19px, 10px);
	padding: 2px;
}
.colorselector checkbutton radio:checked, .colorselector checkbutton check:checked {
	-gtk-icon-source: -gtk-icontheme("check-mark-symbolic");
	background-color: @accent_bg_color;
	color: @accent_fg_color;
}
.colorselector checkbutton.red {
	background: none;
	background-color: var(--red-3);
}
.colorselector checkbutton.orange {
	background: none;
	background-color: var(--orange-3);
}
.colorselector checkbutton.yellow {
	background: none;
	background-color: var(--yellow-3);
}
.colorselector checkbutton.green {
	background: none;
	background-color: var(--green-3);
}
.colorselector checkbutton.blue {
	background: none;
	background-color: var(--blue-3);
}
.colorselector checkbutton.purple {
	background: none;
	background-color: var(--purple-3);
}
.popout {
	font-size: 300%;
}
.popout .circular {
	min-height: 68px;
	min-width: 68px;
	-gtk-icon-size: 32px;
}
]]

local csslight = [[
list.tally-list row.red, toolbarview.red {
	background-color: color-mix(in srgb, var(--red-1) 10%, transparent);
	color: color-mix(in srgb, var(--red-5) 90%, black);
}
list.tally-list row.red:hover {
	background-color: color-mix(in srgb, var(--red-2) 10%, transparent);
	color: color-mix(in srgb, var(--red-5) 90%, black);
}
list.tally-list row.orange, toolbarview.orange {
	background-color: color-mix(in srgb, var(--orange-1) 20%, transparent);
	color: color-mix(in srgb, var(--orange-5) 70%, black);
}
list.tally-list row.orange:hover {
	background-color: color-mix(in srgb, var(--orange-2) 20%, transparent);
	color: color-mix(in srgb, var(--orange-5) 70%, black);
}
list.tally-list row.yellow, toolbarview.yellow {
	background-color: color-mix(in srgb, var(--yellow-1) 30%, transparent);
	color: color-mix(in srgb, var(--yellow-5) 40%, black);
}
list.tally-list row.yellow:hover {
	background-color: color-mix(in srgb, var(--yellow-2) 30%, transparent);
	color: color-mix(in srgb, var(--yellow-5) 40%, black);
}
list.tally-list row.green, toolbarview.green {
	background-color: color-mix(in srgb, var(--green-1) 25%, transparent);
	color: color-mix(in srgb, var(--green-5) 55%, black);
}
list.tally-list row.green:hover {
	background-color: color-mix(in srgb, var(--green-2) 25%, transparent);
	color: color-mix(in srgb, var(--green-5) 55%, black);
}
list.tally-list row.blue, toolbarview.blue {
	background-color: color-mix(in srgb, var(--blue-1) 20%, transparent);
	color: color-mix(in srgb, var(--blue-5) 70%, black);
}
list.tally-list row.blue:hover {
	background-color: color-mix(in srgb, var(--blue-2) 20%, transparent);
	color: color-mix(in srgb, var(--blue-5) 70%, black);
}
list.tally-list row.purple, toolbarview.purple {
	background-color: color-mix(in srgb, var(--purple-1) 20%, transparent);
	color: var(--purple-5);
}
list.tally-list row.purple:hover {
	background-color: color-mix(in srgb, var(--purple-2) 20%, transparent);
	color: var(--purple-5);
}
.colorselector checkbutton.system {
	background: none;
	background-color: white;
}
]]

local cssdark = [[
list.tally-list row.red, toolbarview.red {
	background-color: color-mix(in srgb, var(--red-5) 90%, transparent);
	color: white;
}
list.tally-list row.red:hover {
	background-color: color-mix(in srgb, var(--red-4) 90%, transparent);
	color: white;
}
list.tally-list row.orange, toolbarview.orange {
	background-color: color-mix(in srgb, var(--orange-5) 55%, transparent);
	color: white;
}
list.tally-list row.orange:hover {
	background-color: color-mix(in srgb, var(--orange-4) 55%, transparent);
	color: white;
}
list.tally-list row.yellow, toolbarview.yellow {
	background-color: color-mix(in srgb, var(--yellow-5) 25%, transparent);
	color: white;
}
list.tally-list row.yellow:hover {
	background-color: color-mix(in srgb, var(--yellow-4) 25%, transparent);
	color: white;
}
list.tally-list row.green, toolbarview.green {
	background-color: color-mix(in srgb, var(--green-5) 40%, transparent);
	color: white;
}
list.tally-list row.green:hover {
	background-color: color-mix(in srgb, var(--green-4) 40%, transparent);
	color: white;
}
list.tally-list row.blue, toolbarview.blue {
	background-color: color-mix(in srgb, var(--blue-5) 70%, transparent);
	color: white;
}
list.tally-list row.blue:hover {
	background-color: color-mix(in srgb, var(--blue-4) 70%, transparent);
	color: white;
}
list.tally-list row.purple, toolbarview.purple {
	background-color: var(--purple-5);
	color: white;
}
list.tally-list row.purple:hover {
	background-color: var(--purple-4);
	color: white;
}
.colorselector checkbox.system {
	background: none;
	background-color: black;
}
]]

do
	local styleman = Adw.StyleManager.get_default()
	local display = Gdk.Display.get_default()
	local providerlight = Gtk.CssProvider()
	providerlight:load_from_string(cssbase .. csslight)
	local providerdark = Gtk.CssProvider()
	providerdark:load_from_string(cssbase .. cssdark)
	if styleman.dark then
		Gtk.StyleContext.add_provider_for_display(display, providerdark, 1000000)
	else
		Gtk.StyleContext.add_provider_for_display(display, providerlight, 1000000)
	end
	local function refresh()
		if styleman.dark then
			Gtk.StyleContext.remove_provider_for_display(display, providerlight)
			Gtk.StyleContext.add_provider_for_display(display, providerdark, 1000000)
		else
			Gtk.StyleContext.remove_provider_for_display(display, providerdark)
			Gtk.StyleContext.add_provider_for_display(display, providerlight, 1000000)
		end
	end
	function styleman.on_notify.dark()
		refresh()
	end
end

-- SECTION: App callbacks

function app:on_activate()
	if app.active_window then app.active_window:present() end
end

function app:on_startup()
	app_window = window()
	app_window.window:present()
end

function app:on_shutdown()
	writecfg()
end

return app:run()
