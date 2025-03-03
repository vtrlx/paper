--[[ parchment.lua (text editing application that feels like parchment)
Copyright © 2024–2025 Victoria Lacroix

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <https://www.gnu.org/licenses/>. ]]--

-- This app runs in Flatpak, which puts Lua libraries outside of the standard paths. These lines tell Lua to look for libraries where Flatpak has put them.
package.cpath = "/app/lib/lua/5.4/?.so;" .. package.cpath
package.path = "/app/share/lua/5.4/?.lua;" .. package.path

--[[
SECTION: Support library
]]--

local lfs = require "lfs"
local lib = require "parchmentlib"

function lib.get_home_directory()
	return os.getenv "HOME"
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
	if full_path:sub(1, 1) ~= "/" then dir = lib.get_home_directory() end
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
	while file_path:sub(last + 1):find "/" do
		last = last + (file_path:sub(last + 1):find "/")
	end
	return file_path:sub(1, last - 1), file_path:sub(last + 1)
end

function lib.file_exists(file_name)
	file_name = lib.absolute_path(file_name)
	local ok, err, code = os.rename(file_name, file_name)
	if not ok then
		-- In Linux, error code 13 when moving a file means the it failed because the directory cannot be made its own child. Any other error means the file does not exist.
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

-- Iterates all lines in a file handle, returning true if the file contains any NUL characters and false otherwise. The file handle is then seeked back to the beginning for further reading.
function lib.file_is_binary(hdl)
	local is_binary = false
	for line in hdl:lines() do
		if line:match "\0" then
			is_binary = true
			break
		end
	end
	hdl:seek "set"
	return is_binary
end

function lib.escapepattern(str)
	-- Lua's string.gmatch function does not have a plain option. This takes input strings and returns their pattern equivalent, allowing string.gmatch to work as though it didn't match patterns.
	return str:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
end

function lib.escaperepl(str)
	-- In order to prevent replacement strings from being treated like replacement patterns, all % characters simply need to be escaped by doubling them.
	return str:gsub("%%", "%%%%")
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
SECTION: Main application
]]--

local lgi = require "lgi"

local GLib = lgi.require "GLib"
local Gio = lgi.require "Gio"
local Adw = lgi.require "Adw"
local Gtk = lgi.require "Gtk"
local Gdk = lgi.require "Gdk"

local Parchment = lgi.package "Parchment"

local app_id = lib.get_app_id()
local is_devel = lib.get_is_devel()
local app_title = "Parchment"
local app_version = lib.get_app_ver()
local app  = Adw.Application {
	application_id = app_id,
	flags = "HANDLES_OPEN",
}

