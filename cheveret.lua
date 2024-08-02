--[[ cheveret.lua — GNOME text editor with as few features as possible besides a file pane.
Copyright © 2024 Victoria Lacroix

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <https://www.gnu.org/licenses/>. ]]

-- Support Library --

-- As this is a Linux program, many of these functions are specific to Linux.

-- Allows the libraries to be loaded by Flatpak.
package.cpath = "/app/lib/lua/5.4/?.so;" .. package.cpath
package.path = "/app/share/lua/5.4/?.lua;" .. package.path

local lfs = require "lfs"
local lib = require "chevlib"
local inotify = require "inotify"

function lib.get_home_directory()
	return os.getenv "HOME"
end

function lib.get_pwd()
	return lib.getcwd() or lib.decode_path "~"
end

-- Replaces the home directory in the given path with a tilde.
function lib.encode_path(path)
	local pattern = "^" .. lib.get_home_directory()
	return path:gsub(pattern, "~", 1)
end

-- Replaces a tilde at the start of the path with the user's home directory.
function lib.decode_path(path)
	return path:gsub("^~", lib.get_home_directory(), 1)
end

function lib.absolute_path(file_path)
	file_path = lib.decode_path(file_path)
	local full_path = file_path
	local dir
	if full_path:sub(1, 1) ~= "/" then dir = lib.get_pwd() end
	if dir then
		local up_pattern = "^%.%./"
		local only_up_pattern = "^..$"
		local cur_dir_pattern = "/[^/]+$"
		while file_path:find(up_pattern) do
			file_path = file_path:gsub(up_pattern, "")
			dir = dir:gsub(cur_dir_pattern, "")
		end
		while file_path:find(only_up_pattern) do
			file_path = ""
			dir = dir:gsub(cur_dir_pattern, "")
		end
		full_path = dir .. "/" .. file_path
	end
	return full_path
end

-- Takes the given file path (relative or absolute) and returns the directory and the file name.
function lib.dir_and_file(file_path)
	file_path = lib.absolute_path(file_path)
	local last = 1
	while file_path:sub(last + 1):find("/") do
		last = last + (file_path:sub(last + 1):find("/"))
	end
	return file_path:sub(1, last - 1), file_path:sub(last + 1)
end

function lib.file_exists(file_name)
	file_name = lib.absolute_path(file_name)
	local ok, err, code = os.rename(file_name, file_name)
	if not ok then
		-- In Linux, error code 13 when moving a file means the it failed because the directory cannot be made its own child.
		if code == 13 then
			return true
		end
	end
	return ok
end

function lib.is_dir(file_name)
	file_name = lib.absolute_path(file_name)
	if file_name == "/" then return true end
	return lib.file_exists(file_name .. "/")
end

function lib.file_is_binary(file)
	local is_binary = false
	for line in file:lines() do
		if line:match "\0" then
			is_binary = true
			break
		end
	end
	file:seek "set"
	return is_binary
end

-- Main Application --

local lgi = require "lgi"

local GLib = lgi.require "GLib"
local Gio = lgi.require "Gio"
local Adw = lgi.require "Adw"
local Gtk = lgi.require "Gtk"

local app_id = lib.get_app_id()
local is_devel = lib.get_is_devel()
local app_title = "Cheveret"
local app_version = lib.get_app_ver()
local app  = Adw.Application {
	application_id = app_id,
	flags = Gio.ApplicationFlags.NON_UNIQUE,
}

-- Shortcuts from the GNOME HIG (https://developer.gnome.org/hig/reference/keyboard.html)
local accels = {
	["win.close_tab"] = { "<Ctrl>W" },
	["win.save_file"] = { "<Ctrl>S" },
	["win.search"] = { "<Ctrl>F" },
	["win.goto"] = { "<Ctrl>I" },
	["win.toggle_sidebar"] = { "F9" },
	["win.open_workspace"] = {"<Ctrl>N" },
	["win.open_new_workspace"] = { "<Ctrl><Shift>N" },
	["win.project_dir"] = { "<Ctrl>P" },
	["win.shortcuts"] = { "<Ctrl><Shift>slash" },
}
for k, v in pairs(accels) do
	app:set_accels_for_action(k, v)
end

local lerror = error
local function error(...)
	local msg = table.concat({ ... }, " ")
	local dlg = Adw.AlertDialog.new("Error", msg)
	dlg:add_response("cancel", "Okay")
	dlg:choose()
	-- Call Lua's builtin error() function so this new one has the same semantics of unwinding the call stack.
	lerror(...)
end

local aboutdlg = Adw.AboutDialog {
	application_icon = "text-x-generic", -- FIXME: use an actual app icon
	application_name = "Cheveret",
	copyright = "© 2024 Victoria Lacroix",
	developer_name = "Victoria Lacroix",
	developers = {
		"Victoria Lacroix <victoria@vlacroix.ca>",
	},
	issue_url = nil, -- FIXME: assign actual issue URL
	license_type = "GPL_3_0",
	version = lib.get_app_ver(),
	website = nil, -- FIXME: assign actual website URL
}

-- Holds the data for open files.
local editors_by_view = {}
local editors_by_path = {}
local window_widgets = {}

-- Table for text editor functions. They get defined later.
local editor = {}

local function new_editor()
	-- FIXME: Add results count to search entry
	local search_entry = Gtk.SearchEntry {
		placeholder_text = "Find in file…",
		width_request = 300,
	}
	local prev_match = Gtk.Button.new_from_icon_name "go-up-symbolic"
	local next_match = Gtk.Button.new_from_icon_name "go-down-symbolic"
	local match_box = Gtk.Box { orientation = Gtk.Orientation.HORIZONTAL }
	match_box:add_css_class "linked" -- No, but a tin can.
	match_box:append(prev_match)
	match_box:append(next_match)
	local matchnum_label = Gtk.Label {}
	matchnum_label:add_css_class "numeric"
	local search_box = Gtk.Box {
		orientation = Gtk.Orientation.HORIZONTAL,
		spacing = 8,
	}
	search_box:append(search_entry)
	search_box:append(match_box)
	search_box:append(matchnum_label)
	local search_bar = Gtk.SearchBar {
		child = search_box,
		search_mode_enabled = false,
		show_close_button = true,
	}
	search_bar:connect_entry(search_entry)
	local jump_entry = Gtk.Entry {
		placeholder_text = "Go to line…",
	}
	local jump_bar = Gtk.SearchBar {
		child = jump_entry,
		search_mode_enabled = false,
		show_close_button = true,
	}
	local text_view = Gtk.TextView {
		top_margin = 6,
		bottom_margin = 400,
		left_margin = 12,
		right_margin = 18,
		pixels_above_lines = 2,
		pixels_below_lines = 2,
		pixels_inside_wrap = 0,
		wrap_mode = Gtk.WrapMode.WORD_CHAR,
	}
	-- Force monospace numbers regardless of font.
	text_view:add_css_class "numeric"
	text_view.buffer:set_max_undo_levels(0)
	local scrolled_win = Gtk.ScrolledWindow {
		child = text_view,
		hscrollbar_policy = "NEVER",
		vexpand = true,
	}
	local vbox = Gtk.Box { orientation = Gtk.Orientation.VERTICAL }
	vbox:append(search_bar)
	vbox:append(jump_bar)
	vbox:append(scrolled_win)
	local e = {
		matches = {},
		search = {
			entry = search_entry,
			bar = search_bar,
			matchnum = matchnum_label,
		},
		jump = {
			entry = jump_entry,
			bar = jump_bar,
		},
		tv = text_view,
		scroll = scrolled_win,
		widget = vbox,
	}
	function e.tv.buffer:on_modified_changed()
		e:update_title()
	end
	function scrolled_win:on_map()
		e:update_title()
	end
	function search_entry:on_search_changed()
		e:findall(self.text, true)
	end
	function search_entry:on_previous_match()
		e:prev_match(self.text, true)
	end
	function prev_match:on_clicked()
		e:prev_match(search_entry.text, true)
	end
	function search_entry:on_next_match()
		e:next_match(self.text, true)
	end
	function next_match:on_clicked()
		e:next_match(search_entry.text, true)
	end
	function search_entry:on_activate()
		e:next_match(self.text, true)
	end
	function jump_entry:on_activate()
		local n = tonumber(jump_entry.text)
		if type(n) == "number" then
			e:go_to(n)
		end
	end
	return setmetatable(e, {
		__index = editor,
	})
end

local function open_file(path)
	if not app.active_window then return end
	local tab_view = window_widgets[app.active_window].tab_view
	if not tab_view then return end
	if type(path) == "string" then
		path = lib.absolute_path(path)
		local e = editors_by_path[path]
		if e then
			e:grab_focus()
			return
		end
	end
	local e = new_editor()
	if type(path) == "string" then
		e:edit_file(path)
		local iter = e.tv.buffer:get_start_iter()
		e.tv.buffer:select_range(iter, iter)
	end
	editors_by_view[e.widget] = e
	if path then editors_by_path[path] = e end
	local page = tab_view:add_page(e.widget)
	tab_view:set_selected_page(page)
end

local function get_focused_editor()
	if not app.active_window then return {} end
	local tab_view = window_widgets[app.active_window].tab_view
	if not tab_view then return {} end
	local page = tab_view.selected_page
	if not page then return {} end
	return editors_by_view[page.child]
end

-- Workspace Selector --

local function create_file_dialog(pwd, ...)
	local dlg = Gtk.FileChooserNative.new(...)
	local f = Gio.File.new_for_path(pwd)
	dlg:set_current_folder(f)
	return dlg
end

-- Workspace Selector --

local cfgdir = os.getenv("XDG_CONFIG_HOME") .. "/cheveret"
os.execute(("mkdir -p '%s'"):format(cfgdir))
local workspace_history_file = cfgdir .. "/workspace_history"
os.execute(("touch '%s'"):format(workspace_history_file))

local function read_workspaces()
	local workspaces = {}
	for line in io.lines(workspace_history_file) do
		table.insert(workspaces, line)
	end
	return workspaces
end

local function write_workspaces(workspaces)
	assert(type(workspaces) == "table")
	local f = io.open(workspace_history_file, "w")
	for n, ws in ipairs(workspaces) do
		f:write(ws .. "\n")
	end
end

local wsrow = {}
local wsrow_mt = { __index = wsrow }

function wsrow:mode(mode)
	if mode == "open" then
		self.checkbtn.visible = false
		self.openbtn.visible = true
		self.arow:set_activatable_widget(self.openbtn)
	elseif mode == "check" then
		self.checkbtn.visible = true
		self.checkbtn.active = false
		self.openbtn.visible = false
		self.arow:set_activatable_widget(self.checkbtn)
	end
end

function wsrow:getcheck()
	return self.checkbtn.visible and self.checkbtn.active
end

local function new_wsrow(path, cb)
	local checkbtn = Gtk.CheckButton {
		valign = "CENTER",
		vexpand = false,
		visible = false,
	}
	local openbtn = Gtk.Button.new_from_icon_name "document-open-symbolic"
	openbtn:add_css_class "flat"
	local arow = Adw.ActionRow {
		title = path:match "([^/]*)/?$",
		subtitle = lib.encode_path(path:match "^(.*)/"),
	}
	arow:add_prefix(checkbtn)
	arow:add_suffix(openbtn)
	arow:set_activatable_widget(openbtn)
	local r = {
		checkbtn = checkbtn,
		openbtn = openbtn,
		arow = arow,
	}
	function openbtn:on_clicked() cb(path) end
	return setmetatable(r, wsrow_mt)
end

local workspace_selector_window
local function select_workspace(cb)
	if workspace_selector_window then
		workspace_selector_window:present()
		return
	end
	workspace_selector_window = Adw.ApplicationWindow {
		application = app,
		height_request = 600,
		width_request = 600,
	}
	if is_devel then
		workspace_selector_window:add_css_class "devel"
	end
	workspace_selector_window.title = "Cheveret — Select Workspace"
	local workspaces = read_workspaces()
	local wsrows = {}
	local deletebtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "edit-delete-symbolic",
			label = "Forget",
		}
	}
	deletebtn:add_css_class "destructive-action"
	local newbtn = Gtk.Button {
		child = Adw.ButtonContent {
			icon_name = "folder-open-symbolic",
			label = "New…",
		}
	}
	local wslist = Adw.PreferencesGroup {
		title = "Previous Workspaces",
		header_suffix = openbtn,
	}
	for _, ws in ipairs(workspaces) do
		local r = new_wsrow(ws, function()
			cb(ws)
			workspace_selector_window:close()
			workspace_selector_window = nil
		end)
		table.insert(wsrows, r)
		wslist:add(r.arow)
	end
	local selectbtn = Gtk.ToggleButton {
		icon_name = "checkbox-checked-symbolic",
	}
	function selectbtn:on_toggled()
		if selectbtn.active then
			for _, r in ipairs(wsrows) do r:mode "check" end
			wslist.header_suffix = deletebtn
		else
			for _, r in ipairs(wsrows) do r:mode "open" end
			wslist.header_suffix = newbtn
		end
	end
	local contents = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 24,
	}
	function deletebtn:on_clicked()
		local to_delete = {}
		for i = 1, #workspaces do
			local n = 1 + #workspaces - i
			if wsrows[n]:getcheck() then
				table.insert(to_delete, n)
			end
		end
		-- Backwards traversal to ensure indices are correct.
		for _, n in ipairs(to_delete) do
			wslist:remove(wsrows[n].arow)
			table.remove(wsrows, n)
			table.remove(workspaces, n)
		end
		write_workspaces(workspaces)
		selectbtn.active = false
	end
	function newbtn:on_clicked()
		local dialog = create_file_dialog(
			os.getenv "PWD",
			"Open New Workspace",
			window,
			"SELECT_FOLDER",
			"Open",
			"Cancel")
		function dialog:on_response(id)
			if id ~= Gtk.ResponseType.ACCEPT then return end
			local f = dialog:get_file()
			local path = f:get_path()
			cb(path)
			local idx
			for n, ws in ipairs(workspaces) do
				if path == ws then
					table.remove(workspaces, n)
					break
				end
			end
			table.insert(workspaces, 1, path)
			write_workspaces(workspaces)
			workspace_selector_window:close()
			workspace_selector_window = nil
		end
		dialog:show()
	end
	local header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle.new("Cheveret", "Select Workspace"),
	}
	if #workspaces > 0 then
		newbtn:add_css_class "suggested-action"
		newbtn.child = Adw.ButtonContent {
			icon_name = "list-add-symbolic",
			label = "New",
		}
		wslist.header_suffix = newbtn
		contents:append(wslist)
		header:pack_end(selectbtn)
	else
		newbtn.halign = "CENTER"
		newbtn.valign = "CENTER"
		newbtn:add_css_class "pill"
		newbtn:add_css_class "suggested-action"
		newbtn.child = nil
		newbtn.label = "New Workspace…"
		workspace_selector_window.height_request = 300
		contents = newbtn
	end
	local scrolled = Gtk.ScrolledWindow {
		vexpand = true,
		child = Adw.Clamp {
			child = contents,
			maximum_size = 500,
		},
	}
	scrolled:add_css_class "undershoot-top"
	scrolled:add_css_class "undershoot-bottom"
	local tbview = Adw.ToolbarView {
		content = scrolled,
	}
	tbview:add_top_bar(header)
	workspace_selector_window.content = tbview
	workspace_selector_window:present()
