--[[ tally.lua — Tally counter for GNOME ]]--

--[[
SECTION: Support library

Functions which will be used throughout the application.
]]--

local function fileexists(path)
	local ok, err, code = os.rename(path, path)
	if not ok and code == 13 then
		-- In Linux, error code 13 when moving a file means the it failed because the directory cannot be made its own child. Any other error means the file does not exist.
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

-- Simple class implementation without inheritance.
local function newclass(init)
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

--[[
SECTION: Imports and app initialization
]]--

-- Load packages from Flatpak only. If the Flatpak is broken, the application should not even attempt to load libraries from the system.
package.cpath = "/app/lib/lua/5.4/?.so"
package.path = "/app/share/lua/5.4/?.lua"

local lib = require "tallylib"

local lgi = require "lgi"
local Adw = lgi.require "Adw"
local Gtk = lgi.require "Gtk"
local Gdk = lgi.require "Gdk"
local GObject = lgi.require "GObject"
local GLib = lgi.require "GLib"

local app_id = lib.get_app_id()
local is_devel = lib.get_is_devel()
local app = Adw.Application {
	application_id = app_id,
}

--[[
SECTION: Tally counter class
]]--

local tallies = {} -- Global Lua table containing all tallies.
local tallyrows = {} -- Global Lua table associating Gtk.ListBoxRow items to their respective tally.

local tally = newclass(function(self, param)
	self.name = "unnamed"
	self.value = 0
	if type(param) == "table" then
		self.name = param.name or self.name
		self.value = param.value or self.value
	end

	self.namelabel = Gtk.Label {
		label = self.name,
		visible = false,
		halign = "START",
		hexpand = true,
	}
	self.countlabel = Gtk.Label {
		label = ("%d"):format(self.value),
		visible = false,
		halign = "END",
	}

	self.row = Adw.SpinRow.new_with_range(0, 1000000, 1)
	self.spinbtn = self.row.child:get_last_child():get_first_child()
	self.row.value = self.value
	function self.row.on_notify.value()
		self.value = self.row.value
		self.countlabel.label = ("%d"):format(self.value)
	end
	if param and param.color then
		self:setcolor(param.color)
	end

	self.checkbox = Gtk.CheckButton {
		visible = false,
	}
	function self.checkbox.on_notify.active()
		self.checked = self.checkbox.active
		if self.checked then
			self.row:add_css_class "checked"
		else
			self.row:remove_css_class "checked"
		end
	end

	self.entry = Gtk.Text {
		text = self.name,
		margin_top = 6,
		margin_bottom = 6,
	}
	function self.entry.on_changed()
		if #self.entry.text == 0 then
			self.row:add_css_class "error"
		else
			self.row:remove_css_class "error"
			self.name = self.entry.text
			self.namelabel.label = self.entry.text
		end
	end
	self.row:add_prefix(self.entry)
	function self.row:on_activate()
		self.entry:grab_focus()
	end

	self.draghdl = Gtk.Image.new_from_icon_name "list-drag-handle-symbolic"
	self.draghdl:add_css_class "drag-handle"

	local src = Gtk.DragSource {
		actions = "MOVE",
		propagation_phase = "CAPTURE",
	}
	function src.on_prepare(src, x, y)
		self.drag_x, self.drag_y = x, y
		local v = GObject.Value(Adw.SpinRow, self.row)
		return Gdk.ContentProvider.new_for_value(v)
	end
	function src.on_drag_begin(src, drag)
		local allocation = self.row:get_allocation()
		self.drag_widget = Gtk.ListBox()
		self.drag_widget:add_css_class "boxed-list"
		self.drag_widget:set_size_request(allocation.width, allocation.height)

		local dragrow = self:duplicate()
		self.drag_widget:append(dragrow)
		self.drag_widget:drag_highlight_row(dragrow)

		local drag_icon = Gtk.DragIcon.get_for_drag(drag)
		drag_icon.child = self.drag_widget
		drag:set_hotspot(math.floor(self.drag_x), math.floor(self.drag_y))
	end

	local tgt = Gtk.DropTarget {
		actions = "MOVE",
		formats = Gdk.ContentFormats.new_for_gtype(Adw.SpinRow),
		preload = true,
	}
	function tgt.on_drop(tgt, src, x, y)
		self.drag_widget = nil
		self.drag_x = nil
		self.drag_y = nil
		local widget = src.value
		local source_position = widget:get_index()
		local target_position = self.row:get_index()
		if source_position == target_position then return false end
		local lbox = self.row.parent
		lbox:remove(widget)
		lbox:insert(widget, target_position)
		table.remove(tallies, source_position + 1)
		local sourcetally = tallyrows[widget]
		table.insert(tallies, target_position + 1, sourcetally)
		return true
	end

	self.draghdl:add_controller(src)
	self.row:add_controller(tgt)

	self.row:add_prefix(self.namelabel)
	self.row:add_prefix(self.draghdl)
	self.row:add_prefix(self.checkbox)

	self.menubtn = Gtk.MenuButton {
		icon_name = "view-more-horizontal-symbolic",
		margin_top = 6,
		margin_bottom = 6,
		direction = "RIGHT",
		popover = self:menu(),
	}
	self.menubtn:add_css_class "flat"

	self.row:add_suffix(self.countlabel)
	self.row:add_suffix(self.menubtn)

	self:read()
end)

