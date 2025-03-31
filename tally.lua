--[[ tally.lua (Tally counter)
Copyright © 2024–2025 Victoria Lacroix
This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
You should have received a copy of the GNU General Public License along with this program.  If not, see <https://www.gnu.org/licenses/>. ]]--

--[[
SECTION: Support library
Functions which will be used throughout the application.
]]--

local lib = require "tallylib"

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

local function _(...)
	return lib.gettext(...)
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

	self.countlabel = Gtk.Label {
		label = ("%d"):format(self.value),
		visible = false,
		hexpand = false,
		margin_start = 18,
		halign = "END",
	}

	self.spinbtn = Gtk.SpinButton.new_with_range(0, 1000000, 1)
	self.spinbtn:get_first_child().xalign = 1
	self.spinbtn.valign = "CENTER"
	self.row = Adw.ExpanderRow()
	self.row:add_css_class "spin"
	self.row.title = self.name
	self.spinbtn.value = self.value
	function self.spinbtn.on_notify.value()
		self.value = self.spinbtn.value
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

	self.draghdl = Gtk.Image.new_from_icon_name "list-drag-handle-symbolic"
	self.draghdl:add_css_class "drag-handle"

	local src = Gtk.DragSource {
		actions = "MOVE",
		propagation_phase = "CAPTURE",
	}
	function src.on_prepare(src, x, y)
		self.drag_x, self.drag_y = x, y
		local v = GObject.Value(Adw.ExpanderRow, self.row)
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
		formats = Gdk.ContentFormats.new_for_gtype(Adw.ExpanderRow),
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

	self.row:add_prefix(self.draghdl)
	self.row:add_prefix(self.checkbox)

	self.row:add_suffix(self.countlabel)
	self.row:add_suffix(self.spinbtn)

	self:createmenu()

	-- Force the contents of the suffix box to align right when the spinbutton is made invisible.
	local suffixbox = self.row.child:get_last_child()
	suffixbox.hexpand = true
--	suffixbox.halign = "END"

	self:read()
end)

function tally:read()
	self.spinbtn.value = self.value
end

function tally:setcheckmode(enabled)
	self.checkmode = enabled
	if enabled then
		self.checkbox.visible = true
		self.checkbox.active = false
		self.countlabel.visible = true
		self.spinbtn.visible = false
		self.draghdl.visible = false
		self.row.expanded = false
		self.row.enable_expansion = false
	else
		self.checkbox.visible = false
		self.checkbox.active = false
		self.countlabel.visible = false
		self.spinbtn.visible = true
		self.draghdl.visible = true
		self.row.enable_expansion = true
		self.row.expanded = false
	end
end

function tally:scroll()
	if not self.viewport then return end
	self.viewport:scroll_to(self.row)
end

function tally:getcolor()
	return self.color or "system"
end

function tally:setcolor(color)
	if self.color then
		self.row:remove_css_class(self.color)
		if self.zoomwin then self.zoomwin.content:remove_css_class(self.color) end
	end
	self.color = color
	if color then
		self.row:add_css_class(color)
		if self.zoomwin then self.zoomwin.content:add_css_class(color) end
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
		valign = "CENTER",
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

function tally:createmenu()
	self.entry = Adw.EntryRow {
		text = self.name,
		title = _ "Name",
	}
	function self.entry.on_changed()
		if #self.entry.text == 0 then
			self.row:add_css_class "error"
			return
		end
		self.row:remove_css_class "error"
		self.name = self.entry.text
		self.row.title = self.entry.text
	end
	self.row:add_row(self.entry)

	local cbox = self:colorrow()
	local crow = Adw.ActionRow {
		title = "Colour",
	}
	crow:add_suffix(cbox)
	self.row:add_row(crow)

	local topbtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "go-top-symbolic",
			label = _ "Move to top",
			halign = "START",
		},
		tooltip_text = _ "Move counter to the top of the current list",
	}
	local bottombtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "go-bottom-symbolic",
			label = _ "Move to bottom",
			halign = "START",
		},
		tooltip_text = _ "Move counter to the bottom of the current list",
	}
	local tbbox = Gtk.Box {
		orientation = "VERTICAL",
		margin_top = 6,
		margin_bottom = 6,
	}
	tbbox:add_css_class "linked"
	tbbox:append(topbtn)
	tbbox:append(bottombtn)

	local upbtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "go-up-symbolic",
			label = _ "Move up",
			halign = "START",
		},
		tooltip_text = _ "Move counter to just above the previous row",
		valign = "CENTER",
	}
	local downbtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "go-down-symbolic",
			label = _ "Move down",
			halign = "START",
		},
		tooltip_text = _ "Move counter to just below the next row",
	}
	local udbox = Gtk.Box {
		orientation = "VERTICAL",
		margin_top = 6,
		margin_bottom = 6,
	}
	udbox:add_css_class "linked"
	udbox:append(upbtn)
	udbox:append(downbtn)

	local mbox = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 12,
		hexpand = true,
		homogeneous = true,
		halign = "CENTER",
		valign = "CENTER",
	}
	mbox:add_css_class "header"
	mbox:append(tbbox)
	mbox:append(udbox)
	self.row:add_row(mbox)

	local popoutbtn = Gtk.Button {
		icon_name = "window-new-symbolic",
		tooltip_text = _ "Create a new window for this counter",
		halign = "END",
		hexpand = true,
		valign = "CENTER",
	}
	local popoutrow = Adw.ActionRow {
		title = _ "Show in a separate window",
	}
	popoutrow:add_suffix(popoutbtn)
	self.row:add_row(popoutrow)

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
				GLib.timeout_add(GLib.PRIORITY_DEFAULT, 20, function() self:scroll() end)
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
				GLib.timeout_add(GLib.PRIORITY_DEFAULT, 20, function() self:scroll() end)
				return
			end
			rindex = rindex + 1
		end
	end

	function topbtn.on_clicked()
		table.remove(tallies, self.row:get_index() + 1)
		table.insert(tallies, 1, self)
		local lbox = self.row.parent
		lbox:remove(self.row)
		lbox:prepend(self.row)
		GLib.timeout_add(GLib.PRIORITY_DEFAULT, 20, function() self:scroll() end)
	end

	function bottombtn.on_clicked()
		table.remove(tallies, self.row:get_index() + 1)
		table.insert(tallies, self)
		local lbox = self.row.parent
		lbox:remove(self.row)
		lbox:append(self.row)
		GLib.timeout_add(GLib.PRIORITY_DEFAULT, 20, function() self:scroll() end)
	end

	function popoutbtn.on_clicked()
		self:popout():present()
	end
