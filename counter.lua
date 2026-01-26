--[[ counter.lua (Tally counter class) ]]--

local lib = require "mainlib"

-- Make gettext available through the name expected by xgettext.
local _ = lib.gettext

local LuaGObject = require "LuaGObject"
local Adw = LuaGObject.require "Adw"
local Gtk = LuaGObject.require "Gtk"
local Gdk = LuaGObject.require "Gdk"
local GObject = LuaGObject.require "GObject"
local GLib = LuaGObject.require "GLib"
local Gio = LuaGObject.require "Gio"

local counters = {} -- Lua table containing all counters.
local counterrows = {} -- Lua table associating Gtk.ListBoxRow items to their respective counter.

local counter = lib.newclass(function(self, param)
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
		lib.queuewrite()
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

	self.draghdl = Gtk.Image.new_from_icon_name "drag-handle-symbolic"
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

		self:createmenu(dragrow)

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
		lib.queuewrite()
		return true
	end

	self.draghdl:add_controller(src)
	self.row:add_controller(tgt)

	self.row:add_prefix(self.draghdl)
	self.row:add_prefix(self.checkbox)

	self.row:add_suffix(self.countlabel)
	self.row:add_suffix(self.spinbtn)

	self:createmenu(self.row)

	-- Force the contents of the suffix box to align right when the spinbutton is made invisible.
	local suffixbox = self.row.child:get_last_child()
	suffixbox.hexpand = true
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
		tooltip_text = lib.getcolorname(color),
		active = (color or "system") == self:getcolor(),
	}
	if color then checkbtn:add_css_class(color) end
	function checkbtn.on_notify.active()
		self:setcolor(color)
		lib.queuewrite()
	end
	return checkbtn
end

function counter:colorrow()
	local box = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
		valign = "CENTER",
		extra_css_classes = { "colorselector" },
	}
	local system = self:gencolorcheck()
	box:append(system)
	for _, color in ipairs { "red", "orange", "yellow", "green", "blue", "purple" } do
		box:append(self:gencolorcheck(color, system))
	end
	if not self.color then system.active = true end
	return box
end