end

-- File Row --

-- FIXME: Keep a list of file rows by path in a tree, come up with a depth-first alphabetical ordering, then add/remove listbox rows in order when inotify adds/removes files.

local filerow = {}
local filerow_mt = { __index = filerow }
local watchopts = inotify.IN_CREATE | inotify.IN_DELETE | inotify.IN_MOVE | inotify.IN_DELETE_SELF | inotify.IN_MOVE_SELF
local watch_paths = {}
local rows_by_path = {}
local rows_by_row = {}

function filerow_mt.__gc(self)
	if self.watchid then in_handle:rmwatch(self.watchid) end
end

function filerow:open()
	if self.kind == "file" then
		open_file(self.path)
	elseif self.kind == "binary" then
		local opencmd = ("xdg-open '%s'"):format(self:getname())
		lib.forkcdexec(self:getdir(), opencmd)
	elseif self.kind == "directory" then
		if self.opened then
			self.opened = false
			for c in self:iterchildren() do
				if c.kind == "directory" then
					c.opened = false
					c:update()
				end
			end
		else
			self.opened = true
		end
	end
	self:update()
end

function filerow:getdir()
	-- string.match() is guaranteed to return the longest possible match, so this pattern matches up to the last slash and captures everything leading up to it.
	local dir = self.path:match "^(.*)/"
	return dir