end

function tally:popout()
	if self.zoomwin then
		return self.zoomwin
	end
	local title = Adw.WindowTitle.new(self.name, _ "Tally")
	local headerbar = Adw.HeaderBar {
		title_widget = title,
	}
	self.entry:bind_property("text", title, "title", "BIDIRECTIONAL")
	local countlabel = Gtk.Label {
		label = ("%d"):format(self.spinbtn.value),
		width_request = 240,
		halign = "CENTER",
	}
	countlabel:add_css_class "numeric"
	local decbtn = Gtk.Button {
		icon_name = "value-decrease-symbolic",
		sensitive = self.spinbtn.value > 0,
	}
	decbtn:add_css_class "circular"
	function decbtn.on_clicked()
		self.spinbtn.value = self.spinbtn.value - 1
	end
	local incbtn = Gtk.Button {
		icon_name = "value-increase-symbolic",
		sensitive = self.spinbtn.value < 1000000,
	}
	incbtn:add_css_class "circular"
	function incbtn.on_clicked()
		self.spinbtn.value = self.spinbtn.value + 1
	end
	function self.spinbtn.on_notify.value()
		countlabel.label = ("%d"):format(self.spinbtn.value)
		decbtn.sensitive = self.spinbtn.value > 0
		incbtn.sensitive = self.spinbtn.value < 1000000
	end
	local countbox = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 48,
		valign = "CENTER",
		halign = "CENTER",
	}
	countbox:append(decbtn)
	countbox:append(incbtn)
	local numbox = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 24,
		valign = "CENTER",
	}
	numbox:append(countlabel)
	numbox:append(countbox)
	numbox:add_css_class "popout"
	local box = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 36,
		margin_top = 24,
		margin_bottom = 24,
		margin_start = 24,
		margin_end = 24,
		valign = "CENTER",
		halign = "CENTER",
	}
	box:append(numbox)
	local content = Adw.ToolbarView {
		content = box,
		width_request = 300,
	}
	content:add_top_bar(headerbar)
	self.zoomwin = Adw.Window {
		application = app,
		content = content,
		hide_on_close = true,
		default_width = 400,
		default_height = 300,
		height_request = 294,
		width_request = 360,
	}
	if self.color then content:add_css_class(self.color) end
	if is_devel then self.zoomwin:add_css_class "devel" end
	return self.zoomwin
