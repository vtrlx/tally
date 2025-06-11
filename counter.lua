--[[ counter.lua (Tally counter class) ]]--

local lib = require "mainlib"

local _ = lib.gettext

local lgi = require "lgi"
local Adw = lgi.require "Adw"
local Gtk = lgi.require "Gtk"
local Gdk = lgi.require "Gdk"
local GObject = lgi.require "GObject"
local GLib = lgi.require "GLib"

local counters = {} -- Lua table containing all counters.
local counterrows = {} -- Lua table associating Gtk.ListBoxRow items to their respective counter.

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

local counter = newclass(function(self, param)
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

	self.row = Adw.ExpanderRow()
	self.row:add_css_class "spin"
	self.row.title = self.name
	local function scroll_in()
		self:scroll()
	end
	function self.row.on_notify.expanded()
		if self.row.expanded then
			GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, scroll_in)
		end
	end

	self.spinbtn = Gtk.SpinButton.new_with_range(0, 1000000, 1)
	self.spinbtn:get_first_child().xalign = 1
	self.spinbtn.valign = "CENTER"
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
		self.drag_widget:add_css_class "tally-list"
		self.drag_widget:add_css_class "boxed-list"
		self.drag_widget:set_size_request(allocation.width, allocation.height)

		local dragrow = self:duplicate()
		self.drag_widget:append(dragrow)
		self.drag_widget:drag_highlight_row(dragrow)

		self:createmenu(dragrow, false)

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
		table.remove(counters, source_position + 1)
		local sourcetally = counterrows[widget]
		table.insert(counters, target_position + 1, sourcetally)
		return true
	end

	self.draghdl:add_controller(src)
	self.row:add_controller(tgt)

	self.row:add_prefix(self.draghdl)
	self.row:add_prefix(self.checkbox)

	self.row:add_suffix(self.countlabel)
	self.row:add_suffix(self.spinbtn)

	self:createmenu(self.row, true)

	-- Force the contents of the suffix box to align right when the spinbutton is made invisible.
	local suffixbox = self.row.child:get_last_child()
	suffixbox.hexpand = true
--	suffixbox.halign = "END"

	self:read()
end)

function counter:read()
	self.spinbtn.value = self.value
end

function counter:setcheckmode(enabled)
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

function counter:scroll()
	if not self.viewport then return end
	self.viewport:scroll_to(self.row)
end

function counter:getcolor()
	return self.color or "system"
end

function counter:setcolor(color)
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

function counter:gencolorcheck(color, group)
	local checkbtn = Gtk.CheckButton {
		group = group,
	}
	if color then checkbtn:add_css_class(color) end
	function checkbtn.on_notify.active()
		self:setcolor(color)
	end
	return checkbtn
end

function counter:colorrow()
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

function counter:createmenu(row, sensitive)
	self.entry = Adw.EntryRow {
		text = self.name,
		title = _ "Name",
	}
	row:add_row(self.entry)

	local cbox = self:colorrow()
	local crow = Adw.ActionRow {
		title = _ "Color",
		sensitive = sensitive,
	}
	crow:add_suffix(cbox)
	row:add_row(crow)

	local topbtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "go-top-symbolic",
			label = _ "Move to top",
			halign = "START",
		},
		tooltip_text = _ "Move counter to the top of the current list",
		sensitive = sensitive,
	}
	local bottombtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "go-bottom-symbolic",
			label = _ "Move to bottom",
			halign = "START",
		},
		tooltip_text = _ "Move counter to the bottom of the current list",
		sensitive = sensitive,
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
		sensitive = sensitive,
	}
	local downbtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "go-down-symbolic",
			label = _ "Move down",
			halign = "START",
		},
		tooltip_text = _ "Move counter to just below the next row",
		sensitive = sensitive,
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
	row:add_row(mbox)

	local popoutbtn = Gtk.Button {
		icon_name = "window-new-symbolic",
		tooltip_text = _ "Create a new window for this counter",
		halign = "END",
		hexpand = true,
		valign = "CENTER",
		sensitive = sensitive,
	}
	local popoutrow = Adw.ActionRow {
		title = _ "Show in a separate window",
	}
	popoutrow:add_suffix(popoutbtn)
	row:add_row(popoutrow)

	if not sensitive then return end

	function self.entry.on_changed()
		if #self.entry.text == 0 then
			row:add_css_class "error"
			return
		end
		row:remove_css_class "error"
		self.name = self.entry.text
		row.title = self.entry.text
	end

	function upbtn.on_clicked()
		local rindex = row:get_index()
		local tindex = rindex + 1
		local lbox = row.parent
		while rindex > 0 do
			rindex = rindex - 1
			local other = lbox:get_row_at_index(rindex)
			if other.mapped then
				-- This is the previous visible row, so place above
				table.remove(counters, tindex)
				table.insert(counters, rindex + 1, self)
				lbox:remove(row)
				lbox:insert(row, rindex)
				GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, function() self:scroll() end)
				return
			end
		end
	end

	function downbtn.on_clicked()
		local rindex = row:get_index()
		local tindex = rindex + 1
		local lbox = row.parent
		rindex = rindex + 1
		while rindex < #counters do
			local other = lbox:get_row_at_index(rindex)
			if other.mapped then
				-- This is the next visible row, so place below.
				table.remove(counters, tindex)
				table.insert(counters, rindex + 1, self)
				lbox:remove(row)
				lbox:insert(row, rindex)
				GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, function() self:scroll() end)
				return
			end
			rindex = rindex + 1
		end
	end

	function topbtn.on_clicked()
		table.remove(counters, row:get_index() + 1)
		table.insert(counters, 1, self)
		local lbox = row.parent
		lbox:remove(row)
		lbox:prepend(row)
		GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, function() self:scroll() end)
	end

	function bottombtn.on_clicked()
		table.remove(counters, row:get_index() + 1)
		table.insert(counters, self)
		local lbox = row.parent
		lbox:remove(row)
		lbox:append(row)
		GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, function() self:scroll() end)
	end

	function popoutbtn.on_clicked()
		self:popout():present()
	end
end

function counter:popout()
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
		tooltip_text = _ "Decrement by 1",
	}
	decbtn:add_css_class "circular"
	function decbtn.on_clicked()
		self.spinbtn.value = self.spinbtn.value - 1
	end
	local incbtn = Gtk.Button {
		icon_name = "value-increase-symbolic",
		sensitive = self.spinbtn.value < 1000000,
		tooltip_text = _ "Increment by 1",
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

function counter:duplicate()
	local spinner = Gtk.SpinButton.new_with_range(0, 1000000, 1)
	local r = Adw.ExpanderRow()
	r.expanded = self.row.expanded
	r:add_suffix(spinner)
	if self.color then r:add_css_class(self.color) end
	r.title = self.name
	spinner.value = self.value
	local img = Gtk.Image.new_from_icon_name "list-drag-handle-symbolic"
	img:add_css_class "drag-handle"
	r:add_prefix(img)
	return r
end

function counter:delete()
	if self.zoomwin then
		-- Prevent zombie windows from keeping the app alive.
		self.zoomwin:close()
		self.zoomwin:destroy()
		self.zoomwin = nil
	end
	local lbox = self.row.parent
	if not lbox then return end
	table.remove(counters, self.row:get_index() + 1)
	lbox:remove(self.row)
	if not lbox:get_row_at_index(0) then lbox.visible = false end
end

function counter:serialize()
	local r = ""
	for k, v in pairs(self) do
		if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
			r = r .. ("\t[%q] = %q,\n"):format(k, v)
		end
	end
	return ("{\n%s},\n"):format(r)
end

return { counter, counters, counterrows }