function counter:createmenu(row)
	-- If self.entry already exists, then this menu won't actually control the counter and is just as a display when drag-and-dropping. For added security, if it's a duplicate menu
	local duplicate = self.entry ~= nil

	local entry = Adw.EntryRow {
		text = self.name,
		title = _ "Name",
		sensitive = not duplicate,
	}
	if not self.entry then self.entry = entry end
	row:add_row(entry)

	local crow = Adw.ActionRow {
		title = _ "Color",
		sensitive = not duplicate,
		suffixes = self:colorrow(),
	}
	row:add_row(crow)

	local topbtn = Gtk.Button {
		icon_name = "move-top-symbolic",
		tooltip_text = _ "Move counter to the top of the current list",
		sensitive = not duplicate,
	}
	local bottombtn = Gtk.Button {
		icon_name = "move-bottom-symbolic",
		tooltip_text = _ "Move counter to the bottom of the current list",
		sensitive = not duplicate,
	}

	local upbtn = Gtk.Button {
		icon_name = "move-up-symbolic",
		tooltip_text = _ "Move counter to just above the previous row",
		valign = "CENTER",
		sensitive = not duplicate,
	}
	local downbtn = Gtk.Button {
		icon_name = "move-down-symbolic",
		tooltip_text = _ "Move counter to just below the next row",
		sensitive = not duplicate,
	}

	local orderbox = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
		halign = "END",
		valign = "CENTER",
		topbtn,
		upbtn,
		downbtn,
		bottombtn,
	}

	local orderrow = Adw.ActionRow {
		title = _ "Reorder in List",
		suffixes = { orderbox },
	}

	row:add_row(orderrow)

	local popoutbtn = Gtk.Button {
		icon_name = "pop-out-symbolic",
		tooltip_text = _ "Create a new window for this counter",
		halign = "END",
		hexpand = true,
		valign = "CENTER",
		sensitive = not duplicate,
	}
	local popoutrow = Adw.ActionRow {
		title = _ "Show in a Separate Window",
	}
	popoutrow:add_suffix(popoutbtn)
	row:add_row(popoutrow)

	if duplicate then return end

	function entry.on_changed()
		if #entry.text == 0 then
			row:add_css_class "error"
			return
		end
		row:remove_css_class "error"
		self.name = entry.text
		row.title = entry.text
		if self.zoomwin then
			self.zoomwin.title = entry.text .. " — " .. lib.gettext "Tally"
		end
		lib.queuewrite()
	end

	function upbtn.on_clicked()
		local rindex = row:get_index()
		local tindex = rindex + 1
		local lbox = row.parent
		while rindex > 0 do
			rindex = rindex - 1
			local other = lbox:get_row_at_index(rindex)
			if other:get_mapped() then
				-- This is the previous visible row, so place above
				table.remove(counters, tindex)
				table.insert(counters, rindex + 1, self)
				lbox:remove(row)
				lbox:insert(row, rindex)
				lib.queuewrite()
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
			if other:get_mapped() then
				-- This is the next visible row, so place below.
				table.remove(counters, tindex)
				table.insert(counters, rindex + 1, self)
				lbox:remove(row)
				lbox:insert(row, rindex)
				lib.queuewrite()
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
		lib.queuewrite()
		GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, function() self:scroll() end)
	end

	function bottombtn.on_clicked()
		table.remove(counters, row:get_index() + 1)
		table.insert(counters, self)
		local lbox = row.parent
		lbox:remove(row)
		lbox:append(row)
		lib.queuewrite()
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
	self.entry:bind_property("text", title, "title", "BIDIRECTIONAL")
	local headerbar = Adw.HeaderBar {
		title_widget = title,
	}
	local countlabel = Gtk.Label {
		label = ("%d"):format(self.spinbtn.value),
		width_request = 240,
		halign = "CENTER",
		extra_css_classes = { "numeric" },
	}
	local decbtn = Gtk.Button {
		icon_name = "minus-symbolic",
		sensitive = self.spinbtn.value > 0,
		tooltip_text = _ "Decrement by 1",
		extra_css_classes = { "circular" },
		on_clicked = function()
			self.spinbtn.value = self.spinbtn.value - 1
		end,
	}
	local incbtn = Gtk.Button {
		icon_name = "plus-symbolic",
		sensitive = self.spinbtn.value < 1000000,
		tooltip_text = _ "Increment by 1",
		extra_css_classes = { "circular" },
		on_clicked = function()
			self.spinbtn.value = self.spinbtn.value + 1
		end,
	}
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
		decbtn,
		incbtn,
	}
	local numbox = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 24,
		valign = "CENTER",
		extra_css_classes = { "popout" },
		countlabel,
		countbox,
	}
	local box = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 36,
		margin_top = 24,
		margin_bottom = 24,
		margin_start = 24,
		margin_end = 24,
		valign = "CENTER",
		halign = "CENTER",
		numbox,
	}
	local handle = Gtk.WindowHandle {
		child = box,
	}
	local content = Adw.ToolbarView {
		content = handle,
		width_request = 300,
		top_bars = headerbar,
	}
	self.zoomwin = Adw.ApplicationWindow {
		application = lib.app,
		content = content,
		title = self.name .. " — " .. _ "Tally",
		hide_on_close = true,
		default_width = 400,
		default_height = 300,
		height_request = 294,
		width_request = 360,
	}
	function self.zoomwin.on_close_request()
		self.zoomwin:destroy()
		self.zoomwin = nil
	end
	local close_action = Gio.SimpleAction.new "close"
	function close_action.on_activate()
		self.zoomwin:close()
	end
	close_action.enabled = true
	self.zoomwin:add_action(close_action)
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
	local img = Gtk.Image.new_from_icon_name "drag-handle-symbolic"
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
	lib.queuewrite()
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
