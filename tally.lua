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

	self.row = Adw.SpinRow.new_with_range(0, 1000000, 1)
	self.row.value = self.value
	function self.row.on_notify.value()
		self.value = self.row.value
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
		end
	end
	self.row:add_prefix(self.entry)
	function self.row:on_activate()
		self.entry:grab_focus()
	end

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
		local lbox = self.row.parent
		lbox:remove(widget)
		lbox:insert(widget, target_position)
		table.remove(tallies, source_position + 1)
		local sourcetally = tallyrows[widget]
		table.insert(tallies, target_position + 1, sourcetally)
		return true
	end

	img:add_controller(src)
	self.row:add_controller(tgt)

	self.row:add_prefix(img)

	local menubtn = Gtk.MenuButton {
		icon_name = "view-more-horizontal-symbolic",
		margin_top = 6,
		margin_bottom = 6,
		direction = "RIGHT",
		popover = self:menu(),
	}
	menubtn:add_css_class "flat"
	self.row:add_suffix(menubtn)

	self:read()
end)

function tally:read()
	self.entry.text = self.name
	self.row.value = self.value
end

function tally:menu()
	-- FIXME: Generate the popover menu through a callback instead of on construction.

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

	local box = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
		margin_start = 6,
		margin_end = 6,
		margin_top = 6,
		margin_bottom = 6,
	}
	box:append(udbox)
	box:append(tbbox)
	box:append(delbtn)

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
	r.title = self.name
	r.value = self.value
	r:add_suffix(Gtk.Button.new_from_icon_name "view-more-horizontal-symbolic")
	local img = Gtk.Image.new_from_icon_name "list-drag-handle-symbolic"
	img:add_css_class "drag-handle"
	r:add_prefix(img)
	return r
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
	if not f then
		print("Cannot load saved tallies", err)
		return
	end
	local saved = f()
	assert(type(saved) == "table")
	for _, v in ipairs(saved) do
		local t = tally(v)
		table.insert(tallies, t)
		tallyrows[t.row] = t
	end
end

do -- Initialize configuration if it doesn't exist, load if it does.
	if not fileexists(tallydir) then
		mkdir(tallydir)
	elseif not isdir(tallydir) then
		error "installation is broken"
	end
	if not fileexists(tallyfile) then
		io.open(tallyfile, "w"):write("return {}\n"):close()
	end
	readcfg()
end

local function tallydelete(t, lbox)
	table.remove(tallies, t.row:get_index() + 1)
	lbox:remove(t.row)
	if not lbox:get_row_at_index(0) then lbox.visible = false end
end

--[[
SECTION: Window construction
]]--

local aboutwin = Adw.AboutDialog {
	application_name = "Tally",
	copyright = "© 2024 Victoria Lacroix",
	developer_name = "Victoria Lacroix",
	issue_url = "https://github.com/vtrlx/tally/issues/",
	license_type = "GPL_3_0",
	version = "alpha",
	website = "https://github.com/vtrlx/tally/",
}

local function newwin()
	-- Force the window to be unique.
	if app.active_window then return app.active_window end

	local newbtn = Gtk.Button.new_from_icon_name "list-add-symbolic"
	local searchbtn = Gtk.ToggleButton {
		icon_name = "system-search-symbolic",
	}
	local infobtn = Gtk.Button.new_from_icon_name "help-about-symbolic"

	local header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle.new("Tally", ""),
	}
	header:pack_start(newbtn)
	header:pack_start(searchbtn)
	header:pack_end(infobtn)

	local searchentry = Gtk.SearchEntry {
		placeholder_text = "Filter by name…",
	}

	local searchbar = Gtk.SearchBar {
		child = searchentry,
	}
	searchbar:connect_entry(searchentry)
	searchbar:bind_property("search-mode-enabled", searchbtn, "active", "BIDIRECTIONAL")
	function searchbar.on_notify.search_mode_enabled()
		searchentry.text = ""
	end

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
		table.insert(tallies, t)
		tallyrows[t.row] = t
		function t:delete()
			tallydelete(t, lbox)
			searchentry:grab_focus()
			tallyrows[t.row] = nil
		end
		lbox:append(t.row)
		t.entry:grab_focus()
		if not lbox.visible then lbox.visible = true end
	end
	function searchentry:on_search_changed()
		lbox:invalidate_filter()
	end

	-- Initialize loaded tallies.
	for _, t in ipairs(tallies) do
		lbox:append(t.row)
		function t:delete()
			tallydelete(t, lbox)
			searchentry:grab_focus()
			tallyrows[t.row] = nil
		end
	end
	if #tallies > 0 then lbox.visible = true end

	local clamp = Adw.Clamp {
		child = lbox,
		maximum_size = 500,
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
		content = tbview,
		height_request = 500,
		width_request = 600,
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
