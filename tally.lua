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

--[[ Class system

Simple object-orientation implementation. Adapted from http://lua-users.org/wiki/SimpleLuaClasses to rely more heavily on Lua metatables. Resulting objects only have two predefined methods, :init() to (re)initialize and :isa() to compare against other objects.
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

-- Tally counter row widget

-- The wonders of being able to reference a class before its definition.
local function tallymenu(tally)
	local namerow = Adw.EntryRow {
		text = tally.name,
		title = "Name",
	}
	local function namevalid()
		return #namerow.text
	end

	local valuerow = Adw.EntryRow {
		text = tally.value,
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

	local savebtn = Gtk.Button {
		label = "Apply",
		halign = "END",
	}
	savebtn:add_css_class "suggested-action"

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
	box:append(savebtn)

	local popover = Gtk.Popover {
		child = box,
	}

	function savebtn:on_clicked()
		tally.name = namerow.text
		tally.value = math.floor(tonumber(valuerow.text))
		tally:update()
		popover:popdown()
	end

	return popover
end

local tally = newclass(function(self, name)
	self.value = 0
	self.name = name or "Counter"
	self.row = Adw.SpinRow.new_with_range(0, 1000000, 1)
	self.row.title = self.name
	self.drag_x, self.drag_y = 0, 0

	local menubtn = Gtk.MenuButton {
		icon_name = "view-more-horizontal-symbolic",
		margin_top = 6,
		margin_bottom = 6,
		popover = tallymenu(self),
	}
	menubtn:add_css_class "flat"
	self.row:add_suffix(menubtn)
end)

function tally:update()
	self.row.title = self.name
	self.row.value = self.value
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
		return true
	end

	self.row:add_controller(src)
	self.row:add_controller(tgt)

	self.row:add_prefix(img)
end

-- Window management

local function new_window()
	-- Force the window to be unique.
	if app.active_window then return app.active_window end

	local newbtn = Gtk.Button.new_from_icon_name "list-add-symbolic"

	local header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle.new("Tally", ""),
	}
	header:pack_start(newbtn)

	-- Adw.PreferencesGroup can't insert at arbitrary positions, so it's Gtk.ListBox instead.
	local lbox = Gtk.ListBox {
		selection_mode = "NONE",
		valign = "START",
		visible = false,
	}
	lbox:add_css_class "boxed-list"
	function newbtn:on_clicked()
		local t = tally()
		t:enable_drag(lbox)
		lbox:append(t.row)
		lbox.visible = true
	end

	local clamp = Adw.Clamp {
		child = lbox,
		maximum_size = 400,
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

	local window = Adw.ApplicationWindow {
		application = app,
		content = tbview,
		height_request = 300,
		width_request = 400,
	}
	if is_devel then
		window:add_css_class "devel"
	end

	window:present()
end

-- App management

function app:on_activate()
	if app.active_window then app.active_window:present() end
end

function app:on_startup()
	new_window()
end

return app:run()