-- Shortcuts from the GNOME HIG (https://developer.gnome.org/hig/reference/keyboard.html)
local accels = {
	["win.close_tab"] = { "<Ctrl>W" },
	["win.open_file"] = { "<Ctrl>O" },
	["win.open_folder"] = { "<Ctrl>D" },
	["win.new_file"] = { "<Ctrl>T" },
	["win.save_file"] = { "<Ctrl>S" },
	["win.save_file_as"] = { "<Ctrl><Shift>S" },
	["win.search"] = { "<Ctrl>F" },
	["win.goto"] = { "<Ctrl>I" },
	["win.new_window"] = {"<Ctrl>N" },
	["win.shortcuts"] = { "<Ctrl><Shift>question" },
}
for k, v in pairs(accels) do
	app:set_accels_for_action(k, v)
end

local lerror = error
local function error(...)
	local msg = table.concat({ ... }, " ")
	local dlg = Adw.AlertDialog.new("Error", msg)
	dlg:add_response("cancel", "Continue")
	dlg:choose()
	-- Call Lua's builtin error() function so this new one has the same semantics of unwinding the call stack.
	lerror(...)
end

--[[
SECTION: Layout management
GTK widgets do not provide signals for when they've resized. Instead, one is supposed to use a Layout Manager to handle this. Because the Layout Manager needs to be of a specific class, this will subclass it.
]]--

Parchment:class("EditorLayoutManager", Gtk.LayoutManager)

function Parchment.EditorLayoutManager:do_allocate(widget, width, height, baseline)
	local minmargin = 24
	local maxwidth = 640
	local maxinner = maxwidth - minmargin * 2
	local totalmargin = math.max(minmargin, (width - maxinner) / 2)
	-- In case of the margin space being an odd number, the extra pixel gets assigned to the right side.
	widget.left_margin = math.floor(totalmargin)
	widget.right_margin = math.ceil(totalmargin)
	-- Allow some overscroll at the bottom of the file, but never enough such that all text can be scrolled out of view.
	widget.bottom_margin = math.floor(height * 0.6)
	Gtk.TextView.do_size_allocate(widget, width, height, baseline)
end

--[[
SECTION: Text editor constructor
]]--

-- Holds the data for open files.
local editors = {}
local window_widgets = {}

local editor = newclass(function(self)
	local searchimg = Gtk.Image { icon_name = "system-search-symbolic" }
	local search_entry = Gtk.Text {
		placeholder_text = "Find in file…",
		hexpand = true,
	}
	local matchnum_label = Gtk.Label {
		margin_start = 18,
		margin_end = 6,
		halign = "END",
		hexpand = false,
	}
	matchnum_label:add_css_class "numeric"
	local sbox = Gtk.Box {
		orientation = "HORIZONTAL",
		css_name = "entry",
	}
	sbox:append(searchimg)
	sbox:append(search_entry)
	sbox:append(matchnum_label)
	local prev_match = Gtk.Button.new_from_icon_name "go-up-symbolic"
	local next_match = Gtk.Button.new_from_icon_name "go-down-symbolic"
	local search_box = Gtk.Box {
		orientation = "HORIZONTAL",
	}
	search_box:add_css_class "linked"
	search_box:append(sbox)
	search_box:append(prev_match)
	search_box:append(next_match)
	local replace_entry = Gtk.Entry {
		placeholder_text = "Replace with…",
		hexpand = true,
	}
	local replace_button = Gtk.Button.new_with_label "Replace"
	replace_button.tooltip_text = "Replaces selected text"
	replace_button.sensitive = false
	local replace_in_sel_button = Gtk.Button.new_with_label "Replace in selection"
	replace_in_sel_button.tooltip_text = "Replace all matches in selection"
	replace_in_sel_button.visible = false
	local replace_all_button = Gtk.Button.new_with_label "Replace all"
	replace_all_button.tooltip_text = "Replaces all matches in file"
	replace_all_button.sensitive = false
	local replace_box = Gtk.Box { orientation = "HORIZONTAL" }
	replace_box:add_css_class "linked"
	replace_box:append(replace_entry)
	replace_box:append(replace_button)
	replace_box:append(replace_in_sel_button)
	replace_box:append(replace_all_button)
	local search_bar_box = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 6,
	}
	search_bar_box:append(search_box)
	search_bar_box:append(replace_box)
	local search_bar_clamp = Adw.Clamp {
		orientation = "HORIZONTAL",
		child = search_bar_box,
		maximum_size = 480,
	}
	local search_bar = Gtk.SearchBar {
		child = search_bar_clamp,
		search_mode_enabled = false,
		show_close_button = true,
	}
	search_bar:connect_entry(search_entry)
	local text_view = Gtk.TextView {
		top_margin = 12,
		bottom_margin = 400,
		left_margin = 24,
		right_margin = 24,
		pixels_above_lines = 4,
		pixels_below_lines = 4,
		pixels_inside_wrap = 0,
		layout_manager = Parchment.EditorLayoutManager(),
		wrap_mode = Gtk.WrapMode.WORD_CHAR,
	}
	text_view:add_css_class "numeric"
	text_view.buffer:set_max_undo_levels(0)
	local scrolled_win = Gtk.ScrolledWindow {
		hscrollbar_policy = "NEVER",
		child = text_view,
		vexpand = true,
	}
	local box = Gtk.Box {
		orientation = "VERTICAL",
	}
	box:append(search_bar)
	box:append(scrolled_win)
	self.matches = {}
	self.search = {
		entry = search_entry,
		replentry = replace_entry,
		bar = search_bar,
		matchnum = matchnum_label,
	}
	self.tv = text_view
	self.scroll = scrolled_win
	self.widget = box
	function self.tv.buffer.on_modified_changed()
		self:update_title()
	end
	local function refresh_repl_buttons()
		if self:selection_has_match() and not self:match_selected() then
			replace_button.visible = false
			replace_in_sel_button.visible = true
			replace_all_button.visible = false
		else
			replace_button.visible = true
			replace_in_sel_button.visible = false
			replace_all_button.visible = true
		end
		replace_button.sensitive = self:match_selected()
		replace_in_sel_button.sensitive = not self:match_selected() and self:selection_has_match()
		replace_all_button.sensitive = #self.matches > 0
		if search_entry.text == replace_entry.text then
			replace_button.sensitive = false
			replace_in_sel_button.sensitive = false
			replace_all_button.sensitive = false
		end
	end
	function self.tv.buffer.on_mark_set(iter, mark)
		refresh_repl_buttons()
	end
	local function dosearch()
		-- Skip searching if nothing is written.
		if #search_entry.text == 0 then
			matchnum_label.label = ""
			return
		end
		matchnum_label.label = self:findall(search_entry.text)
		refresh_repl_buttons()
	end
	local function prev()
		matchnum_label.label = self:prev_match(search_entry.text)
		refresh_repl_buttons()
	end
	local function next()
		matchnum_label.label = self:next_match(search_entry.text)
		refresh_repl_buttons()
	end
	local function repl()
		if not replace_button.sensitive then return end
		self:replace(replace_entry.text)
		matchnum_label.label = self:next_match(search_entry.text)
		refresh_repl_buttons()
	end
	local function replsel()
		self:replace_in_selection(search_entry.text, replace_entry.text)
		dosearch()
	end
	local function replall()
		matchnum_label.label = ""
		self:replace_all(search_entry.text, replace_entry.text)
		refresh_repl_buttons()
	end
	search_entry.buffer.on_notify.text = dosearch
	prev_match.on_clicked = prev
	next_match.on_clicked = next
	search_entry.on_activate = next
	replace_button.on_clicked = repl
	replace_in_sel_button.on_clicked = replsel
	replace_all_button.on_clicked = replall
end)

