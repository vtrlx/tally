--[[ tally.lua — Tally counter for GNOME ]]--

-- Load packages from flatpak.
package.cpath = "/app/lib/lua/5.4/?.so;" .. package.cpath
package.path = "/app/share/lua/5.4/?.lua;" .. package.path

local lib = require "tallylib"

local lgi = require "lgi"
local Adw = lgi.require "Adw"
local Gtk = lgi.require "Gtk"
local Gdk = lgi.require "Gdk"
local GObject = lgi.require "GObject"

local app_id = lib.get_app_id()
local is_devel = lib.get_is_devel()
local app = Adw.Application {
	application_id = app_id,
}

--[[
SECTION: Class system

Simple object-orientation implementation. Adapted from http://lua-users.org/wiki/SimpleLuaClasses to rely more heavily on Lua metatables. Resulting objects only have two predefined methods, :init() to (re)initialize and :isa() to compare against other objects. The resulting table can be called as a function to construct new object instances, or have values on it to define class methods and class-static variables.
]]--

local function newclass(base, init)
	local c = {}
	local mt = {}
	local metaevents = {
		--[[ Excluded: __call, __index, __newindex ]]--
		"__add", "__sub", "__mul", "__div",
		"__mod", "__pow", "__concat",
		"__eq", "__lt", "__le",
		"__unm", "__len",
		"__tostring",
	}
	if not init and type(base) == "function" then
		init = base
		base = nil
	elseif type(base) == "table" then
		mt.__index = base
		for _, v in ipairs(metaevents) do
			c[v] = base[v]
		end
	end
	c.__index = c

	function c:init(...)
		if init then
			init(self, ...)
		elseif base then
			base.init(self, ...)
		end
	end

	function mt:__call(...)
		local obj = setmetatable({}, c)
		obj:init(...)
		return obj
	end

	-- Invoke the same constructor as this object instance. If no arguments are given, clones the object instead. To explicitly invoke a constructor with no arguments, pass nil.
	function c:__call(...)
		if select('#', ...) > 0 then
			-- This invokes __call() as defined on the metatable.
			return c(...)
		else
			local copy = setmetatable({}, c)
			for k, v in pairs(self) do
				copy[k] = v
			end
			return copy
		end
	end

	function c:isa(klass)
		local m = getmetatable(self)
		while m do
			if m == klass then return true end
			m = getmetatable(m).__index
		end
		return false
	end

	return setmetatable(c, mt)
end

--[[
SECTION: Tally counter class
]]--

local tallies = {}

local tally = newclass(function(self, name, value)
	self.value = 0
	self.name = name or "unnamed"
	self.row = Adw.SpinRow.new_with_range(value or 0, 1000000, 1)

	self.entry = Gtk.Text {
		text = self.name,
		placeholder_text = self.name,
		margin_top = 6,
		margin_bottom = 6,
	}
	function self.entry.on_activate()
		if #self.entry.text == 0 then
			self.entry.text = self.name
			return
		end
		self.name = self.entry.text
		self.entry.placeholder_text = self.entry.text
	end
	self.row:add_prefix(self.entry)
	function self.row:on_activate()
		self.entry:grab_focus()
	end

	local menubtn = Gtk.MenuButton {
		icon_name = "view-more-horizontal-symbolic",
		margin_top = 6,
		margin_bottom = 6,
		popover = self:menu(),
	}
	menubtn:add_css_class "flat"
	self.row:add_suffix(menubtn)

	self:update()
	table.insert(tallies, self)
end)

function tally:update()
	self.entry.text = self.name
	self.row.value = self.value
end

function tally:menu()
	local namerow = Adw.EntryRow {
		text = self.name,
		title = "Name",
	}
	local function namevalid()
		return #namerow.text
	end

	local valuerow = Adw.EntryRow {
		text = self.value,
		title = "Value",
	}
	local function valuevalid()
		return #valuerow.text
			and type(tonumber(valuerow.text)) == "number"
			-- Prevent decimal points.
			and not (valuerow.text:match "%.")
	end

	local function isvalid()
		return namevalid() and valuevalid()
	end

	local pgroup = Adw.PreferencesGroup()
	pgroup:add(namerow)
	pgroup:add(valuerow)

	local delbtn = Gtk.Button {
		label = "Delete",
		halign = "START",
	}
	delbtn:add_css_class "destructive-action"

	local savebtn = Gtk.Button {
		label = "Apply",
		halign = "END",
	}
	savebtn:add_css_class "suggested-action"

	local bbox = Gtk.CenterBox {
		start_widget = delbtn,
		end_widget = savebtn,
	}

	function namerow:on_changed()
		if not namevalid() then
			namerow:add_css_class "error"
			savebtn.sensitive = false
		else
			namerow:remove_css_class "error"
			if isvalid() then savebtn.sensitive = true end
		end
	end
	function valuerow:on_changed()
		if not valuevalid() then
			valuerow:add_css_class "error"
			savebtn.sensitive = false
		else
			valuerow:remove_css_class "error"
			if isvalid() then savebtn.sensitive = true end
		end
	end

	local box = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 12,
		margin_start = 12,
		margin_end = 12,
		margin_top = 6,
		margin_bottom = 6,
	}
	box:append(pgroup)
	box:append(bbox)

	local popover = Gtk.Popover {
		child = box,
	}

	function delbtn.on_clicked()
		popover:popdown()
		self:delete()
	end
	function savebtn.on_clicked()
		popover:popdown()
		self.name = namerow.text
		self.value = math.floor(tonumber(valuerow.text))
		self:update()
	end

	return popover