end

function tally:duplicate()
	local spinner = Gtk.SpinButton.new_with_range(0, 1000000, 1)
	local r = Adw.ExpanderRow()
	r:add_suffix(spinner)
	if self.color then r:add_css_class(self.color) end
	r.title = self.name
	spinner.value = self.value
	local img = Gtk.Image.new_from_icon_name "list-drag-handle-symbolic"
	img:add_css_class "drag-handle"
	r:add_prefix(img)
	return r
end

function tally:delete()
	if self.zoomwin then
		-- Prevent zombie windows from keeping the app alive.
		self.zoomwin:close()
		self.zoomwin:destroy()
		self.zoomwin = nil
	end
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
	application_name = _ "Tally",
	copyright = "Copyright © 2024–2025 Victoria Lacroix",
	developer_name = "Victoria Lacroix",
	issue_url = "https://github.com/vtrlx/tally/issues/",
	license_type = "GPL_3_0",
	version = lib.get_app_ver(),
	website = "https://www.vlacroix.ca/apps/tally/",
}
aboutwin:add_link(_ "Send a tip!", "https://liberapay.com/vtrlx/")
aboutwin.release_notes = [[
<p>Tally now displays properly on a wider range of mobile devices.</p>
]]
aboutwin.release_notes_version = "0.4.2"