end

function filerow:getname()
	return self.path:match "[^/]+$"
end

function filerow:iterchildren()
	return coroutine.wrap(function()
		for _, d in pairs(self.cdirs) do
			coroutine.yield(d)
		end
		for _, f in pairs(self.cfiles) do
			coroutine.yield(f)
		end
	end)
end

function filerow:refresh()
	if self.kind == "file" or self.kind == "binary" then
		if lib.file_is_binary(io.open(self.path)) then
			self.kind = "binary"
		else
			self.kind = "file"
		end
	end
	self:update()
end

function filerow:update()
	if self.kind == "root" then return end
	self.label.label = self:getname()
	self.lbr.tooltip_text = self.label.label
	if self.kind == "file" then
		self.icon.icon_name = "emblem-documents-symbolic"
	elseif self.kind == "binary" then
		self.icon.icon_name = "application-x-executable-symbolic"
	elseif self.kind == "directory" then
		for c in self:iterchildren() do
			c.lbr:set_visible(self.opened)
		end
		if self.opened then
			self.icon.icon_name = "folder-open-symbolic"
		else
			self.icon.icon_name = "folder-symbolic"
		end
	end
end

function filerow:getlastindex()
	if #self.cfiles > 0 then
		return self.cfiles[#self.cfiles].lbr:get_index()
	elseif #self.cdirs > 0 then
		return self.cdirs[#self.cdirs]:getlastindex()
	else
		return self.lbr:get_index()
	end
end

function filerow:append(child)
	local cname = child:getname()
	local t
	if self.opened then child.lbr:set_visible(true) end
	if child.kind == "directory" then
		t = self.cdirs
	elseif child.kind == "file" then
		t = self.cfiles
	end
	if #t == 0 and child.kind == "directory" then
		-- There are no subdirectories, so always insert the child just below this row.
		local index = self.lbr:get_index()
		self.lbr.parent:insert(child.lbr, index + 1)
		table.insert(t, child)
		return
	elseif #t == 0 and child.kind == "file" then
		-- Insert the child below the last item in all subdirectories.
		local index = self:getlastindex()
		self.lbr.parent:insert(child.lbr, index + 1)
		table.insert(t, child)
		return
	end
	-- Insert sorted.
	for i, v in ipairs(t) do
		local vname = v:getname()
		if cname < vname then
			local index = v.lbr:get_index()
			v.lbr.parent:insert(child.lbr, index)
			table.insert(t, i, child)
			return
		end
	end
	-- If no insert, add to the end.
	local index = t[#t]:getlastindex()
	self.lbr.parent:insert(child.lbr, index + 1)
	table.insert(t, child)
end

function filerow:deletechild(name)
	for i, v in ipairs(self.cdirs) do
		if name == v:getname() then
			table.remove(self.cdirs, i)
			return
		end
	end
	for i, v in ipairs(self.cfiles) do
		if name == v:getname() then
			table.remove(self.cfiles, i)
			return
		end
	end
end

function filerow:delete()
	self.lbr.parent:remove(self.lbr)
end

function filerow:set_visible(value)
	self.lbr:set_visible(value)
end

function filerow:set_hidden(value)
	self.hidden = value
end

local callbacks_by_filerow = {}

function new_filerow(path, kind, depth)
	local icon = Gtk.Image.new_from_icon_name ""
	local label = Gtk.Label {
		ellipsize = "END",
	}
	local box = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
		margin_start = math.max(0, 18 * depth),
	}
	box:append(icon)
	box:append(label)
	local lbr = Gtk.ListBoxRow {
		child = box,
		visible = depth == 0 and kind ~= "root",
	}
	local r = setmetatable({
		path = path,
		kind = kind,
		depth = depth,
		cdirs = {},
		cfiles = {},
		lbr = lbr,
		icon = icon,
		label = label,
		opened = false,
		hidden = false,
	}, filerow_mt)
	callbacks_by_filerow[lbr] = function() r:open() end
	rows_by_row[lbr] = r
	function lbr:on_map() r:refresh() end
	return r
end

local function populate_filerow_tree(params)
	coroutine.yield(true)
	local directories = {}
	local files = {}
	local in_id = params.in_handle:fileno()
	local watchid = params.in_handle:addwatch(params.path, watchopts)
	watch_paths[in_id][watchid] = params.path
	for file in lfs.dir(params.path) do
		if file ~= "." and file ~= ".." then
			local f = params.path .. "/" .. file
			local attrs = lfs.symlinkattributes(f)
			assert(type(attrs) == "table")
			if attrs.mode == "directory" and file:sub(1, 1) ~= "." then
				table.insert(directories, f)
			elseif attrs.mode == "file" then
				table.insert(files, f)
			end
		end
	end
	table.sort(directories)
	for _, directory in ipairs(directories) do
		local row = new_filerow(directory, "directory", params.depth)
		rows_by_path[in_id][directory] = row
		params.parent:append(row)
		populate_filerow_tree {
			path = directory,
			parent = row,
			depth = params.depth + 1,
			in_handle = params.in_handle,
		}
	end
	table.sort(files)
	for _, file in ipairs(files) do
		local row = new_filerow(file, "file", params.depth)
		rows_by_path[in_id][file] = row
		params.parent:append(row)
	end
end

local function create_file_pane(dir)
	local box = Gtk.ListBox()
	box:add_css_class "navigation-sidebar"
	local in_handle = inotify.init { blocking = false }
	local in_id = in_handle:fileno()
	watch_paths[in_id] = {}
	rows_by_path[in_id] = {}
	local root = new_filerow(dir, "root", -1)
	rows_by_path[in_id][dir] = root
	box:append(root.lbr)
	-- Populate the file list gradually to prevent the app from stalling when opening a new workspace.
	GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1, coroutine.create(function()
		populate_filerow_tree {
			path = dir,
			parent = root,
			depth = 0,
			in_handle = in_handle,
		}
		return false
	end))
	function box:on_row_activated(row)
		callbacks_by_filerow[row]()
	end
	local scrolled = Gtk.ScrolledWindow {
		child = box,
		hscrollbar_policy = "NEVER",
		vexpand = true,
	}
	scrolled:add_css_class "undershoot-top"
	return scrolled, box, in_handle
end

local function handle_inotify()
	for wk in pairs(window_widgets) do
		local in_handle = window_widgets[wk].in_handle
		local in_id = in_handle:fileno()
		for evt, err in in_handle:events() do
			if not evt then
				lerror("error when processing inotify", err)
				break
			end
			local dirpath = watch_paths[in_id][evt.wd]
			local filepath = dirpath
			if evt.name then filepath = dirpath .. "/" .. evt.name end
			if (evt.mask & (inotify.IN_CREATE | inotify.IN_MOVED_TO)) ~= 0 then
				local attrs = lfs.symlinkattributes(filepath)
				local file_name = filepath:match "([^/]+)/?$"
				if type(attrs) ~= "table" then attrs = {} end
				if attrs.mode == "directory" and file_name:sub(1, 1) ~= "." then
					local prow = rows_by_path[in_id][dirpath]
					local row = new_filerow(filepath, "directory", prow.depth + 1)
					prow:append(row)
					rows_by_path[in_id][filepath] = row
					populate_filerow_tree {
						path = filepath,
						parent = row,
						depth = row.depth + 1,
						in_handle = in_handle,
					}
				elseif attrs.mode == "file" then
					local prow = rows_by_path[in_id][dirpath]
					local row = new_filerow(filepath, "file", prow.depth + 1)
					prow:append(row)
					rows_by_path[in_id][filepath] = row
				end
			elseif (evt.mask & (inotify.IN_DELETE | inotify.IN_MOVED_FROM)) ~= 0 then
				local row = rows_by_path[in_id][filepath]
				-- If the row doesn't exist, it's because the deleted file was a symlink.
				if not row then return end
				row:delete()
				local parent = rows_by_path[in_id][dirpath]
				parent:deletechild(evt.name)
			elseif (evt.mask & (inotify.IN_DELETE_SELF | inotify.IN_MOVE_SELF)) ~= 0 then
				in_handle:rmwatch(evt.wd)
				watch_paths[in_id][evt.wd] = nil
			end
		end
	end
end
GLib.timeout_add(GLib.PRIORITY_DEFAULT, 10, coroutine.create(function()
	repeat
		local successful, r = pcall(handle_inotify)
		if not successful then
			error(r)
		end
		coroutine.yield(true)
	until false
end))

-- Main Workspace Window --

local save_menu = Gio.Menu()
save_menu:append("Save", "win.save_file")
local file_menu = Gio.Menu()
file_menu:append("New Window", "win.open_workspace")
file_menu:append("New Workspace…", "win.open_new_workspace")
file_menu:append("Open Workspace Folder", "win.project_dir")
local app_menu = Gio.Menu()
app_menu:append("Keyboard Shortcuts", "win.shortcuts")
app_menu:append("About Cheveret", "win.about")
local burger_menu = Gio.Menu()
burger_menu:append_section(nil, save_menu)
burger_menu:append_section(nil, file_menu)
burger_menu:append_section(nil, app_menu)

local function newshortwindow(parent)
	local editorgroup = Gtk.ShortcutsGroup {
		title = "Editor",
	}
	editorgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.save_file",
		title = "Save",
		accelerator = "<Ctrl>S",
	})
	editorgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.search",
		title = "Search in file",
		accelerator = "<Ctrl>F",
	})
	editorgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.goto",
		title = "Go to line",
		accelerator = "<Ctrl>I",
	})
	editorgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.close_tab",
		title = "Close tab",
		accelerator = "<Ctrl>W",
	})
	local miscgroup = Gtk.ShortcutsGroup {
		title = "Application",
	}
	miscgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.open_workspace",
		title = "New window here",
		accelerator = "<Ctrl>N",
	})
	miscgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.open_new_workspace",
		title = "New window elsewhere",
		accelerator = "<Ctrl><Shift>N",
	})
	miscgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.project_dir",
		title = "View workspace folder",
		accelerator = "<Ctrl>P",
	})
	miscgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.shortcuts",
		title = "Keyboard shortcuts",
		accelerator = "<Ctrl><Shift>slash",
	})
	local shortsection = Gtk.ShortcutsSection {
		title = "Cheveret",
	}
	shortsection:add_group(editorgroup)
	shortsection:add_group(miscgroup)
	shortcutwin = Gtk.ShortcutsWindow()
	shortcutwin:add_section(shortsection)
	shortcutwin.transient_for = parent
	shortcutwin.modal = true
	shortcutwin.application = app
	return shortcutwin