function tally:read()
	self.entry.text = self.name
	self.row.value = self.value
end

function tally:setcheckmode(enabled)
	self.checkmode = enabled
	if enabled then
		self.checkbox.visible = true
		self.checkbox.active = false
		self.namelabel.visible = true
		self.countlabel.visible = true
		self.entry.visible = false
		self.spinbtn.visible = false
		self.menubtn.visible = false
		self.draghdl.visible = false
		-- self.row.activatable_widget = self.checkbox
	else
		self.checkbox.visible = false
		self.checkbox.active = false
		self.namelabel.visible = false
		self.countlabel.visible = false
		self.entry.visible = true
		self.spinbtn.visible = true
		self.menubtn.visible = true
		self.draghdl.visible = true
		-- self.row.activatable_widget = self.entry
	end
end

function tally:getcolor()
	return self.color or "system"
end

function tally:setcolor(color)
	if self.color then
		self.row:remove_css_class(self.color)
	end
	self.color = color
	if color then
		self.row:add_css_class(color)
	end
end

function tally:gencolorcheck(color, group)
	local checkbtn = Gtk.CheckButton {
		group = group,
	}
	if color then checkbtn:add_css_class(color) end
	function checkbtn.on_notify.active()
		self:setcolor(color)
	end
	return checkbtn
end

function tally:colorrow()
	local box = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
	}
	box:add_css_class "colorselector"
	local system = self:gencolorcheck()
	box:append(system)
	for _, color in ipairs { "red", "orange", "yellow", "green", "blue", "purple" } do
		local check = self:gencolorcheck(color, system)
		if self.color == color then check.active = true end
		box:append(check)
	end
	if not self.color then system.active = true end
	return box
end

function tally:menu()
	-- FIXME: Generate the popover menu through a callback instead of on construction.
	local cbox = self:colorrow()

	local upbtn = Gtk.Button {
		icon_name = "go-up-symbolic",
	}
	local downbtn = Gtk.Button {
		icon_name = "go-down-symbolic",
	}
	local udbox = Gtk.Box { orientation = "HORIZONTAL" }
	udbox:add_css_class "linked"
	udbox:append(upbtn)
	udbox:append(downbtn)

	local topbtn = Gtk.Button {
		icon_name = "go-top-symbolic",
	}
	local bottombtn = Gtk.Button {
		icon_name = "go-bottom-symbolic",
	}
	local tbbox = Gtk.Box { orientation = "HORIZONTAL" }
	tbbox:add_css_class "linked"
	tbbox:append(topbtn)
	tbbox:append(bottombtn)

	local delbtn = Gtk.Button {
		icon_name = "edit-delete-symbolic",
	}
	delbtn:add_css_class "destructive-action"

	local mbox = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
	}
	mbox:append(udbox)
	mbox:append(tbbox)
	mbox:append(delbtn)

	local box = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 12,
		margin_start = 6,
		margin_end = 6,
		margin_top = 6,
		margin_bottom = 6,
	}
	box:append(cbox)
	box:append(mbox)

	local popover = Gtk.Popover {
		child = box,
	}

	function upbtn.on_clicked()
		local rindex = self.row:get_index()
		local tindex = rindex + 1
		local lbox = self.row.parent
		while rindex > 0 do
			rindex = rindex - 1
			local row = lbox:get_row_at_index(rindex)
			if row.mapped then
				table.remove(tallies, tindex)
				table.insert(tallies, rindex + 1, self)
				lbox:remove(self.row)
				lbox:insert(self.row, rindex)
				return
			end
		end
	end

	function downbtn.on_clicked()
		local rindex = self.row:get_index()
		local tindex = rindex + 1
		local lbox = self.row.parent
		rindex = rindex + 1
		while rindex < #tallies do
			local row = lbox:get_row_at_index(rindex)
			if row.mapped then
				table.remove(tallies, tindex)
				table.insert(tallies, rindex + 1, self)
				lbox:remove(self.row)
				lbox:insert(self.row, rindex)
				return
			end
			rindex = rindex + 1
		end
	end

	function topbtn.on_clicked()
		popover:popdown()
		table.remove(tallies, self.row:get_index() + 1)
		table.insert(tallies, 1, self)
		local lbox = self.row.parent
		lbox:remove(self.row)
		lbox:prepend(self.row)
	end

	function bottombtn.on_clicked()
		popover:popdown()
		table.remove(tallies, self.row:get_index() + 1)
		table.insert(tallies, self)
		local lbox = self.row.parent
		lbox:remove(self.row)
		lbox:append(self.row)
	end

	function delbtn.on_clicked()
		popover:popdown()
		self:delete()
	end

	return popover