local function open_file(path)
	assert(app.active_window)
	local tab_view = window_widgets[app.active_window].tab_view
	assert(tab_view)
	if type(path) == "string" then
		path = lib.absolute_path(path)
		local e = editors[path]
		if e then
			e:grab_focus()
			return
		end
	end
	local e = editor()
	if type(path) == "string" then
		if not e:edit_file(path) then return end
		local iter = e.tv.buffer:get_start_iter()
		e.tv.buffer:select_range(iter, iter)
	end
	editors[e.widget] = e
	if path then editors[path] = e end
	local page = tab_view:add_page(e.widget)
	tab_view:set_selected_page(page)
end

local function get_focused_editor()
	assert(app.active_window)
	local tab_view = window_widgets[app.active_window].tab_view
	assert(tab_view)
	local page = tab_view.selected_page
	if not page then return nil end
	return editors[page.child]
end

--[[
SECTION: File Management
]]--

local file_dialog_path = lib.get_home_directory()
local filefilters = Gio.ListStore.new(Gtk.FileFilter)
filefilters:append(Gtk.FileFilter {
	name = "Text files",
	mime_types = { "text/*" },
})

local function open_file_dialog(window)
	local e = get_focused_editor()
	local dir = file_dialog_path
	if e and e:has_file() then
		local _, newdir, _ = e:get_path_info()
		dir = newdir
	end
	local file_dialog = Gtk.FileDialog {
		initial_folder = Gio.File.new_for_path(dir),
		filters = filefilters,
	}
	local cancellable = Gio.Cancellable {}
	function cancellable:on_cancelled()
		file_dialog:close()
	end
	local function on_open(src, res)
		local list = file_dialog:open_multiple_finish(res)
		if not list then return end
		for i = 1, list.n_items do
			-- Gio's API documents says that ListModel's :get_item() method is not available to language bindings and to use :get_object() instead. That's not the case for LGI, which binds :get_item() and returns the object itself instead of a pointer.
			local file = list:get_item(i - 1)
			if i == 1 then
				file_dialog_path = file:get_parent():get_path()
			end
			open_file(file:get_path())
		end
	end
	file_dialog:open_multiple(window, cancellable, on_open)
end

local function save_file_dialog(window, e)
	local dir = file_dialog_path
	if e:has_file() then
		local _, newdir, _ = e:get_path_info()
		dir = newdir
	end
	local file_dialog = Gtk.FileDialog {
		initial_folder = Gio.File.new_for_path(dir),
		filters = filefilters,
	}
	local cancellable = Gio.Cancellable {}
	function cancellable:on_cancelled()
		file_dialog:close()
	end
	local function on_save(src, res)
		local file = file_dialog:save_finish(res)
		if not file then return end
		local path = file:get_path()
		local dir, _ = lib.dir_and_file(path)
		file_dialog_path = dir
		e:save(path)
	end
	file_dialog:save(window, cancellable, on_save)