end

function tally:duplicate()
	local r = Adw.SpinRow.new_with_range(0, 1000000, 1)
	r.title = self.name
	r.value = self.value
	r:add_suffix(Gtk.Button.new_from_icon_name "view-more-horizontal-symbolic")
	local img = Gtk.Image.new_from_icon_name "list-drag-handle-symbolic"
	img:add_css_class "drag-handle"
	r:add_prefix(img)
	return r
end

function tally:enable_drag(box)
	local img = Gtk.Image.new_from_icon_name "list-drag-handle-symbolic"
	img:add_css_class "drag-handle"

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
		-- FIXME: save order in global list
		box:remove(widget)
		box:insert(widget, target_position)
		table.remove(tallies, source_position + 1)
		table.insert(tallies, self, target_position + 1)
		return true
	end

	self.row:add_controller(src)
	self.row:add_controller(tgt)

	self.row:add_prefix(img)
end

--[[
SECTION: Window construction
]]--

local tallyrows = {}

local function new_window()
	-- Force the window to be unique.
	if app.active_window then return app.active_window end

	local newbtn = Gtk.Button.new_from_icon_name "list-add-symbolic"
	local searchbtn = Gtk.ToggleButton {
		icon_name = "system-search-symbolic",
	}

	local header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle.new("Tally", ""),
	}
	header:pack_start(newbtn)
	header:pack_start(searchbtn)

	local searchentry = Gtk.SearchEntry {
		placeholder_text = "Filter by name…",
	}

	local searchbar = Gtk.SearchBar {
		child = searchentry,
	}
	searchbar:connect_entry(searchentry)
	searchbar:bind_property("search-mode-enabled", searchbtn, "active", "BIDIRECTIONAL")

	local lbox = Gtk.ListBox {
		selection_mode = "NONE",
		valign = "START",
		visible = false,
	}
	lbox:add_css_class "boxed-list"
	lbox:set_filter_func(function(row)
		if #searchentry.text == 0 then return true end
		local t = tallyrows[row]
		local title = t.name:lower()
		local entry = searchentry.text:lower()
		return (title:find(entry, 1, true))
	end)
	lbox:set_placeholder(Gtk.Label {
		label = "no matches",
		margin_top = 12,
		margin_bottom = 12,
	})
	function newbtn:on_clicked()
		local t = tally()
		tallyrows[t.row] = t
		function t:delete()
			lbox:remove(t.row)
			if not lbox:get_row_at_index(0) then
				lbox.visible = false
			end
		end
		t:enable_drag(lbox)
		lbox:append(t.row)
		if not lbox.visible then lbox.visible = true end
	end
	function searchentry:on_search_changed()
		lbox:invalidate_filter()
	end

	local clamp = Adw.Clamp {
		child = lbox,
		maximum_size = 500,
		margin_start = 18,
		margin_end = 18,
		margin_top = 18,
		margin_bottom = 18,
	}

	local scroll = Gtk.ScrolledWindow {
		hscrollbar_policy = "NEVER",
		child = clamp,
	}

	local tbview = Adw.ToolbarView {
		content = scroll,
	}
	tbview:add_top_bar(header)
	tbview:add_top_bar(searchbar)

	local window = Adw.ApplicationWindow {
		application = app,
		content = tbview,
		height_request = 350,
		width_request = 500,
	}
	if is_devel then
		window:add_css_class "devel"
	end
	searchbar.key_capture_widget = window
	searchbar.on_notify.search_mode_enabled = function()
		searchentry.text = ""
		lbox:invalidate_filter()
	end

	window:present()
end

--[[
SECTION: App callbacks
]]--

function app:on_activate()
	if app.active_window then app.active_window:present() end
end

function app:on_startup()
	new_window()
end

return app:run()