end

function tally:duplicate()
	local r = Adw.SpinRow.new_with_range(0, 1000000, 1)
	if self.color then r:add_css_class(self.color) end
	r.title = self.name
	r.value = self.value
	r:add_suffix(Gtk.Button.new_from_icon_name "view-more-horizontal-symbolic")
	local img = Gtk.Image.new_from_icon_name "list-drag-handle-symbolic"
	img:add_css_class "drag-handle"
	r:add_prefix(img)
	return r
end

function tally:delete()
	local lbox = self.row.parent
	if not lbox then return end
	table.remove(tallies, self.row:get_index() + 1)
	lbox:remove(self.row)
	if not lbox:get_row_at_index(0) then lbox.visible = false end
end

function tally:serialize()
	local r = ""
	for k, v in pairs(self) do
		if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
			r = r .. ("\t[%q] = %q,\n"):format(k, v)
		end
	end
	return ("{\n%s},\n"):format(r)
end

--[[
SECTION: Saving/loading
]]--

local cfgdir = os.getenv "XDG_CONFIG_HOME"
local tallydir = cfgdir .. "/tally"
local tallyfile = tallydir .. "/tally"

local function writecfg()
	local cfg = ""
	for _, t in ipairs(tallies) do
		cfg = cfg .. t:serialize()
	end
	cfg = ("return {\n%s\n}"):format(cfg)
	io.open(tallyfile, "w"):write(cfg):close()
end

local function readcfg()
	local cfg = io.open(tallyfile):read "a"
	local f, err = load(cfg)
	-- Unable to read saved tallies, so just start the program with an empty list.
	if not f then return end
	local saved = f()
	assert(type(saved) == "table")
	for _, v in ipairs(saved) do
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

--[[
SECTION: Window construction
]]--

local aboutwin = Adw.AboutDialog {
	application_icon = app_id,
	application_name = "Tally",
	copyright = "Copyright © 2024 Victoria Lacroix",
	developer_name = "Victoria Lacroix",
	issue_url = "https://github.com/vtrlx/tally/issues/",
	license_type = "GPL_3_0",
	version = lib.get_app_ver(),
	website = "https://github.com/vtrlx/tally/",
}