end

local function window_new_action(win, name, cb)
	local action = Gio.SimpleAction.new(name)
	action.enabled = true
	action.on_activate = cb
	win:add_action(action)
end

-- Creates a new window and returns its inner TabView.
-- The TabView is returned for ease of creating new windows by dragging tabs off of an existing window.
local function new_window(pwd)
	local sidebar_header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle.new("Cheveret", lib.encode_path(pwd)),
		show_end_title_buttons = false,
		valign = "START",
	}

	local filepane, listbox, in_handle = create_file_pane(pwd)

	local sidebar = Adw.ToolbarView {
		content = filepane,
		top_bar_style = "FLAT",
	}
	sidebar:add_top_bar(sidebar_header)

	local menu_button = Gtk.MenuButton {
		direction = "DOWN",
		halign = "END",
		icon_name = "open-menu-symbolic",
		menu_model = burger_menu,
	}

	local sidebar_toggle_button = Gtk.ToggleButton {
		icon_name = "sidebar-show-symbolic",
		active = true,
	}

	local content_header = Adw.HeaderBar {
		title_widget = Adw.WindowTitle.new("Cheveret", ""),
		show_start_title_buttons = false,
		valign = "START",
	}
	content_header:pack_start(sidebar_toggle_button)
	content_header:pack_end(menu_button)

	-- FIXME: Prevent detachment of tabs.
	local tab_view = Adw.TabView {
		hexpand = true,
		vexpand = true,
	}
	function tab_view:on_create_window() return self end

	local tab_bar = Adw.TabBar {
		autohide = true,
		view = tab_view,
		valign = "START",
	}

	local content = Adw.ToolbarView {
		content = tab_view,
		top_bar_style = "FLAT",
	}
	content:add_top_bar(content_header)
	content:add_top_bar(tab_bar)

	local mainview = Adw.OverlaySplitView {
		sidebar = sidebar,
		content = content,
		min_sidebar_width = 200,
		max_sidebar_width = 500,
		sidebar_width_fraction = .3,
	}
	local function toggle_sidebar()
		mainview.show_sidebar = not mainview.show_sidebar
		sidebar_toggle_button.active = mainview.show_sidebar
	end
	function sidebar_toggle_button:on_clicked() toggle_sidebar() end

	local window = Adw.ApplicationWindow.new(app)
	window.content = mainview
	window.title = ("Cheveret — %s"):format(lib.encode_path(pwd))
	window:set_default_size(900, 600)

	function tab_view:on_page_attached(page)
		local e = editors_by_view[page.child]
		if not e then return end
		content.top_bar_style = "RAISED_BORDER"
		function e:set_title(title, subtitle)
			if type(title) ~= "string" then title = "No Name" end
			if type(subtitle) ~= "string" then subtitle = "" end
			page.title = title
			if tab_view.selected_page == page then
				content_header.title_widget:set_title(title)
				content_header.title_widget:set_subtitle(subtitle)
			end
		end
		function e:grab_focus()
			tab_view:set_selected_page(page)
			e.tv:grab_focus()
		end
		-- Force set here, because the tab view's selected_page won't be set in time for this call.
		local title, subtitle = e:get_title()
		page.title = title
		content_header.title_widget:set_title(title)
		content_header.title_widget:set_subtitle(subtitle)
	end
	function tab_view:on_page_detached(page)
		local e = editors_by_view[page.child]
		if not e then return end
		-- This will be reset once the page is reattached.
		function e:set_title() end
	end
	function tab_view:on_close_page(page)
		local e = editors_by_view[page.child]
		local do_close = true
		local reason
		if type(e.can_close) == "function" then
			do_close, reason = e:can_close()
		end
		self:close_page_finish(page, do_close)
		if not do_close then
			local body = ("The file \"%s\" has unsaved changes."):format(e:get_file_name())
			local dlg = Adw.AlertDialog.new("Save changes?", body)
			dlg:add_response("close", "Keep open")
			dlg:set_response_appearance("close", Adw.ResponseAppearance.DEFAULT)
			dlg:add_response("discard", "Close without saving")
			dlg:set_response_appearance("discard", Adw.ResponseAppearance.DESTRUCTIVE)
			dlg:add_response("save", "Save and close")
			dlg:set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED)
			function dlg:on_response(response)
				if response == "discard" then
					e.tv.buffer:set_modified(false)
					tab_view:close_page(page)
				elseif response == "save" then
					e:save()
					tab_view:close_page(page)
				end
			end
			dlg:choose(app.active_window)
		else
			editors_by_view[page.child] = nil
			local path = e:get_file_path()
			if path then editors_by_path[path] = nil end
			if self:get_n_pages() == 0 then
				content_header.title_widget:set_title "Cheveret"
				content_header.title_widget:set_subtitle ""
				content.top_bar_style = "FLAT"
			end
		end
		return true
	end

	window_widgets[window] = {
		filepane = filepane,
		tab_view = tab_view,
		in_handle = in_handle,
	}
	function window:on_close_request()
		local n_pages = tab_view:get_n_pages()
		local unsaved = {}
		for i = 1, n_pages do
			local page = tab_view:get_nth_page(n_pages - i)
			local e = editors_by_view[page.child]
			if not e:can_close() then
				table.insert(unsaved, e)
			end
		end
		if #unsaved > 0 then
			local dlg = Adw.AlertDialog.new("Save changes?", "Some of your work is unsaved.")
			dlg:add_response("close", "Keep open")
			dlg:set_response_appearance("close", Adw.ResponseAppearance.DEFAULT)
			dlg:add_response("discard", "Discard all changes")
			dlg:set_response_appearance("discard", Adw.ResponseAppearance.DESTRUCTIVE)
			dlg:add_response("save", "Save all and close workspace")
			dlg:set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED)
			function dlg:on_response(response)
				if response == "save" then
					for _, e in ipairs(unsaved) do e:save() end
					window:close()
				elseif response == "discard" then
					for _, e in ipairs(unsaved) do e.tv.buffer:set_modified(false) end
					window:close()
				end
			end
			dlg:choose(self)
			return true
		else
			window_widgets[self] = nil
			-- Explicitly close each editor page to free their resources. Better than hooking into __gc or something similar.
			for i = 1, n_pages do
				local page = tab_view:get_nth_page(n_pages - i)
				tab_view:close_page(page)
			end
			return false
		end
	end

	window_new_action(window, "close_tab", function()
		local page = tab_view.selected_page
		if not page then return true end
		tab_view:close_page(page)
	end)

	window_new_action(window, "save_file", function()
		local e = get_focused_editor()
		if e:has_file() then
			e:save()
		else
			save_file_dialog(e)
		end
	end)

	window_new_action(window, "search", function()
		local e = get_focused_editor()
		e:begin_search()
	end)

	window_new_action(window, "goto", function()
		local e = get_focused_editor()
		e:begin_jump()
	end)

	window_new_action(window, "toggle_sidebar", function()
		toggle_sidebar()
	end)

	window_new_action(window, "open_workspace", function()
		new_window(pwd):present()
	end)

	window_new_action(window, "open_new_workspace", function()
		select_workspace(function(dir)
			new_window(dir):present()
		end)
	end)

	window_new_action(window, "project_dir", function()
		lib.forkcdexec(pwd, "/usr/bin/xdg-open .")
	end)

	window_new_action(window, "shortcuts", function()
		local shortcutwin = newshortwindow(window)
		shortcutwin:present()
	end)

	window_new_action(window, "about", function()
		aboutdlg:present(window)
	end)

	if is_devel then window:add_css_class "devel" end
	return window