end

--[[
SECTION: Application menus
]]--

local file_menu = Gio.Menu()
file_menu:append("Save As…", "win.save_file_as")
local nav_menu = Gio.Menu()
nav_menu:append("Open File Location", "win.open_folder")
nav_menu:append("Find/Replace", "win.search")
nav_menu:append("Go to Line", "win.goto")
local app_menu = Gio.Menu()
app_menu:append("New Window", "win.new_window")
app_menu:append("Keyboard Shortcuts", "win.shortcuts")
app_menu:append("About " .. app_title, "win.about")
local burger_menu = Gio.Menu()
burger_menu:append_section(nil, file_menu)
burger_menu:append_section(nil, nav_menu)
burger_menu:append_section(nil, app_menu)

local function newshortwindow(parent)
	local editorgroup = Gtk.ShortcutsGroup {
		title = "Editor",
	}
	editorgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.open_file",
		title = "Open file",
		accelerator = "<Ctrl>O",
	})
	editorgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.open_folder",
		title = "Open file location",
		accelerator = "<Ctrl>D",
	})
	editorgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.save_file",
		title = "Save file",
		accelerator = "<Ctrl>S",
	})
	editorgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.save_file_as",
		title = "Save file as",
		accelerator = "<Ctrl><Shift>S",
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
		action_name = "win.new_tab",
		title = "New tab",
		accelerator = "<Ctrl>T",
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
		action_name = "win.new_window",
		title = "New window",
		accelerator = "<Ctrl>N",
	})
	miscgroup:add_shortcut(Gtk.ShortcutsShortcut {
		action_name = "win.shortcuts",
		title = "Keyboard shortcuts",
		accelerator = "<Ctrl><Shift>question",
	})

	local shortsection = Gtk.ShortcutsSection {
		title = app_title
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

local function about(parent)
	local aboutdlg = Adw.AboutDialog {
		application_icon = app_id,
		application_name = app_title,
		copyright = "© 2025 Victoria Lacroix",
		developer_name = "Victoria Lacroix",
		issue_url = "https://github.com/vtrlx/parchment/issues/new",
		license_type = "GPL_3_0",
		version = lib.get_app_ver(),
		website = "https://www.vtrlx.ca/apps/parchment/",
	}

	aboutdlg:add_link("Contact the Developer", "mailto:victoria@vtrlx.ca?subject=Parchment App")

	aboutdlg:add_acknowledgement_section("Application Name", {
		"Brage Fuglseth https://bragefuglseth.dev",
	})
	aboutdlg:add_acknowledgement_section("3rd Party Libraries", {
		"LuaFileSystem https://lunarmodules.github.io/luafilesystem/index.html",
	})

	aboutdlg:present(parent)
end

--[[
SECTION: Main application window
]]--

local function window_new_action(win, name, cb)
	local action = Gio.SimpleAction.new(name)
	action.enabled = true
	action.on_activate = cb
	win:add_action(action)
	return action
end

-- Returns a new application window and its inner tab view.
local function new_window()
	local new_tab_button = Gtk.Button {
		halign = "START",
		icon_name = "document-new-symbolic",
		tooltip_text = "New file",
	}
	function new_tab_button:on_clicked()
		open_file()
	end

	local open_file_button = Gtk.Button {
		icon_name = "document-open-symbolic",
		tooltip_text = "Open a file",
	}

	local menu_button = Gtk.MenuButton {
		direction = "DOWN",
		icon_name = "open-menu-symbolic",
		menu_model = burger_menu,
	}
	menu_button.popover.halign = "END"

	local tab_view = Adw.TabView {
		vexpand = true,
	}
	function tab_view:on_create_window()
		return new_window()
	end

--[[
	local tab_button = Adw.TabButton {
		view = tab_view,
		action_name = "overview.open",
	}
]]--

	local save_button = Gtk.Button {
		icon_name = "document-save-symbolic",
		visible = false,
	}
	function save_button:on_clicked()
		local e = get_focused_editor()
		if not e then return end
		if e:has_file() then
			e:save()
		else
			save_file_dialog(window, e)
		end
	end

	local window_title = Adw.WindowTitle.new(app_title, "")

	local content_header = Adw.HeaderBar {
		title_widget = window_title,
		show_start_title_buttons = false,
		valign = "START",
	}
	content_header:pack_start(new_tab_button)
	content_header:pack_start(open_file_button)
	content_header:pack_start(save_button)
	content_header:pack_end(menu_button)
--	content_header:pack_end(tab_button)

	local tab_bar = Adw.TabBar {
		autohide = true,
		view = tab_view,
	}

	local content = Adw.ToolbarView {
		content = tab_view,
		top_bar_style = "FLAT",
	}
	content:add_top_bar(content_header)
	content:add_top_bar(tab_bar)

	-- This is disabled as it is currently broken by Gtk.TextView causing resize events during its snapshot phase, which when used as a child of Adw.TabOverview leads to the entire tab contents visually freezing until switching to a new tab. Worse still, to fix this requires a breaking change in Gtk and Gtk.SourceView, so the fix must be coordinated downstream with distros.
--[[
	local tab_overview = Adw.TabOverview {
		child = content,
		view = tab_view,
	}
]]--

	local window = Adw.ApplicationWindow.new(app)
--	window.content = tab_overview
	window.content = content
	window.title = app_title
	window:set_default_size(640, 720)
	window.width_request = 480
	window.height_request = 480

	function open_file_button:on_clicked()
		open_file_dialog(window)
	end

	function tab_view:on_page_attached(page)
		local e = editors[page.child]
		if not e then return end
		content.top_bar_style = "RAISED_BORDER"
		function e:set_title(title, subtitle, icon)
			page.title = title
			if icon then
				local iname = "document-edit-symbolic"
				page.indicator_icon = Gio.Icon.new_for_string(iname)
			else
				page.indicator_icon = nil
			end
			if tab_view.selected_page == page then
				window.title = title
				window_title:set_title(title)
				window_title:set_subtitle(subtitle)
				save_button.tooltip_text = "Save " .. title
				save_button.visible = icon
				if window_widgets[window] and self:has_file() then
					window_widgets[window].open_folder_action.enabled = true
				end
			end
		end
		function e:grab_focus()
			window:activate()
			tab_view:set_selected_page(page)
			e.tv:grab_focus()
		end
		-- Force set here, because the tab view's selected_page won't be set in time for this call.
		local title, subtitle = e:get_title()
		page.title = name
		window.title = title
		window_title:set_title(title)
		window_title:set_subtitle(subtitle)
		window_widgets[window].open_folder_action.enabled = e:has_file()
		window_widgets[window].search_action.enabled = true
		window_widgets[window].goto_action.enabled = true
	end
	function tab_view:on_page_detached(page)
		local e = editors[page.child]
		if not e then return end
		-- This will be reset once the page is reattached.
		function e:set_title() end
	end
	function tab_view:on_notify(spec)
		if spec.name == "selected-page" and self.selected_page then
			local e = editors[self.selected_page.child]
			e:update_title()
			e.tv:grab_focus()
		end
	end
	function tab_view:on_close_page(page)
		local e = editors[page.child]
		local do_close = true
		local reason
		if type(e.can_close) == "function" then
			do_close, reason = e:can_close()
		end
		self:close_page_finish(page, do_close)
		if not do_close then
			local body = "The file %q has unsaved changes."
			local _, _, name = e:get_path_info()
			body = body:format(name)
			if not e:has_file() then
				body = "This file has unsaved changes."
			end
			local dlg = Adw.AlertDialog.new("Save changes?", body)
			dlg:add_response("close", "Keep open")
			dlg:set_response_appearance("close", "DEFAULT")
			dlg:add_response("discard", "Close without saving")
			dlg:set_response_appearance("discard", "DESTRUCTIVE")
			dlg:add_response("save", "Save and close")
			dlg:set_response_appearance("save", "SUGGESTED")
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
			editors[page.child] = nil
			local path = e:get_path_info()
			if path then editors[path] = nil end
			if self:get_n_pages() == 0 then
				window.title = app_title
				window_title:set_title(app_title)
				window_title:set_subtitle ""
				save_button.visible = false
				content.top_bar_style = "FLAT"
				if window_widgets[window] then
					window_widgets[window].open_folder_action.enabled = false
					window_widgets[window].search_action.enabled = false
					window_widgets[window].goto_action.enabled = false
				end
			end
		end
		return true
	end

	window_widgets[window] = {
		tab_view = tab_view,
		in_handle = in_handle,
	}
	function window:on_close_request()
		local n_pages = tab_view:get_n_pages()
		local unsaved = {}
		for i = 1, n_pages do
			local page = tab_view:get_nth_page(n_pages - i)
			local e = editors[page.child]
			if not e:can_close() then
				table.insert(unsaved, e)
			end
		end
		local function discard()
			for _, e in ipairs(unsaved) do
				e.tv.buffer:set_modified(false)
			end
			self:close()
		end
		if #unsaved > 0 then
			local dlg = Adw.AlertDialog.new("Close window?", "There are unsaved changes.")
			dlg:add_response("cancel", "Keep open")
			dlg:set_response_appearance("cancel", "DEFAULT")
			dlg:add_response("discard", "Discard all changes")
			dlg:set_response_appearance("discard", "DESTRUCTIVE")
			function dlg:on_response(response)
				if response == "discard" then discard() end
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

	local file_drop_target = Gtk.DropTarget.new(Gio.File, Gdk.DragAction.COPY)
	function file_drop_target:on_drop(value)
		local file = value:get_object()
		open_file(file:get_path())
	end
	window:add_controller(file_drop_target)

	window_new_action(window, "close_tab", function()
		local page = tab_view.selected_page
		if not page then return true end
		tab_view:close_page(page)
	end)

	window_new_action(window, "open_file", function()
		open_file_dialog(window)
	end)

	window_widgets[window].open_folder_action = window_new_action(window, "open_folder", function()
		local e = get_focused_editor()
		if not e or not e:has_file() then return end
		local _, dir = e:get_path_info()
		lib.forkexec(("xdg-open %q"):format(dir))
	end)
	window_widgets[window].open_folder_action.enabled = false

	window_new_action(window, "new_file", function()
		open_file()
	end)

	window_new_action(window, "save_file", function()
		local e = get_focused_editor()
		if not e then return end
		if e:has_file() then
			e:save()
		else
			save_file_dialog(window, e)
		end
	end)

	window_new_action(window, "save_file_as", function()
		local e = get_focused_editor()
		if not e then return end
		save_file_dialog(window, e)
	end)

	window_widgets[window].search_action = window_new_action(window, "search", function()
		local e = get_focused_editor()
		if not e then return end
		e:begin_search()
	end)
	window_widgets[window].search_action.enabled = false

	window_widgets[window].goto_action = window_new_action(window, "goto", function()
		local e = get_focused_editor()
		if not e then return end
		e:begin_jumpover()
	end)
	window_widgets[window].goto_action.enabled = false

	window_new_action(window, "new_window", function()
		new_window()
	end)

	window_new_action(window, "shortcuts", function()
		local shortcutwin = newshortwindow(window)
		shortcutwin:present()
	end)

	window_new_action(window, "about", function()
		about(window)
	end)

	if is_devel then window:add_css_class "devel" end

	window:present()

	return tab_view
end

--[[
SECTION: Text editor definitions
]]--

local function buffer_read_file(buffer, file_path)
	local dir, name = lib.dir_and_file(file_path)
	assert(lib.is_dir(dir))
	buffer:begin_irreversible_action()
	buffer:delete(buffer:get_start_iter(), buffer:get_end_iter())
	local hdl = io.open(lib.decode_path(file_path), "r")
	if hdl then
		if lib.file_is_binary(hdl) then
			local window = app.active_window
			if not window then return fail end
			local msg = "The file %q is not a text file, so it can't be opened."
			msg = msg:format(lib.encode_path(name))
			local dlg = Adw.AlertDialog.new("Invalid File Type", msg)
			dlg:add_response("cancel", "Continue without opening")
			dlg:choose(window)
			return fail
		end
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
	-- utf8.len() returns fail on an invalid UTF-8 sequence.
	local length = utf8.len(buffer.text)
	if length == fail then
		local window = app.active_window
		if not window then return fail end
		local msg = "The encoding of %q is not supported, so it can't be opened."
		msg = msg:format(lib.encode_path(name))
		local dlg = Adw.AlertDialog.new("Invalid File Encoding", msg)
		dlg:add_response("cancel", "Continue without opening")
		dlg:choose(window)
		return fail
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
	local success, err = file:flush()
	if success then
		buffer:set_modified(false)
	end
	file:close()
	return success
end

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

function editor:selection_get()
	local first, second = self:get_iters()
	return first:get_slice(second)
end

function editor:selection_replace(str)
	assert(type(str) == "string")
	local first, second = self:get_iters()
	self.tv.buffer:delete(first, second)
	local offset = second:get_offset()
	self.tv.buffer:insert(second, str, #str)
	first = self.tv.buffer:get_iter_at_offset(offset)
	self:set_iters(first, second)
end

function editor:selection_rect()
	local first, second = self:get_iters()
	if second:starts_line() and first:get_offset() ~= second:get_offset() then
		second:backward_line()
		first:order(second)
	end
	local rect = self.tv:get_cursor_locations(second)
	rect.x, rect.y = self.tv:buffer_to_window_coords(Gtk.TextWindowType.TEXT, rect.x, rect.y)
	return rect
end

function editor:can_close()
	return not self.tv.buffer:get_modified()
end

function editor:get_title()
	local title = self.file_name or "New File"
	local subtitle = ""
	if self.file_dir then subtitle = lib.encode_path(self.file_dir) end
	local icon = self.tv.buffer:get_modified()
	return title, subtitle, icon
end

function editor:update_title()
	if type(self.set_title) == "function" then
		self:set_title(self:get_title())
	end
end

function editor:get_path_info()
	if not self:has_file() then return end
	return self.file_dir .. "/" .. self.file_name, self.file_dir, self.file_name
end

function editor:has_file()
	return self.file_dir and self.file_name
end

function editor:set_file_path(path)
	local oldpath = self:get_path_info()
	assert(path and type(path) == "string")
	assert(not lib.is_dir(path))
	local abspath = lib.absolute_path(path)
	if oldpath == abspath then return end
	if editors[abspath] then return end
	if oldpath then editors[oldpath] = nil end
	local dir, name = lib.dir_and_file(path)
	assert(lib.is_dir(dir))
	self.file_dir = dir; self.file_name = name
	editors[abspath] = self
	self:update_title()
end

function editor:edit_file(path)
	if self.tv.buffer:get_modified() then
		return
	end
	assert(type(path) == "string")
	self:set_file_path(path)
	path = self:get_path_info()
	local attrs = lfs.attributes(path)
	self.modtime = attrs.modification
	return buffer_read_file(self.tv.buffer, path)
end

function editor:save(path)
	local oldpath = self:get_path_info()
	if path then self:set_file_path(path) end
	assert(self.file_dir and self.file_name)
	local name, _
	path, _, name = self:get_path_info()
	local samepath = oldpath == path
	local attrs, modtime
	if lib.file_exists(path) then
		attrs = lfs.attributes(path)
		modtime = attrs.modification
	end
	local function dosave()
		local success = buffer_write_file(self.tv.buffer, path)
		if not success then error(err) end
		attrs = lfs.attributes(path)
		self.modtime = attrs.modification
		self:update_title()
	end
	if samepath and self.modtime and modtime and modtime > self.modtime then
		local bodyfmt = "The file %q has been modified by another application since it was opened. Saving will overwrite those modifications."
		local body = bodyfmt:format(name)
		local dlg = Adw.AlertDialog.new("Overwrite file?", body)
		dlg:add_response("keep", "Don't save")
		dlg:set_response_appearance("keep", "DEFAULT")
		dlg:add_response("save", "Overwrite")
		dlg:set_response_appearance("save", "SUGGESTED")
		function dlg:on_response(response)
			if response == "save" then dosave() end
		end
		dlg:choose(app.active_window)
	else
		dosave()
	end
end

function editor:go_to(line)
	local lines = self.tv.buffer:get_line_count()
	assert(type(line) == "number" and line >= 1 and line <= lines)
	local first = self.tv.buffer:get_iter_at_line(line - 1)
	self:set_iters(first, first)
	self:scroll_to_selection()
end

function editor:begin_search()
	-- Replace the search entry if the current selection doesn't match
	if not self.search.bar.search_mode_enabled then
		if self.tv.buffer:get_has_selection() and not self:match_selected() then
			self.search.entry.text = self:selection_get()
		else
			self.search.entry.text = ""
		end
		self.search.replentry.text = ""
	end
	self.search.bar.search_mode_enabled = true
	self.search.entry:grab_focus()
end

function editor:update_matches(total, match)
	if type(match) == "number" and type(total) == "number" then
		return ("%d of %d"):format(match, total)
	elseif type(total) == "number" then
		return ("%d"):format(total)
	elseif type(total) == "string" then
		return total
	else
		return ""
	end
end

-- Lua is excellent at processing long strings, and in my experience this implementation is fast enough for most use cases.
function editor:findall(pattern)
	local byte_indices = {}
	local text = self.tv.buffer.text
	local len = #text
	local init = 1
	while init <= len do
		local i, j = text:find(pattern, init, true)
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
		return self:update_matches "no match"
	end
	return self:update_matches(#self.matches)
end

-- Returns true if the currently selected text is on a match.
function editor:match_selected()
	local first, second = self:get_iters()
	local first_offset = first:get_offset() + 1
	local second_offset = second:get_offset() + 1
	for _, m in ipairs(self.matches) do
		if first_offset == m[1] and second_offset == m[2] then
			return true
		elseif first_offset < m[1] and second_offset < m[2] then
			return false
		end
	end
	return false
end

function editor:selection_has_match()
	if #self.matches == 0 then return false end
	local first, second = self:get_iters()
	local first_offset = first:get_offset() + 1
	local second_offset = second:get_offset() + 1
	for _, m in ipairs(self.matches) do
		if first_offset <= m[1] and second_offset >= m[2] then
			return true
		end
	end
	return false
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
			return self:update_matches(#self.matches, i)
		end
	end
	-- Wrap to start
	self:select_range(self.matches[1][1], self.matches[1][2])
	self:scroll_to_selection()
	return self:update_matches(#self.matches, 1)
end

function editor:prev_match(...)
	self:findall(...)
	if #self.matches == 0 then return end
	local first, _ = self:get_iters()
	local cursor_pos = first:get_offset() + 1
	for i = 1, #self.matches do
		local idx = #self.matches - i + 1
		local m = self.matches[idx]
		if cursor_pos >= m[2] then
			self:select_range(m[1], m[2])
			self:scroll_to_selection()
			return self:update_matches(#self.matches, idx)
		end
	end
	local m = self.matches[#self.matches]
	self:select_range(m[1], m[2])
	self:scroll_to_selection()
	return self:update_matches(#self.matches, #self.matches)
end

-- Replaces the matched expression with the given text.
function editor:replace(repl)
	if not self:match_selected() then return end
	self:selection_replace(repl)
end

function editor:replace_in_selection(pattern, repl)
	if #pattern == 0 then return end
	if not self:selection_has_match() then return end
	pattern = lib.escapepattern(pattern)
	repl = lib.escaperepl(repl)
	print(pattern, repl)
	local text = self:selection_get()
	self:selection_replace(text:gsub(pattern,repl))
end

function editor:replace_all(pattern, repl)
	if #pattern == 0 then return end
	pattern = lib.escapepattern(pattern)
	repl = lib.escaperepl(repl)
	print(pattern, repl)
	local text = self.tv.buffer.text
	self.tv.buffer.text = text:gsub(pattern, repl)
end

function editor:begin_jumpover()
	self:scroll_to_selection()
	self.scroll.kinetic_scrolling = false
	local _, second = self:get_iters()
	local lineno = second:get_line() + 1
	local lines = self.tv.buffer:get_line_count()
	local colno = second:get_line_index() + 1
	local labelfmt = "Line #%d/%d, Column #%d"
	local linelabel = Gtk.Label {
		label = labelfmt:format(lineno, lines, colno),
		halign = "START",
	}
	local lineentry = Gtk.Entry {
		placeholder_text = "Go to line…",
		halign = "FILL",
		width_request = 100,
	}
	local box = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 6,
	}
	box:append(linelabel)
	box:append(lineentry)
	local popover = Gtk.Popover {
		child = box,
		pointing_to = self:selection_rect(),
	}
	function lineentry.on_changed()
		local num = tonumber(lineentry.text)
		if num and num >= 1 and num <= lines then
			lineentry:remove_css_class "error"
		else
			lineentry:add_css_class "error"
		end
	end
	function lineentry.on_activate()
		local num = tonumber(lineentry.text)
		if num and num >= 1 and num <= lines then
			self:go_to(num)
			popover:popdown()
		end
	end
	popover:set_parent(self.tv)
	popover:popup()
	self.scroll.kinetic_scrolling = true
end

--[[
SECTION: Application callbacks and startup
]]--

function app:on_open(files)
	for _, f in ipairs(files) do
		open_file(f:get_path())
	end
	if app.active_window then app.active_window:present() end
end

function app:on_activate()
	if app.active_window then app.active_window:present() end
end

function app:on_startup()
	new_window()
end

return app:run { lib.get_cli_args() }