local function newwin()
	-- Force the window to be unique.
	if app.active_window then return app.active_window end

	local newbtn = Gtk.Button.new_from_icon_name "list-add-symbolic"
	local delbtn = Gtk.Button {
		icon_name = "edit-delete-symbolic",
		visible = false,
	}
	delbtn:add_css_class "destructive-action"
	local searchbtn = Gtk.ToggleButton {
		icon_name = "system-search-symbolic",
	}
	local infobtn = Gtk.Button.new_from_icon_name "help-about-symbolic"
	local checkbtn = Gtk.ToggleButton {
		icon_name = "checkbox-checked-symbolic",
	}

	local header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle.new("Tally", ""),
	}
	header:pack_start(newbtn)
	header:pack_start(delbtn)
	header:pack_start(checkbtn)
	header:pack_end(infobtn)
	header:pack_end(searchbtn)

	local searchentry = Gtk.SearchEntry {
		placeholder_text = "Filter by name…",
	}

	local colorbox = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
	}
	colorbox:add_css_class "colorselector"
	local filtcolors = {}
	local colorchecks = {}

	local searchbox = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 6,
		margin_top = 6,
		margin_bottom = 6,
	}
	searchbox:append(searchentry)
	searchbox:append(colorbox)

	local searchbar = Gtk.SearchBar {
		child = searchbox,
	}
	searchbar:connect_entry(searchentry)
	searchbar:bind_property("search-mode-enabled", searchbtn, "active", "BIDIRECTIONAL")
	-- Despite mapping property names with underscores and providing a lovely syntax for defining signal event handlers, LGI doesn't do both at the same time.
	searchbar.on_notify["search-mode-enabled"] = function()
		for _, cb in ipairs(colorchecks) do cb.active = false end
	end

	local lbox = Gtk.ListBox {
		selection_mode = "NONE",
		valign = "START",
		visible = false,
	}
	lbox:add_css_class "boxed-list"
	lbox:set_filter_func(function(row)
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
		local checkbtn = Gtk.CheckButton()
		checkbtn:add_css_class(c)
		function checkbtn.on_notify.active()
			filtcolors[c] = checkbtn.active
			filtcolors.active = filtcolors.system or filtcolors.red or filtcolors.orange or
				filtcolors.yellow or filtcolors.green or filtcolors.blue or filtcolors.purple
			lbox:invalidate_filter()
		end
		table.insert(colorchecks, checkbtn)
		colorbox:append(checkbtn)
	end
--[[
	lbox:set_placeholder(Gtk.Label {
		label = "no matches",
		margin_top = 12,
		margin_bottom = 12,
	})
]]--
	function newbtn:on_clicked()
		local t = tally()
		table.insert(tallies, t)
		tallyrows[t.row] = t
		lbox:append(t.row)
		t.entry:grab_focus()
		if not lbox.visible then lbox.visible = true end
	end
	function checkbtn.on_notify.active()
		if checkbtn.active then
			newbtn.visible = false
			delbtn.visible = true
		else
			newbtn.visible = true
			delbtn.visible = false
		end
		for _, t in ipairs(tallies) do
			t:setcheckmode(checkbtn.active)
		end
	end
	function delbtn:on_clicked()
		if not checkbtn.active then return end
		local count = #tallies -- Cache the length because it's about to shrink.
		for i = 1, count do
			local idx = 1 + count - i
			local t = tallies[idx]
			if t.checked then t:delete() end
		end
		checkbtn.active = false
	end
	function searchentry:on_search_changed()
		lbox:invalidate_filter()
	end
	function lbox:on_row_activated(row)
		local t = tallyrows[row]
		if t.checkmode then
			t.checkbox.active = t.checkbox.active ~= true
		end
	end

	-- Place loaded tallies into the list.
	for _, t in ipairs(tallies) do
		lbox:append(t.row)
	end
	if #tallies > 0 then lbox.visible = true end

	local clamp = Adw.Clamp {
		child = lbox,
		maximum_size = 600,
		margin_start = 48,
		margin_end = 48,
		margin_top = 24,
		margin_bottom = 24,
	}

	local scroll = Gtk.ScrolledWindow {
		hscrollbar_policy = "NEVER",
		child = clamp,
	}
	local old_upper = 0
	local function scroll_to_bottom()
		scroll.vadjustment.value = scroll.vadjustment.upper
	end
	function scroll.vadjustment.on_notify.upper()
		local upper = scroll.vadjustment.upper
		if upper > old_upper then
			GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1, scroll_to_bottom)
		end
		old_upper = upper
	end

	local tbview = Adw.ToolbarView {
		content = scroll,
	}
	tbview:add_top_bar(header)
	tbview:add_top_bar(searchbar)

	local window = Adw.ApplicationWindow {
		application = app,
		title = "Tally",
		content = tbview,
		height_request = 600,
		width_request = 500,
	}

	function infobtn.on_clicked()
		aboutwin:present(window)
	end

	searchbar.key_capture_widget = window
	if is_devel then
		window:add_css_class "devel"
	end

	searchentry:grab_focus()
	window:present()
end

--[[
SECTION: Styles
]]--