local function newwin()
	-- Force the window to be unique.
	if app.active_window then return app.active_window end

	local newbtn = Gtk.MenuButton {
		icon_name = "list-add-symbolic",
		tooltip_text = _ "Create a new counter",
	}
	local delbtn = Gtk.Button {
		icon_name = "edit-delete-symbolic",
		tooltip_text = _ "Delete selected counters",
		visible = false,
	}
	delbtn:add_css_class "destructive-action"
	local searchbtn = Gtk.ToggleButton {
		icon_name = "system-search-symbolic",
		tooltip_text = _ "Filter counters by name and/or colour",
	}
	local infobtn = Gtk.Button {
		icon_name = "help-about-symbolic",
		tooltip_text = _ "About Tally",
	}
	local checkbtn = Gtk.ToggleButton {
		icon_name = "checkbox-checked-symbolic",
		tooltip_text = _ "Select counters to delete",
	}

	local header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle.new(_ "Tally", ""),
	}
	header:pack_start(newbtn)
	header:pack_start(delbtn)
	header:pack_start(checkbtn)
	header:pack_end(infobtn)
	header:pack_end(searchbtn)

	local searchentry = Gtk.SearchEntry {
		placeholder_text = _ "Filter by name…",
	}

	local searchcolorbox = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
	}
	searchcolorbox:add_css_class "colorselector"
	local filtcolors = {}
	local searchcolorchecks = {}

	local searchbox = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 6,
		margin_top = 6,
		margin_bottom = 6,
	}
	searchbox:append(searchentry)
	searchbox:append(searchcolorbox)

	local searchbar = Gtk.SearchBar {
		child = searchbox,
	}
	searchbar:connect_entry(searchentry)
	searchbar:bind_property("search-mode-enabled", searchbtn, "active", "BIDIRECTIONAL")
	-- Despite mapping property names with underscores and providing a lovely syntax for defining signal event handlers, LGI doesn't do both at the same time.
	searchbar.on_notify["search-mode-enabled"] = function()
		for _, cb in ipairs(searchcolorchecks) do cb.active = false end
	end

	local lbox = Gtk.ListBox {
		selection_mode = "NONE",
		valign = "START",
		visible = false,
	}
	lbox:add_css_class "tally-list"
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
		table.insert(searchcolorchecks, checkbtn)
		searchcolorbox:append(checkbtn)
	end

	local newtallycolor
	local createbtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "list-add-symbolic",
			label = _ "Add to list",
		},
		tooltip_text = _ "Add this counter to the list",
		halign = "CENTER",
	}
	createbtn:add_css_class "suggested-action"
	createbtn.sensitive = false

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
	}
	tallycolorbox:add_css_class "colorselector"
	local newsystemcheckbtn = Gtk.CheckButton {}
	tallycolorbox:append(newsystemcheckbtn)
	function newsystemcheckbtn.on_notify.active()
		newtallycolor = nil
	end
	for _, c in ipairs { "red", "orange", "yellow", "green", "blue", "purple" } do
		local checkbtn = Gtk.CheckButton { group = newsystemcheckbtn }
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
	}
	pbox:append(nameentry)
	pbox:append(tallycolorbox)
	pbox:append(createbtn)
	local popover = Gtk.Popover {
		child = pbox,
	}
	function popover.on_notify.visible()
		nameentry.text = ""
		-- Prevent showing the error CSS when popping up the popover.
		nameentry:remove_css_class "error"
		newsystemcheckbtn.active = true
	end
	newbtn.popover = popover

	function checkbtn.on_notify.active()
		if checkbtn.active then
			checkbtn.tooltip_text = _ "Stop selecting without deleting anything"
			newbtn.visible = false
			delbtn.visible = true
		else
			checkbtn.tooltip_text = _ "Select counters to delete"
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
	multi:set_child("list", lbox)
	multi:add_layout(biglayout)
	multi:add_layout(smalllayout)

	local scroll = Gtk.ScrolledWindow {
		hscrollbar_policy = "NEVER",
		child = multi,
	}
	local function scroll_to_bottom()
		scroll.vadjustment.value = scroll.vadjustment.upper
	end
	local function do_create()
		if #nameentry.text == 0 then return end
		local t = tally {
			name = nameentry.text,
			color = newtallycolor,
		}
		t.viewport = scroll:get_child()
		table.insert(tallies, t)
		tallyrows[t.row] = t
		lbox:append(t.row)
		if not lbox.visible then lbox.visible = true end
		GLib.timeout_add(GLib.PRIORITY_DEFAULT, 20, scroll_to_bottom)
		popover:popdown()
	end
	nameentry.on_activate = do_create
	createbtn.on_clicked = do_create

	for _, t in ipairs(tallies) do
		t.viewport = scroll:get_child()
	end

	local tbview = Adw.ToolbarView {
		content = scroll,
	}
	tbview:add_top_bar(header)
	tbview:add_top_bar(searchbar)

	local function enlarge()
		multi.layout = biglayout
		lbox:remove_css_class "separators"
		lbox:add_css_class "boxed-list"
		tbview.top_bar_style = "FLAT"
	end

	local function shrink()
		multi.layout = smalllayout
		lbox:remove_css_class "boxed-list"
		lbox:add_css_class "separators"
		tbview.top_bar_style = "RAISED_BORDER"
	end

	local window = Adw.ApplicationWindow {
		application = app,
		title = _ "Tally",
		content = tbview,
		default_height = 600,
		default_width = 500,
		height_request = 294,
		width_request = 360,
	}

	local bpcond = Adw.BreakpointCondition.new_length("MAX_WIDTH", 400, "PX")
	local breakpoint = Adw.Breakpoint.new(bpcond)
	breakpoint.on_apply = shrink
	breakpoint.on_unapply = enlarge
	window:add_breakpoint(breakpoint)

	function infobtn.on_clicked()
		aboutwin:present(window)
	end

	searchbar.key_capture_widget = window
	if is_devel then
		window:add_css_class "devel"
	end

	function window:on_close_request()
		for _, t in ipairs(tallies) do
			if t.zoomwin then
				t.zoomwin:close()
				t.zoomwin:destroy()
				t.zoomwin = nil
			end
		end
	end

	searchentry:grab_focus()
	window:present()
end

--[[
SECTION: Styles
]]--

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
