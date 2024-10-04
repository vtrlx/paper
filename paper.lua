--[[ paper.lua — Text editor for GNOME that's simple as paper.
Copyright © 2024 Victoria Lacroix

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <https://www.gnu.org/licenses/>. ]]--

-- Allows the libraries to be loaded by Flatpak.
package.cpath = "/app/lib/lua/5.4/?.so;" .. package.cpath
package.path = "/app/share/lua/5.4/?.lua;" .. package.path

-- Linux Support Library --

local lib = require "paperlib"

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
	while file_path:sub(last + 1):find("/") do
		last = last + (file_path:sub(last + 1):find("/"))
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

-- Main Application --

local lgi = require "lgi"

local GLib = lgi.require "GLib"
local Gio = lgi.require "Gio"
local Adw = lgi.require "Adw"
local Gtk = lgi.require "Gtk"
local Gdk = lgi.require "Gdk"

local app_id = lib.get_app_id()
local is_devel = lib.get_is_devel()
local app_title = "Paper"
local app_version = lib.get_app_ver()
local app  = Adw.Application {
	application_id = app_id,
	flags = Gio.ApplicationFlags.DEFAULT_FLAGS | Gio.ApplicationFlags.HANDLES_OPEN,
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

local aboutdlg = Adw.AboutDialog {
	application_icon = "text-x-generic",
	application_name = app_title,
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

local open_file

local function new_editor()
	-- FIXME: Add results count to search entry
	local search_entry = Gtk.SearchEntry {
		placeholder_text = "Find in file…",
		width_request = 300,
	}
	local pattern_toggle = Gtk.ToggleButton {
		label = ".*",
		tooltip_text = "match by pattern",
	}
	local prev_match = Gtk.Button.new_from_icon_name "go-up-symbolic"
	local next_match = Gtk.Button.new_from_icon_name "go-down-symbolic"
	local search_ctrl_box = Gtk.Box { orientation = "HORIZONTAL" }
	search_ctrl_box:add_css_class "linked"
	search_ctrl_box:append(search_entry)
	search_ctrl_box:append(pattern_toggle)
	search_ctrl_box:append(prev_match)
	search_ctrl_box:append(next_match)
	local matchnum_label = Gtk.Label {
		margin_start = 6,
		halign = "START",
		hexpand = false,
	}
	matchnum_label:add_css_class "numeric"
	local search_box = Gtk.Box {
		orientation = "HORIZONTAL",
		spacing = 6,
	}
	search_box:append(search_ctrl_box)
	search_box:append(matchnum_label)
	local replace_entry = Gtk.Entry {
		placeholder_text = "Replace with…",
		width_request = 300,
	}
	local replace_button = Gtk.Button.new_with_label "Replace"
	local replace_all_button = Gtk.Button.new_with_label "Replace All"
	local replace_box = Gtk.Box { orientation = "HORIZONTAL" }
	replace_box:add_css_class "linked"
	replace_box:append(replace_entry)
	replace_box:append(replace_button)
	replace_box:append(replace_all_button)
	local search_bar_box = Gtk.Box {
		orientation = "VERTICAL",
		spacing = 6,
	}
	search_bar_box:append(search_box)
	search_bar_box:append(replace_box)
	local search_bar = Gtk.SearchBar {
		child = search_bar_box,
		search_mode_enabled = false,
		show_close_button = true,
	}
	search_bar:connect_entry(search_entry)
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
	text_view:add_css_class "paper-editor"
	local file_drop_target = Gtk.DropTarget.new(Gio.File, Gdk.DragAction.COPY)
	function file_drop_target:on_drop(value)
		local file = value:get_object()
		open_file(file:get_path())
	end
	text_view:add_controller(file_drop_target)
	text_view:add_css_class "numeric" -- Force monospace numbers regardless of font.
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
	local e = {
		matches = {},
		search = {
			entry = search_entry,
			bar = search_bar,
			matchnum = matchnum_label,
			pattern = pattern_toggle,
		},
		tv = text_view,
		scroll = scrolled_win,
		widget = box,
	}
	function e.tv.buffer:on_modified_changed()
		e:update_title()
	end
	function e.tv.buffer:on_mark_set(iter, mark)
		replace_button.sensitive = e:match_selected()
	end
	local function dosearch()
		-- Forgo the search if the pattern is too small, because it'd take too long. If the user wants to match a small pattern, they can manually do a search by activating the entry or pressing the next/prev buttons to do so.
		if #search_entry.text < 3 then
			matchnum_label.label = ""
			return
		end
		matchnum_label.label = e:findall(search_entry.text, not pattern_toggle.active)
		replace_all_button.sensitive = #e.matches > 0
	end
	local function prev()
		matchnum_label.label = e:prev_match(search_entry.text, not pattern_toggle.active)
		replace_all_button.sensitive = #e.matches > 0
	end
	local function next()
		matchnum_label.label = e:next_match(search_entry.text, not pattern_toggle.active)
		replace_all_button.sensitive = #e.matches > 0
	end
	local function repl()
		if not replace_button.sensitive then return end
		e:replace(self.text)
		matchnum_label.label = e:next_match(search_entry.text, not pattern_toggle.active)
	end
	local function replall()
		-- FIXME: Create Gtk.TextMark at selection, select it and delete marks after replacing
		e:replace_all(search_entry.text, not pattern_toggle.active, replace_entry.text)
		replace_all_button.sensitive = false
		matchnum_label.label = ""
	end
	pattern_toggle.on_clicked = dosearch
	search_entry.on_search_changed = dosearch
	search_entry.on_previous_match = prev
	prev_match.on_clicked = prev
	search_entry.on_next_match = next
	next_match.on_clicked = next
	search_entry.on_activate = next
	replace_entry.on_activate = repl
	replace_button.on_clicked = repl
	replace_all_button.on_clicked = replall
	return setmetatable(e, {
		__index = editor,
	})
end

open_file = function(path)
	assert(app.active_window)
	local tab_view = window_widgets[app.active_window].tab_view
	assert(tab_view)
	if type(path) == "string" then
		path = lib.absolute_path(path)
		local e = editors_by_path[path]
		if e then
			-- File is already open so just grab focus.
			-- FIXME: If file is open in another window, maybe create a new editor backed by the open file's GtkTextBuffer?
			e:grab_focus()
			return
		end
	end
	local e = new_editor()
	if type(path) == "string" then
		if not e:edit_file(path) then return end
		local iter = e.tv.buffer:get_start_iter()
		e.tv.buffer:select_range(iter, iter)
	end
	editors_by_view[e.widget] = e
	if path then editors_by_path[path] = e end
	local page = tab_view:add_page(e.widget)
	tab_view:set_selected_page(page)
end

local function get_focused_editor()
	assert(app.active_window)
	local tab_view = window_widgets[app.active_window].tab_view
	assert(tab_view)
	local page = tab_view.selected_page
	if not page then return nil end
	return editors_by_view[page.child]
end

-- File Management --

local file_dialog_path = lib.get_home_directory()
local file_dialog

local function open_file_dialog(window)
	if file_dialog then return end
	local e = get_focused_editor()
	local dir = file_dialog_path
	if e and e:has_file() then
		dir = e:get_file_dir()
	end
	file_dialog = Gtk.FileChooserNative.new("Open File", window, "OPEN")
	file_dialog.modal = true
	file_dialog.transient_for = window
	file_dialog:set_current_folder(Gio.File.new_for_path(dir))
	file_dialog:set_select_multiple(true)
	function file_dialog:on_response(id)
		file_dialog = nil
		if id ~= Gtk.ResponseType.ACCEPT then return end
		file_dialog_path = self:get_current_folder():get_path()
		local list = self:get_files()
		for i = 1, list.n_items do
			-- Gio's API documents says that ListModel's :get_item() method is not available to language bindings and to use :get_object() instead. That's not the case for LGI, which binds :get_item() and returns the object itself instead of a pointer.
			local file = list:get_item(i - 1)
			open_file(file:get_path())
		end
	end
	file_dialog:show()
end

local function save_file_dialog(window, e)
	if file_dialog then return end
	local dir = file_dialog_path
	if e:has_file() then
		dir = e:get_file_dir()
	end
	file_dialog = Gtk.FileChooserNative.new("Save File As", window, "SAVE")
	file_dialog.modal = true
	file_dialog.transient_for = window
	file_dialog:set_current_folder(Gio.File.new_for_path(dir))
	function file_dialog:on_response(id)
		file_dialog = nil
		if id ~= Gtk.ResponseType.ACCEPT then return end
		local f = self:get_file()
		if not f then return end
		local path = f:get_path()
		local dir, _ = lib.dir_and_file(path)
		file_dialog_path = dir
		e:save(path)
	end
	file_dialog:show()
end

-- Application Menus --

local file_menu = Gio.Menu()
file_menu:append("Save", "win.save_file")
file_menu:append("Save As…", "win.save_file_as")
file_menu:append("Open File Location", "win.open_folder")
local app_menu = Gio.Menu()
app_menu:append("New Window", "win.new_window")
app_menu:append("Keyboard Shortcuts", "win.shortcuts")
app_menu:append("About " .. app_title, "win.about")
local burger_menu = Gio.Menu()
burger_menu:append_section(nil, file_menu)
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

-- Main Application Window --

local function window_new_action(win, name, cb)
	local action = Gio.SimpleAction.new(name)
	action.enabled = true
	action.on_activate = cb
	win:add_action(action)
	return action
end

-- Returns a new application window and its inner tab view.
local function new_window()
	local open_file_button = Gtk.Button {
		label = "Open",
	}
	open_file_button:add_css_class "suggested-action"

	local new_tab_button = Gtk.Button {
		halign = "START",
		icon_name = "tab-new-symbolic",
	}
	function new_tab_button:on_clicked()
		open_file()
	end

	local menu_button = Gtk.MenuButton {
		direction = "DOWN",
		halign = "END",
		icon_name = "open-menu-symbolic",
		menu_model = burger_menu,
	}

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

	local title_icon = Gtk.Button {
		icon_name = nil,
		visible = false,
	}
	function title_icon:on_clicked()
		local e = get_focused_editor()
		if not e then return end
		if e:has_file() then
			e:save()
		else
			save_file_dialog(window, e)
		end
	end

	local window_title = Adw.WindowTitle.new(app_title, "")
	local title_box = Gtk.CenterBox {
		orientation = "HORIZONTAL",
		shrink_center_last = true,
	}
	title_box.start_widget = title_icon
	title_box.center_widget = window_title

	local content_header = Adw.HeaderBar {
		title_widget = title_box,
		show_start_title_buttons = false,
		valign = "START",
	}
	content_header:pack_start(open_file_button)
	content_header:pack_start(new_tab_button)
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
	window:set_default_size(800, 600)

	function open_file_button:on_clicked()
		open_file_dialog(window)
	end

	function tab_view:on_page_attached(page)
		local e = editors_by_view[page.child]
		if not e then return end
		content.top_bar_style = "RAISED_BORDER"
		function e:set_title(title, subtitle, icon)
			page.title = title
			page.indicator_icon = icon
			page.indicator_activatable = icon ~= nil
			if page.indicator_activatable then
				page.indicator_tooltip = "Save " .. (e:get_file_name() or "New File")
			else
				page.indicator_tooltip = e:get_file_name() or "New File"
			end
			if tab_view.selected_page == page then
				window_title:set_title(title)
				window_title:set_subtitle(subtitle)
				if icon then
					title_icon.icon_name = icon:to_string()
				end
				title_icon.tooltip_text = "Save " .. (e:get_file_name() or "New File")
				title_icon.visible = icon ~= nil
				if window_widgets[window] then
					window_widgets[window].open_folder_action.enabled = self:has_file()
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
		window_title:set_title(title)
		window_title:set_subtitle(subtitle)
		window_widgets[window].open_folder_action.enabled = e:has_file()
	end
	function tab_view:on_page_detached(page)
		local e = editors_by_view[page.child]
		if not e then return end
		-- This will be reset once the page is reattached.
		function e:set_title() end
	end
	function tab_view:on_notify(spec)
		if spec.name == "selected-page" and self.selected_page then
			local e = editors_by_view[self.selected_page.child]
			e:update_title()
			e.tv:grab_focus()
		end
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
				window_title:set_title(app_title)
				window_title:set_subtitle ""
				title_icon.visible = false
				content.top_bar_style = "FLAT"
				if window_widgets[window] then
					window_widgets[window].open_folder_action.enabled = false
				end
			end
		end
		return true
	end
	function tab_view:on_indicator_activated(page)
		local e = editors_by_view[page.child]
		if not e then return end
		if e:has_file() then
			e:save()
		else
			save_file_dialog(window, e)
		end
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
			function dlg:on_response(response)
				if response == "discard" then
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
		lib.forkexec(("xdg-open %q"):format(e:get_file_dir()))
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

	window_new_action(window, "search", function()
		local e = get_focused_editor()
		if not e then return end
		e:begin_search()
	end)

	window_new_action(window, "goto", function()
		local e = get_focused_editor()
		if not e then return end
		e:begin_jumpover()
	end)

	window_new_action(window, "new_window", function()
		new_window()
	end)

	window_new_action(window, "shortcuts", function()
		local shortcutwin = newshortwindow(window)
		shortcutwin:present()
	end)

	window_new_action(window, "about", function()
		aboutdlg:present(window)
	end)

	if is_devel then window:add_css_class "devel" end

	window:present()

	return tab_view
end

-- Text Editor --

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
			local msg = ("The file %q is not a text file, so it can't be opened."):format(lib.encode_path(name))
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
	first = self.tv.buffer:get_iter_at_offset(offset)
	self:set_iters(first, second)
end

function editor:selecton_wrap(str)
	assert(type(str) == "string")
	self:selection_prepend(str)
	self:selection_append(str)
end

function editor:selection_rect()
	local bound, ins = self:get_iters()
	if ins:starts_line() and bound:get_offset() ~= ins:get_offset() then
		ins:backward_line()
		bound:order(ins)
	end
	local rect = self.tv:get_cursor_locations(ins)
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
	local icon
	if self.tv.buffer:get_modified() then
		icon = Gio.Icon.new_for_string "document-save-symbolic"
	end
	return title, subtitle, icon
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
	return buffer_read_file(self.tv.buffer, self:get_file_path())
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
	local success = buffer_write_file(self.tv.buffer, self:get_file_path())
	if not success then error(err) end
	self:update_title()
end

function editor:go_to(line)
	local lines = self.tv.buffer:get_line_count()
	assert(line >= 1 and line <= lines)
	self:select_lines(line)
	local bound = self:get_iters()
	self:set_iters(bound, bound)
	self:scroll_to_selection()
end

function editor:begin_search()
	-- Replace the search entry if the current selection doesn't match
	if not self.search.bar.search_mode_enabled and not self:match_selected() then
		self.search.entry.text = self:selection_get()
	end
	self.search.pattern.active = false
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

-- Lua is excellent at processing long strings, so this should be pretty fast.
function editor:findall(pattern, plain)
	local byte_indices = {}
	local text = self.tv.buffer.text
	local len = #text
	local init = 1
	local per_line = (not plain) and (pattern:match "^^" or pattern:match "$$")
	if not per_line then
		while init <= len do
			local i, j = text:find(pattern, init, plain)
			if not i or not j then break end
			table.insert(byte_indices, { i, j })
			init = j + 1
		end
	else
		local linelen = 0
		for line in text:gmatch "[^\n]*" do
			local i, j = line:find(pattern, 1, plain)
			if i and j then
				table.insert(byte_indices, { i + linelen, j + linelen })
			end
			linelen = linelen + #line + 1
		end
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
	local bound, ins = self:get_iters()
	local bound_offset = bound:get_offset() + 1
	local ins_offset = ins:get_offset() + 1
	for _, m in ipairs(self.matches) do
		if bound_offset == m[1] and ins_offset == m[2] then
			return true
		elseif bound_offset < m[1] and ins_offset < m[2] then
			return false
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
	local start_iter, _ = self:get_iters()
	local cursor_pos = start_iter:get_offset()
	for i = 1, #self.matches do
		local idx = #self.matches - i + 1
		local m = self.matches[idx]
		if cursor_pos > m[2] then
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

function editor:replace_all(pattern, plain, repl)
	if #pattern == 0 then return end
	self:findall(pattern, plain)
	local i = #self.matches
	self.tv.buffer:begin_user_action()
	-- Matches are always sorted, so by going backwards with replacements, it can be guaranteed
	repeat
		local m = self.matches[i]
		self:select_range(m[1], m[2])
		if plain then
			self:selection_replace(repl)
		else
			local text = self:selection_get()
			self:selection_replace(text:gsub(pattern, repl))
		end
		i = i - 1
	until i == 0
	self.tv.buffer:end_user_action()
end

function editor:begin_jumpover()
	self:scroll_to_selection()
	self.scroll.kinetic_scrolling = false
	local lineentry = Gtk.Entry {
		placeholder_text = "Go to line…",
		width_request = 100,
	}
	local popover = Gtk.Popover {
		child = lineentry,
		pointing_to = self:selection_rect(),
	}

	function lineentry:on_changed()
		if self.text:match "^[0-9]+$" or self.text == "$" then
			self:remove_css_class "error"
		else
			self:add_css_class "error"
		end
	end

	function lineentry.on_activate()
		if lineentry.text:match "^[0-9]+$" then
			self:go_to(tonumber(lineentry.text))
			popover:popdown()
		elseif lineentry.text == "$" then
			local iter = self.tv.buffer:get_end_iter()
			self:set_iters(iter, iter)
			self:scroll_to_selection()
			popover:popdown()
		end
	end

	popover:set_parent(self.tv)
	popover:popup()
	self.scroll.kinetic_scrolling = true
end

-- Custom Styling --

do -- Initialize custom CSS.
	local provider = Gtk.CssProvider()
	provider:load_from_string [[
		.paper-editor {
			font-size: 110%;
		}
	]]
	local display = Gdk.Display.get_default()
	Gtk.StyleContext.add_provider_for_display(display, provider, 1)
end

-- Application Features --

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