-- FIXME: Add dark styles
local cssbase = [[
.colorselector checkbutton {
	padding: 0;
	min-height: 32px;
	min-width: 32px;
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
	-gtk-icon-source: -gtk-icontheme("object-select-symbolic");
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
]]

local csslight = [[
list.boxed-list row.red {
	background-color: color-mix(in srgb, var(--red-1) 10%, transparent);
	color: color-mix(in srgb, var(--red-5) 90%, black);
}
list.boxed-list row.red:hover {
	background-color: color-mix(in srgb, var(--red-2) 10%, transparent);
	color: color-mix(in srgb, var(--red-5) 90%, black);
}
list.boxed-list row.orange {
	background-color: color-mix(in srgb, var(--orange-1) 20%, transparent);
	color: color-mix(in srgb, var(--orange-5) 70%, black);
}
list.boxed-list row.orange:hover {
	background-color: color-mix(in srgb, var(--orange-2) 20%, transparent);
	color: color-mix(in srgb, var(--orange-5) 70%, black);
}
list.boxed-list row.yellow {
	background-color: color-mix(in srgb, var(--yellow-1) 30%, transparent);
	color: color-mix(in srgb, var(--yellow-5) 40%, black);
}
list.boxed-list row.yellow:hover {
	background-color: color-mix(in srgb, var(--yellow-2) 30%, transparent);
	color: color-mix(in srgb, var(--yellow-5) 40%, black);
}
list.boxed-list row.green {
	background-color: color-mix(in srgb, var(--green-1) 25%, transparent);
	color: color-mix(in srgb, var(--green-5) 55%, black);
}
list.boxed-list row.green:hover {
	background-color: color-mix(in srgb, var(--green-2) 25%, transparent);
	color: color-mix(in srgb, var(--green-5) 55%, black);
}
list.boxed-list row.blue {
	background-color: color-mix(in srgb, var(--blue-1) 20%, transparent);
	color: color-mix(in srgb, var(--blue-5) 70%, black);
}
list.boxed-list row.blue:hover {
	background-color: color-mix(in srgb, var(--blue-2) 20%, transparent);
	color: color-mix(in srgb, var(--blue-5) 70%, black);
}
list.boxed-list row.purple {
	background-color: color-mix(in srgb, var(--purple-1) 20%, transparent);
	color: var(--purple-5);
}
list.boxed-list row.purple:hover {
	background-color: color-mix(in srgb, var(--purple-2) 20%, transparent);
	color: var(--purple-5);
}
.colorselector checkbutton.system {
	background: none;
	background-color: white;
}
]]

local cssdark = [[
list.boxed-list row.red {
	background-color: color-mix(in srgb, var(--red-5) 90%, transparent);
	color: white;
}
list.boxed-list row.red:hover {
	background-color: color-mix(in srgb, var(--red-4) 90%, transparent);
	color: white;
}
list.boxed-list row.orange {
	background-color: color-mix(in srgb, var(--orange-5) 55%, transparent);
	color: white;
}
list.boxed-list row.orange:hover {
	background-color: color-mix(in srgb, var(--orange-4) 55%, transparent);
	color: white;
}
list.boxed-list row.yellow {
	background-color: color-mix(in srgb, var(--yellow-5) 25%, transparent);
	color: white;
}
list.boxed-list row.yellow:hover {
	background-color: color-mix(in srgb, var(--yellow-4) 25%, transparent);
	color: white;
}
list.boxed-list row.green {
	background-color: color-mix(in srgb, var(--green-5) 40%, transparent);
	color: white;
}
list.boxed-list row.green:hover {
	background-color: color-mix(in srgb, var(--green-4) 40%, transparent);
	color: white;
}
list.boxed-list row.blue {
	background-color: color-mix(in srgb, var(--blue-5) 70%, transparent);
	color: white;
}
list.boxed-list row.blue:hover {
	background-color: color-mix(in srgb, var(--blue-4) 70%, transparent);
	color: white;
}
list.boxed-list row.purple {
	background-color: var(--purple-5);
	color: white;
}
list.boxed-list row.purple:hover {
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

--[[
SECTION: App callbacks
]]--

function app:on_activate()
	if app.active_window then app.active_window:present() end
end

function app:on_startup()
	newwin()
end

function app:on_shutdown()
	writecfg()
end

return app:run()