end

-- Text Editor --

local function buffer_read_file(buffer, file_path)
	local dir = lib.dir_and_file(file_path)
	assert(lib.is_dir(dir))
	buffer:begin_irreversible_action()
	buffer:delete(buffer:get_start_iter(), buffer:get_end_iter())
	local hdl = io.open(lib.decode_path(file_path), "r")
	if hdl then
		for line in hdl:lines() do
			if line:match "\0" then
				buffer:end_irreversible_action()
				return fail
			end
			line = line:gsub("%s*$", "\n")
			buffer:insert(buffer:get_end_iter(), line, #line)
		end
		-- Remove trailing newlines, so the last line of the file is the last line of the buffer.
		buffer.text = (buffer.text:match ".*[^\n]") or ""
	end
	buffer:set_modified(false)
	buffer:end_irreversible_action()
	return true
end

local function buffer_write_file(buffer, file_path)
	local errmsg
	local file = io.open(file_path, "w")
	local text = buffer.text:match ".*[^\n]"
	for line in text:gmatch "[^\n]*" do
		line = line:gsub("%s*$", "\n")
		file:write(line)
	end
	if not err then
		_, err = file:flush()
	end
	if not err then
		buffer:set_modified(false)
	end
	file:close()
	return err
end

--[[
Unless otherwise stated, this editor uses 1-indexing for the functions it defines.
Line 1 is the first line of the file.
Char 1 is the first char of a line.
…etc…
--]]

function editor:get_insert()
	return self.tv.buffer:get_insert()
end
function editor:get_bound()
	return self.tv.buffer:get_selection_bound()
end
function editor:get_iters()
	local first = self.tv.buffer:get_iter_at_mark(self:get_bound())
	local second = self.tv.buffer:get_iter_at_mark(self:get_insert())
	first:order(second)
	return first, second
end
function editor:set_iters(first, second)
	assert(first, second)
	first:order(second)
	-- Yes, this is how TextBuffer:select_range() works.
	self.tv.buffer:select_range(second, first)
end

function editor:scroll_to_selection()
	self.tv:scroll_to_mark(self:get_bound(), 0.0, false, 0.0, 0.0)
	self.tv:scroll_to_mark(self:get_insert(), 0.2, false, 0.0, 0.0)
end
function editor:select_range(range_start, range_end)
	assert(type(range_start) == "number")
	assert(type(range_end) == "number")
	local first = self.tv.buffer:get_start_iter()
	first:forward_chars(range_start - 1)
	local second = self.tv.buffer:get_start_iter()
	second:forward_chars(range_end - 1)
	self:set_iters(first, second)
end
function editor:select_lines(addr1, addr2)
	assert(type(addr1) == "number")
	if type(addr2) ~= "number" then addr2 = addr1 end
	local lines = self.tv.buffer:get_line_count()
	if addr1 > lines or addr2 > lines then return end
	local first = self.tv.buffer:get_iter_at_line(addr1 - 1)
	local second = self.tv.buffer:get_iter_at_line(addr2 - 1)
	first:order(second)
	second:forward_line()
	self:set_iters(first, second)
end
function editor:select_last_line()
	local last = self.tv.buffer:get_line_count()
	self:select_lines(last, last)
	self:scroll_to_selection()
end
function editor:deselect()
	local _, second = self:get_iters()
	self:set_iters(second, second)
end
function editor:select_all()
	local head = self.tv.buffer:get_start_iter()
	local tail = self.tv.buffer:get_end_iter()
	self:set_iters(head, tail)
end
function editor:selection_extend()
	local first, second = self:get_iters()
	first:set_line_offset(0)
	if not second:starts_line() then
		second:forward_line()
	end
	self:set_iters(first, second)
end
function editor:selection_get()
	local first, second = self:get_iters()
	return first:get_slice(second)
end
function editor:selection_delete()
	self.tv.buffer:delete(self:get_iters())
end
function editor:selection_prepend(str)
	assert(type(str) == "string")
	local first, _ = self:get_iters()
	self.tv.buffer:insert(first, str, #str)
	first = self.tv.buffer:get_iter_at_offset(first:get_offset() - utf8.len(str))
	local _, second = self:get_iters()
	self:set_iters(first, second)
end
function editor:selection_append(str)
	assert(type(str) == "string")
	local first, second = self:get_iters()
	local firstoff = first:get_offset()
	self.tv.buffer:insert(second, str, #str)
	first = self.tv.buffer:get_iter_at_offset(firstoff)
	self:set_iters(first, second)
end
function editor:selection_replace(str)
	assert(type(str) == "string")
	local first, second = self:get_iters()
	self.tv.buffer:delete(first, second)
	local offset = second:get_offset()
	self.tv.buffer:insert(second, str, #str)
	first = self.tv.buffer:get_iter_at_offset(offet)
	self:set_iters(first, second)
end
function editor:selecton_wrap(str)
	assert(type(str) == "string")
	self:selection_prepend(str)
	self:selection_append(str)
end

function editor:can_close()
	return not self.tv.buffer:get_modified()
end
function editor:get_title()
	local name = self.file_name or "New File"
	local modified = ""
	if self.tv.buffer:get_modified() then modified = "* " end
	local title = modified .. name
	local subtitle = ""
	if self.file_dir then subtitle = lib.encode_path(self.file_dir) end
	return title, subtitle
end
function editor:update_title()
	if type(self.set_title) == "function" then
		self:set_title(self:get_title())
	end
end

function editor:get_file_dir()
	if not self.file_dir and self.file_name then return "/" end
	return self.file_dir
end
function editor:get_file_name()
	return self.file_name
end
function editor:has_file()
	return self.file_dir and self.file_name
end
function editor:get_file_path()
	if not self.file_dir and self.file_name then
		return "/" .. self.file_name
	end
	if not self.file_dir or not self.file_name then return end
	return self.file_dir .. "/" .. self.file_name
end
function editor:set_file_path(path)
	local oldpath = self:get_file_path()
	assert(path and type(path) == "string")
	assert(not lib.is_dir(path))
	local abspath = lib.absolute_path(path)
	if oldpath == abspath then return end
	if editors_by_path[abspath] then
		return
	end
	if oldpath then editors_by_path[oldpath] = nil end
	local dir, name = lib.dir_and_file(path)
	assert(lib.is_dir(dir))
	self.file_dir = dir; self.file_name = name
	editors_by_path[abspath] = self
	self:update_title()
end

function editor:edit_file(path)
	if self.tv.buffer:get_modified() then
		return
	end
	assert(type(path) == "string")
	self:set_file_path(path)
	buffer_read_file(self.tv.buffer, self:get_file_path())
end
function editor:discard_changes()
	local path = self:get_file_path()
	if not path then
		self.tv.buffer.text = ""
		self.tv.buffer:set_modified(false)
	else
		self.tv.buffer:set_modified(false)
		self:edit_file(path)
	end
end
function editor:save(path)
	if path then self:set_file_path(path) end
	assert(self.file_dir and self.file_name)
	local err = buffer_write_file(self.tv.buffer, self:get_file_path())
	if err then error(err) end
	self:update_title()
end

function editor:go_to(line)
	local lines = self.tv.buffer:get_line_count()
	assert(line >= 1 and line <= lines)
	self:select_lines(line)
	self:scroll_to_selection()
end

function editor:begin_search()
	if not self.search.bar.search_mode_enabled and self.tv.buffer:get_has_selection() then
		self.search.entry.text = self:selection_get()
	end
	self.jump.bar.search_mode_enabled = false
	self.search.bar.search_mode_enabled = true
	self.search.entry:grab_focus()
end

function editor:update_matches(total, match)
	if type(match) == "number" and type(total) == "number" then
		self.search.matchnum.label = ("%d of %d"):format(match, total)
	elseif type(total) == "number" then
		self.search.matchnum.label = ("%d"):format(total)
	elseif type(total) == "string" then
		self.search.matchnum.label = total
	else
		self.search.matchnum.label = ""
	end
end

-- Lua is excellent at processing long strings, so this should be pretty fast.
function editor:findall(pattern, plain)
	if #pattern < 3 then
		self:update_matches()
		return
	end
	local byte_indices = {}
	local text = self.tv.buffer.text
	local len = #text
	local init = 1
	while init <= len do
		local i, j = text:find(pattern, init, plain)
		if not i or not j then break end
		table.insert(byte_indices, { i, j })
		init = j + 1
	end
	self.matches = {}
	local utf_total = 0
	init = 1
	for _, t in ipairs(byte_indices) do
		local i = t[1]
		local j = t[2]
		local ulen1 = utf8.len(text, init, i, true)
		local ulen2 = utf8.len(text, i, j, true)
		assert(ulen1 and ulen2)
		ulen1 = utf_total + ulen1
		utf_total = ulen1
		ulen2 = utf_total + ulen2
		utf_total = ulen2 - 1
		table.insert(self.matches, { ulen1, ulen2 })
		init = j + 1
	end
	if not #self.matches then
		self:update_matches "no match"
	end
	self:update_matches(#self.matches)
end

function editor:next_match(...)
	self:findall(...)
	if #self.matches == 0 then return end
	local _, start_iter = self:get_iters()
	local cursor_pos = start_iter:get_offset()
	for i, m in ipairs(self.matches) do
		if m[1] > cursor_pos then
			self:select_range(m[1], m[2])
			self:scroll_to_selection()
			self:update_matches(#self.matches, i)
			return
		end
	end
	-- Wrap to start
	self:select_range(self.matches[1][1], self.matches[1][2])
	self:scroll_to_selection()
	self:update_matches(#self.matches, 1)
end

function editor:prev_match(...)
	self:findall(...)
	if #self.matches == 0 then return end
	local start_iter, _ = self:get_iters()
	local cursor_pos = start_iter:get_offset()
	for i = 1, #self.matches do
		local idx = #self.matches - i + 1
		local m = self.matches[idx]
		if cursor_pos > m[2] then
			self:select_range(m[1], m[2])
			self:scroll_to_selection()
			self:update_matches(#self.matches, idx)
			return
		end
	end
	local m = self.matches[#self.matches]
	self:select_range(m[1], m[2])
	self:scroll_to_selection()
	self:update_matches(#self.matches, #self.matches)
end

function editor:begin_jump()
	self.search.bar.search_mode_enabled = false
	self.jump.bar.search_mode_enabled = true
	self.jump.entry:grab_focus()
end

-- Application Features --

function app:on_activate()
	if app.active_window then app.active_window:present() end
end

function app:on_startup()
	select_workspace(function(dir) new_window(dir):present() end)
end

return app:run()
