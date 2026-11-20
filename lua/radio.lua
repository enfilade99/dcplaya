--- @file     radio.lua
--- @date     2026/11/15
--- @brief    DC99 player screen.
---
--- One application, two views drawn in the same style :
---  - "main"   : what is playing, in large type, five favourites below.
---  - "browse" : one list with three sections (Stations, Favourites, Files).
--- Works with the controller, a keyboard and a mouse.
---  - "chat"   : IRC #dc99 and KosNet global chat (radio_chat.lua).
---  - "online" : who is playing what (radio_dash.lua, with the home
---               dashboard : status line, app bar, L and R panels).
--- The older dcplaya applications are untouched and still reachable from
--- the application switcher (Y).

radio_loaded = nil

if not dolib("basic") then return end
if not dolib("evt") then return end
if not dolib("gui") then return end
dolib("radio_vis") -- the Lua visualizers; the screen works without
dolib("radio_chat") -- IRC #dc99 and KosNet chat
dolib("radio_dash") -- home dashboard, L/R panels, Online screen
dolib("radio_wx") -- weather : home screen corner and its own screen

radio_cfg_filename = "/ram/dcplaya/configs/radio.cfg"
radio_list_filename = home .. "../extra/radio.m3u"
radio_max_slots = 5
radio_rows = 12
radio_row_h = 22
radio_list_y = 92
radio_z = 400 -- in front of the visualizers

radio_sections = { "STATIONS", "FAVOURITES", "FILES" }
radio_nsec = 3
radio_bg_dir = home .. "backgrounds/"
radio_bg_original = "/rd/dcpbkg3.jpg"
radio_roots = {
   { name = "Disc", path = "/cd/" },
   { name = "SD card", path = "/sd/" },
   { name = "Memory card", path = "/vmu/" },
}

radio_col = {
   frame = { 1.00, 1.00, 0.54, 0.10 },
   dark  = { 1.00, 0.48, 0.29, 0.06 },
   fill  = { 0.82, 0.14, 0.08, 0.02 },
   fill2 = { 0.82, 0.05, 0.03, 0.02 },
   shade = { 0.55, 0.00, 0.00, 0.00 },
   sel   = { 1.00, 0.78, 0.42, 0.02 },
   sel2  = { 1.00, 0.45, 0.22, 0.00 },
   text  = { 1.00, 1.00, 0.85, 0.29 },
   white = { 1.00, 1.00, 1.00, 1.00 },
   black = { 1.00, 0.00, 0.00, 0.00 },
   green = { 1.00, 0.36, 1.00, 0.42 },
   dim   = { 1.00, 0.91, 0.88, 0.78 },
   label = { 1.00, 1.00, 0.60, 0.12 },
   star  = { 1.00, 1.00, 0.69, 0.00 },
}

-- solid dark bars and key caps (hint line, app bar)
radio_bar = { 0.92, 0.03, 0.02, 0.01 }
radio_cap = { 1.00, 0.10, 0.06, 0.02 }

-- ----------------------------------------------------------------------
-- drawing helpers
-- ----------------------------------------------------------------------

function radio_text(dl, x, y, size, c, s)
   dl_text_prop(dl, 0, size)
   dl_draw_text(dl, x, y, 30, c[1], c[2], c[3], c[4], s)
end

function radio_width(s, size)
   local w = dl_measure_text(nil, s, 0, size)
   return w or 0
end

-- Cut a string so that it fits in maxw pixels.
function radio_fit(s, size, maxw)
   if radio_width(s, size) <= maxw then return s end
   -- the longest start that fits, found by halving (each measure costs)
   local lo, hi = 1, strlen(s)
   while lo < hi do
      local mid = floor((lo + hi + 1) / 2)
      if radio_width(strsub(s, 1, mid) .. "..", size) <= maxw then lo = mid
      else hi = mid - 1 end
   end
   return strsub(s, 1, lo) .. ".."
end

-- Split a name over two lines, at a space when there is one.
function radio_wrap2(s, size, maxw)
   if radio_width(s, size) <= maxw then return s end
   local n = strlen(s)
   local cut = nil
   local i
   for i = 1, n do
      if strsub(s, i, i) == " " then
	 if radio_width(strsub(s, 1, i-1), size) <= maxw then
	    cut = i
	 end
      end
   end
   if cut then
      return strsub(s, 1, cut-1), radio_fit(strsub(s, cut+1), size, maxw)
   end
   local l1 = radio_fit(s, size, maxw)
   return l1
end

function radio_box(dl, x, y, w, h, z, c)
   dl_draw_box1(dl, x, y, x+w, y+h, z, c[1], c[2], c[3], c[4])
end

-- gradient box, ty 1 : left to right, 2 : top to bottom
function radio_grad(dl, x, y, w, h, z, c1, c2, ty)
   dl_draw_box(dl, x, y, x+w, y+h, z,
	       c1[1], c1[2], c1[3], c1[4], c2[1], c2[2], c2[3], c2[4], ty)
end

function radio_frame(dl, x, y, w, h, fill, border, fill2)
   if fill then
      if fill2 then
	 radio_grad(dl, x, y, w, h, 10, fill, fill2, 2)
      else
	 radio_box(dl, x, y, w, h, 10, fill)
      end
   end
   radio_box(dl, x, y, w, 2, 20, border)
   radio_box(dl, x, y+h-2, w, 2, 20, border)
   radio_box(dl, x, y, 2, h, 20, border)
   radio_box(dl, x+w-2, y, 2, h, 20, border)
end

-- Remember a rectangle the mouse can point at.
function radio_hit(r, x, y, w, h, kind, arg)
   tinsert(r.hits, { x, y, x+w, y+h; kind = kind, arg = arg })
end

-- ----------------------------------------------------------------------
-- stations, favourites, files
-- ----------------------------------------------------------------------

function radio_load_list(path)
   local st = { n = 0 }
   local file = openfile(path, "r")
   if not file then return st end
   local cr = strchar(13)
   local name
   local line = read(file)
   local guard = 0
   while line and guard < 4096 do
      guard = guard + 1
      line = gsub(line, cr, "")
      if strlen(line) > 0 then
	 if strsub(line, 1, 1) == "#" then
	    local a, b, t, nm = strfind(line, "^#EXTINF:([%-0-9]*),(.*)")
	    if nm then name = nm end
	 else
	    if not name then
	       local e = strfind(line, "<endpath>", 1, 1)
	       name = (e and strsub(line, 1, e-1)) or line
	    end
	    tinsert(st, { name = name, url = line, kind = "station" })
	    name = nil
	 end
      end
      line = read(file)
   end
   closefile(file)
   return st
end

function radio_load_cfg(r)
   r.fav = { n = 0 }
   radio_cfg = nil
   local file = openfile(radio_cfg_filename, "r")
   if file then
      closefile(file)
      dofile(radio_cfg_filename)
   end
   if type(radio_cfg) == "table" then
      if type(radio_cfg.bg) == "string" then r.bg = radio_cfg.bg end
      if type(radio_cfg.vis) == "string" then r.vis_saved = radio_cfg.vis end
      if radio_cfg.bar == 0 then r.bar_off = 1 end
   end
   if type(radio_cfg) == "table" and type(radio_cfg.fav) == "table" then
      local i, v
      for i, v in radio_cfg.fav do
	 if type(v) == "string" then
	    -- first version of the file : addresses only
	    local s = radio_find_url(r.st, v)
	    if s then
	       tinsert(r.fav, { name = r.st[s].name, url = v,
			  kind = "station" })
	    end
	 elseif type(v) == "table" and type(v.url) == "string" then
	    tinsert(r.fav, { name = v.name or v.url, url = v.url,
		       kind = v.kind or "station" })
	 end
      end
   end
end

-- ramonly : only the file in memory (the memory card gets it with the
-- next save)
function radio_save_cfg(r, ramonly)
   local file = openfile(radio_cfg_filename, "w")
   if not file then return end
   write(file, format("radio_cfg = { bg=%q, vis=%q, bar=%d, fav = {\n",
		      r.bg or "Original", r.vis_name or "off",
		      (r.bar_off and 0) or 1))
   local i
   for i = 1, getn(r.fav) do
      local f = r.fav[i]
      write(file, format(" { name=%q, url=%q, kind=%q },\n",
			 f.name, f.url, f.kind))
   end
   write(file, "} }\n")
   closefile(file)
   r.fav_changed = nil
   if vmu_save and not ramonly then
      vmu_save(nil, 1)
   end
end

function radio_find_url(list, url)
   local i
   for i = 1, getn(list) do
      if list[i].url == url then return i end
   end
end

function radio_toggle_fav(r, item)
   if not item or not item.url then return end
   local i = radio_find_url(r.fav, item.url)
   if i then
      tremove(r.fav, i)
   else
      tinsert(r.fav, { name = item.name, url = item.url, kind = item.kind })
   end
   r.fav_changed = 1
end

-- Content of a folder : folders first, then what the player can play.
function radio_load_dir(path)
   local items = { n = 0 }
   local i
   if path == "/" then
      for i = 1, getn(radio_roots) do
	 tinsert(items, { name = radio_roots[i].name,
		    path = radio_roots[i].path, kind = "dir" })
      end
      return items
   end
   local dir = dirlist("-n", path)
   if type(dir) ~= "table" then return items end
   local n = getn(dir)
   for i = 1, n do
      local e = dir[i]
      if e.size and e.size < 0 and e.name ~= "." and e.name ~= ".." then
	 tinsert(items, { name = e.name, path = path .. e.name .. "/",
		    kind = "dir" })
      end
   end
   for i = 1, n do
      local e = dir[i]
      if e.size and e.size >= 0 then
	 local full = path .. e.name
	 local ty, major = filetype(full, e.size)
	 local low = strlower(e.name)
	 if strsub(low, -4) == ".bin" then
	    -- the program itself, not a tune
	 elseif major == "music" then
	    tinsert(items, { name = e.name, url = full, kind = "file" })
	 elseif major == "playlist" then
	    tinsert(items, { name = e.name, path = full, kind = "list" })
	 end
      end
   end
   return items
end

function radio_parent(path)
   if path == "/" then return end
   local a, b, up = strfind(path, "^(.*/)[^/]+/?$")
   local i
   for i = 1, getn(radio_roots) do
      if radio_roots[i].path == path then return "/" end
   end
   return up or "/"
end

function radio_open_dir(r, path, is_list)
   r.fpath = path
   r.fis_list = is_list
   if is_list then
      r.files = radio_load_list(path)
   else
      r.files = radio_load_dir(path)
   end
end

-- The list shown by the current section.
function radio_items(r)
   if r.sec == 1 then return r.st end
   if r.sec == 2 then return r.fav end
   if r.sec == 4 then return radio_settings(r) end
   return r.files
end

-- ----------------------------------------------------------------------
-- settings : background, visualizer
-- ----------------------------------------------------------------------

-- "None", "Original", then every picture found in dcplaya/backgrounds.
function radio_backgrounds(r)
   if r.bgs then return r.bgs end
   local b = { n = 0 }
   tinsert(b, { name = "None" })
   tinsert(b, { name = "Original", file = radio_bg_original })
   local dir = dirlist("-n", radio_bg_dir)
   if type(dir) == "table" then
      local i
      for i = 1, getn(dir) do
	 local e = dir[i]
	 local low = strlower(e.name)
	 if e.size and e.size > 0
	    and (strsub(low, -4) == ".jpg" or strsub(low, -5) == ".jpeg") then
	    local a, z, nm = strfind(e.name, "^(.*)%.[^.]*$")
	    tinsert(b, { name = nm or e.name, file = radio_bg_dir .. e.name })
	 end
      end
   end
   r.bgs = b
   return b
end

function radio_set_background(r, name)
   local b = radio_backgrounds(r)
   local i, pick
   for i = 1, getn(b) do
      if strlower(b[i].name) == strlower(name or "") then pick = b[i] end
   end
   pick = pick or b[2]
   r.bg = pick.name
   if not background then return end
   if pick.file then
      background:set_color(color_new(1, 1, 1, 1))
      if not background:set_texture(pick.file, "scale") then
	 -- the picture did not load : back to the original
	 r.bg = b[2].name
	 background:set_texture(b[2].file, "scale")
      end
   else
      background:set_texture()
      background:set_color(color_new(1, 0.03, 0.03, 0.08),
			   color_new(1, 0.03, 0.03, 0.08),
			   color_new(1, 0.00, 0.00, 0.00),
			   color_new(1, 0.00, 0.00, 0.00))
   end
end

function radio_next_background(r)
   local b = radio_backgrounds(r)
   local i, k
   k = 1
   for i = 1, getn(b) do
      if b[i].name == r.bg then k = i end
   end
   k = k + 1
   if k > getn(b) then k = 1 end
   radio_ask_background(r, b[k].name)
end

-- A picture takes a moment to load : say so first, load on a later frame.
function radio_ask_background(r, name)
   r.bg_pending = name
   r.bg_wait = 3
   r.busy = "Loading " .. name .. " ..."
   r.fav_changed = 1 -- the choice is saved with the favourites
end

function radio_settings(r)
   local net = "not connected"
   if net_connected and net_cfg and net_cfg.ip then
      net = "connected, " .. net_cfg.ip
   end
   local vol = playa_volume and playa_volume()
   vol = (type(vol) == "number" and format("%d%%", floor(vol * 100 + 0.5)))
      or "?"
   return {
      { name = "Background : " .. (r.bg or "Original"), kind = "setting",
	 id = "bg" },
      { name = "Visualizer : " .. (r.vis_name or "off"), kind = "setting",
	 id = "vis" },
      { name = "Volume : " .. vol, kind = "setting", id = "vol" },
      { name = "Network : " .. net, kind = "setting", id = "net" },
      { name = "Help", kind = "setting", id = "help" },
      { name = "About dcplaya", kind = "setting", id = "about" },
      { name = "Classic dcplaya menus", kind = "setting", id = "classic" };
      n = 7
   }
end

-- A (dir 1) or X (dir -1) on a line of the menu.
function radio_setting(r, id, dir)
   if id == "bg" then
      radio_next_background(r)
   elseif id == "vis" then
      radio_next_visual(r, dir)
      r.toast, r.toast_t = nil, nil
   elseif id == "vol" then
      local vol = playa_volume()
      if type(vol) == "number" then
	 vol = vol + dir * 0.1
	 if vol < 0 then vol = 0 end
	 if vol > 1 then vol = 1 end
	 playa_volume(vol)
      end
   elseif dir < 0 then
      return
   elseif id == "net" then
      if net_connect_dialog then radio_dialog(r, net_connect_dialog) end
   elseif id == "help" then
      r.mode = "help"
   elseif id == "about" then
      if control_center_about then
	 radio_dialog(r, control_center_about, {})
      end
   elseif id == "classic" then
      if r.owner then evt_send(r.owner, { key = KBD_CONT1_Y }) end
   end
end

-- Run one of the older dcplaya dialogs : our screen steps aside while it
-- is open and comes back after, without waking the old panels.
function radio_dialog(r, f, arg, arg2)
   r.modal = 1
   dl_set_active2(r.back, r.front, 0)
   dl_set_active(r.cursor, 0)
   f(arg, arg2)
   r.modal = nil
   r.dirty = 1
end

function radio_set_section(r, sec)
   if sec < 1 then sec = radio_nsec end
   if sec > radio_nsec then sec = 1 end
   r.sec = sec
   if sec < 4 then r.list_sec = sec end
   r.search = nil
   if sec == 3 and not r.files then
      radio_open_dir(r, "/")
   end
   radio_clamp(r)
end

function radio_clamp(r)
   local n = getn(radio_items(r))
   local s = r.sec
   if r.pos[s] > n then r.pos[s] = n end
   if r.pos[s] < 1 then r.pos[s] = 1 end
   if r.pos[s] < r.top[s] then r.top[s] = r.pos[s] end
   if r.pos[s] >= r.top[s] + radio_rows then
      r.top[s] = r.pos[s] - radio_rows + 1
   end
   if r.top[s] > n - radio_rows + 1 then r.top[s] = n - radio_rows + 1 end
   if r.top[s] < 1 then r.top[s] = 1 end
end

function radio_move(r, d, wrap)
   local n = getn(radio_items(r))
   local s = r.sec
   local p = r.pos[s] + d
   if wrap then
      if p < 1 then p = n end
      if p > n then p = 1 end
   end
   r.pos[s] = p
   radio_clamp(r)
end

-- ----------------------------------------------------------------------
-- playing
-- ----------------------------------------------------------------------

function radio_is_playing()
   return play() == 1
end

function radio_play_item(r, item, queue, qpos)
   if not item or not item.url then return end
   r.now = item
   r.queue, r.qpos = queue, qpos
   r.stopped = nil
   -- same convention as the song-browser playlist : the address ends at
   -- <endpath>, and <force-xxx> tells the decoder which format to expect.
   local path = item.url
   local a, b, force = strfind(path, "<force%-([^>]*)>")
   local e = strfind(path, "<endpath>", 1, 1)
   if e then path = strsub(path, 1, e-1) end
   if ff_ff and force then ff_ff(force) end
   if song_browser_play then
      song_browser_play(song_browser, path, 0, 1)
   else
      playa_play(path, 0, 1)
   end
   if ff_ff and force then ff_ff() end
   r.started = 3 -- seconds we give it to start before deciding it ended
   if dash_recent then dash_recent(r, item) end
   r.dirty = 1
end

function radio_stop(r)
   r.stopped = 1
   if song_browser_stop then
      song_browser_stop(song_browser)
   else
      playa_stop()
   end
   r.dirty = 1
end

-- A file ended by itself : go on with the next file of its folder.
function radio_next(r)
   if not r.queue or not r.qpos then return end
   local i = r.qpos + 1
   local n = getn(r.queue)
   while i <= n do
      if r.queue[i].kind == "file" then
	 radio_play_item(r, r.queue[i], r.queue, i)
	 return 1
      end
      i = i + 1
   end
end

-- Open or play the line under the cursor.
function radio_activate(r)
   local items = radio_items(r)
   local item = items[r.pos[r.sec]]
   if not item then return end
   if item.kind == "setting" then
      radio_setting(r, item.id, 1)
   elseif item.kind == "dir" then
      tinsert(r.fhist, { r.pos[3], r.top[3] })
      radio_open_dir(r, item.path)
      r.pos[3], r.top[3] = 1, 1
      r.search = nil
   elseif item.kind == "list" then
      tinsert(r.fhist, { r.pos[3], r.top[3] })
      radio_open_dir(r, item.path, 1)
      r.pos[3], r.top[3] = 1, 1
      r.search = nil
   else
      radio_play_item(r, item, items, r.pos[r.sec])
   end
end

-- B in the list : one folder up, or back to the main view.
function radio_back(r)
   if r.search then
      r.search = nil
      return
   end
   if r.sec == 3 and r.fpath and r.fpath ~= "/" then
      local up = radio_parent(r.fpath)
      radio_open_dir(r, up or "/")
      local h = tremove(r.fhist)
      if h then
	 r.pos[3], r.top[3] = h[1], h[2]
      else
	 r.pos[3], r.top[3] = 1, 1
      end
      radio_clamp(r)
      return
   end
   r.mode = "main"
   if r.fav_changed then
      radio_save_cfg(r)
   end
end

-- Type-ahead : jump to the first line that starts with (or else holds)
-- what was typed.
function radio_search(r)
   local items = radio_items(r)
   local n = getn(items)
   local s = r.search
   if not s or s == "" then return end
   local i, hit
   for i = 1, n do
      local nm = strlower(items[i].name)
      if strsub(nm, 1, strlen(s)) == s then hit = i break end
   end
   if not hit then
      for i = 1, n do
	 if strfind(strlower(items[i].name), s, 1, 1) then hit = i break end
      end
   end
   if hit then
      r.pos[r.sec] = hit
      radio_clamp(r)
   end
end

-- ----------------------------------------------------------------------
-- visualizer
-- ----------------------------------------------------------------------

-- Every visualizer : the Lua ones (radio_vis.lua) then the 3D plugins.
function radio_visuals()
   local v = { n = 0 }
   local i
   if radio_vis_list and fft_bands then
      for i = 1, getn(radio_vis_list) do
	 tinsert(v, { name = radio_vis_list[i].name, lua = i })
      end
   end
   local dl = get_driver_lists and get_driver_lists()
   -- (the lists are not plain tables : read n and the entries directly)
   if type(dl) == "table" and dl.vis and dl.vis.n then
      for i = 1, dl.vis.n do
	 local d = dl.vis[i]
	 if d and d.name then tinsert(v, { name = d.name }) end
      end
   end
   return v
end

-- k : place in radio_visuals(), 0 for none
function radio_apply_visual(r, k)
   local v = radio_visuals()
   local e = v[k]
   r.vis_idx = (e and k) or 0
   r.vis_check = nil
   if not e then
      set_visual("")
      if r.vis then radio_vis_set(r.vis, nil) end
   elseif e.lua then
      set_visual("")
      radio_vis_set(r.vis, e.lua)
   else
      if r.vis then radio_vis_set(r.vis, nil) end
      set_visual(e.name)
      r.vis_check = 0.6
   end
   r.vis_name = (e and e.name) or "off"
end

function radio_next_visual(r, d)
   local v = radio_visuals()
   local n = getn(v)
   if n == 0 then
      r.toast, r.toast_t = "No visualizer on this disc", 2
      return
   end
   local k = (r.vis_idx or 0) + d
   if k > n then k = 0 end
   if k < 0 then k = n end
   r.vis_dir = d
   r.vis_tries = (r.vis_tries or 0) + 1
   radio_apply_visual(r, k)
   r.toast, r.toast_t = "Visualizer : " .. r.vis_name, 2
   r.fav_changed = 1 -- saved with the favourites
end

-- Called a moment after a 3D visualizer was asked for : did it start ?
function radio_check_visual(r)
   local v = radio_visuals()
   local e = v[r.vis_idx or 0]
   r.vis_check = nil
   if not e or e.lua or set_visual() == e.name then
      r.vis_tries = 0
      return
   end
   if r.vis_tries < getn(v) then
      radio_next_visual(r, r.vis_dir or 1)
   else
      r.vis_tries = 0
      radio_apply_visual(r, 0)
   end
   r.dirty = 1
end

-- ----------------------------------------------------------------------
-- START : the pop-up menu. Everything the old dcplaya main menu had,
-- plus background and visualizer.
-- ----------------------------------------------------------------------

function radio_yesno(v)
   return (v and "yes") or "no"
end

-- The lines of one level of the menu. id : which level, arg : its detail.
function radio_menu_build(r, id, arg)
   local it = { n = 0 }
   local i
   if id == "root" then
      if rchat_menu_items then rchat_menu_items(r, it) end
      local net = "not connected"
      if net_connected and net_cfg and net_cfg.ip then net = net_cfg.ip end
      local vol = playa_volume and playa_volume()
      vol = (type(vol) == "number"
	     and format("%d%%", floor(vol * 100 + 0.5))) or "?"
      tinsert(it, { name = "Network settings", val = net, act = "net" })
      tinsert(it, { name = "Background", val = r.bg or "Original",
		 sub = "bg" })
      tinsert(it, { name = "Visualizer", val = r.vis_name or "off",
		 sub = "vis" })
      tinsert(it, { name = "Volume", val = "< " .. vol .. " >",
		 act = "vol" })
      if dash_menu_items then
	 tinsert(it, { name = "Connection test", act = "dashtest" })
	 tinsert(it, { name = "Dashboard", sub = "dash" })
      end
      tinsert(it, { name = "Memory card", sub = "vmu" })
      tinsert(it, { name = "Plugins", sub = "plugins" })
      tinsert(it, { name = "Keyboard on screen", sub = "kbd" })
      tinsert(it, { name = "Help", act = "help" })
      tinsert(it, { name = "About dcplaya", act = "about" })
      tinsert(it, { name = "Classic dcplaya menus", act = "classic" })
   elseif id == "bg" then
      local b = radio_backgrounds(r)
      for i = 1, getn(b) do
	 tinsert(it, { name = b[i].name, act = "setbg", arg = b[i].name,
		    on = (b[i].name == r.bg) })
      end
   elseif id == "vis" then
      local v = radio_visuals()
      tinsert(it, { name = "off", act = "setvis", arg = 0,
		 on = ((r.vis_idx or 0) == 0) })
      for i = 1, getn(v) do
	 tinsert(it, { name = v[i].name, act = "setvis", arg = i,
		    on = (r.vis_idx == i) })
      end
   elseif id == "vmu" then
      local cc = control_center
      tinsert(it, { name = "Save now", act = "vmusave" })
      tinsert(it, { name = "Save as ...", act = "vmusaveas" })
      tinsert(it, { name = "Load", act = "vmuload" })
      tinsert(it, { name = "Picture on its screen", sub = "vmuvis" })
      tinsert(it, { name = "Save by itself",
		 val = radio_yesno(type(cc) == "table" and cc.vmu_auto_save),
		 act = "vmuauto" })
      tinsert(it, { name = "Use the default file",
		 val = radio_yesno(not vmu_no_default_file),
		 act = "vmudef" })
      tinsert(it, { name = "Ask before writing",
		 val = radio_yesno(not vmu_never_confirm_write),
		 act = "vmuconf" })
   elseif id == "vmuvis" then
      local names = { "none", "scope", "fft", "band" }
      for i = 1, 4 do
	 tinsert(it, { name = names[i], act = "vmuvis", arg = i - 1 })
      end
   elseif id == "plugins" then
      tinsert(it, { name = "About the plugins", act = "plughelp" })
      local dl = get_driver_lists and get_driver_lists()
      if type(dl) == "table" then
	 local k, v
	 for k, v in dl do
	    if type(k) == "string" and v and v.n and v.n > 0 then
	       tinsert(it, { name = k, val = format("%d", v.n),
			  sub = "plugtype", arg = k })
	    end
	 end
      end
   elseif id == "plugtype" then
      local dl = get_driver_lists and get_driver_lists()
      local v = type(dl) == "table" and dl[arg]
      if v and v.n then
	 for i = 1, v.n do
	    local d = v[i]
	    if d and d.name then
	       tinsert(it, { name = d.name, act = "pluginfo",
			  arg = arg .. "/" .. d.name })
	    end
	 end
      end
   elseif id == "dash" then
      dash_menu_items(r, it)
   elseif id == "chathue" then
      rchat_menu_hues(r, it)
   elseif id == "kbd" then
      local rule = ke_set_active_rule and ke_set_active_rule()
      local ids = { "never", "normal", "nokbd" }
      local names = { "Never", "When needed", "When no keyboard is plugged" }
      for i = 1, 3 do
	 tinsert(it, { name = names[i], act = "kbd", arg = ids[i],
		    on = (rule == ids[i]) })
      end
   end
   return it
end

radio_menu_titles = {
   root = "MENU", bg = "BACKGROUND", vis = "VISUALIZER", vmu = "MEMORY CARD",
   vmuvis = "PICTURE ON ITS SCREEN", plugins = "PLUGINS",
   plugtype = "PLUGINS", kbd = "KEYBOARD ON SCREEN",
   chathue = "NAME COLOUR IN THE CHAT", dash = "DASHBOARD",
}

function radio_menu_push(r, id, arg)
   local lv = { id = id, arg = arg, pos = 1, top = 1 }
   lv.items = radio_menu_build(r, id, arg)
   -- start on the line that is the current choice
   local i
   for i = 1, getn(lv.items) do
      if lv.items[i].on then lv.pos = i end
   end
   tinsert(r.menu, lv)
end

function radio_menu_open(r)
   r.menu = { n = 0 }
   radio_menu_push(r, "root")
   r.dirty = 1
end

function radio_menu_close(r)
   r.menu = nil
   r.dirty = 1
   if r.fav_changed then
      radio_save_cfg(r)
   elseif r.dash and r.dash.changed and vmu_save then
      vmu_save(nil, 1)
   end
   if r.dash then r.dash.changed = nil end
end

function radio_menu_back(r)
   if not r.menu then return end
   tremove(r.menu)
   if getn(r.menu) == 0 then
      radio_menu_close(r)
   end
   r.dirty = 1
end

-- The values on the lines may have changed : read them again.
function radio_menu_refresh(r)
   if not r.menu then return end
   local i
   for i = 1, getn(r.menu) do
      local lv = r.menu[i]
      lv.items = radio_menu_build(r, lv.id, lv.arg)
      if lv.pos > getn(lv.items) then lv.pos = getn(lv.items) end
      if lv.pos < 1 then lv.pos = 1 end
   end
end

-- dir : 1 for A or right, -1 for left
function radio_menu_do(r, dir)
   local lv = r.menu and r.menu[getn(r.menu)]
   local item = lv and lv.items[lv.pos]
   if not item then return end
   local act = item.act

   if act == "vol" then
      local vol = playa_volume()
      if type(vol) == "number" then
	 vol = vol + dir * 0.1
	 if vol < 0 then vol = 0 end
	 if vol > 1 then vol = 1 end
	 playa_volume(vol)
      end
   elseif act and strsub(act, 1, 4) == "dash" then
      dash_menu_do(r, item, dir)
   elseif dir < 0 then
      radio_menu_back(r)
      return
   elseif item.sub then
      radio_menu_push(r, item.sub, item.arg)
   elseif act and strsub(act, 1, 4) == "chat" then
      rchat_menu_do(r, item)
      if act == "chathue" then radio_menu_back(r) end
   elseif act == "net" then
      if net_connect_dialog then radio_dialog(r, net_connect_dialog) end
   elseif act == "setbg" then
      radio_ask_background(r, item.arg)
   elseif act == "setvis" then
      r.vis_tries = 0
      radio_apply_visual(r, item.arg)
      r.fav_changed = 1
   elseif act == "bar" then
      r.bar_off = (not r.bar_off) or nil
      r.fav_changed = 1
   elseif act == "vmusave" then
      if vmu_save then radio_dialog(r, vmu_save, nil, 1) end
   elseif act == "vmusaveas" then
      if vmu_save_as then radio_dialog(r, vmu_save_as) end
   elseif act == "vmuload" then
      radio_dialog(r, radio_vmu_load)
   elseif act == "vmuvis" then
      if vmu_set_visual then vmu_set_visual(item.arg) end
   elseif act == "vmuauto" then
      if type(control_center) == "table" then
	 control_center.vmu_auto_save = not control_center.vmu_auto_save
      end
   elseif act == "vmudef" then
      vmu_no_default_file = not vmu_no_default_file
   elseif act == "vmuconf" then
      vmu_never_confirm_write = not vmu_never_confirm_write
   elseif act == "plughelp" then
      if gui_file_viewer then
	 radio_dialog(r, radio_plug_help)
      end
   elseif act == "pluginfo" then
      if plugin_viewer then
	 radio_dialog(r, plugin_viewer, nil, item.arg)
      end
   elseif act == "kbd" then
      if ke_set_active_rule then ke_set_active_rule(item.arg) end
   elseif act == "help" then
      r.menu = nil
      r.prev_mode = r.mode
      r.mode = "help"
   elseif act == "about" then
      if control_center_about then
	 radio_dialog(r, control_center_about, {})
      end
   elseif act == "classic" then
      r.menu = nil
      r.classic = 1
      if r.owner then evt_send(r.owner, { key = KBD_CONT1_Y }) end
   end
   radio_menu_refresh(r)
   r.dirty = 1
end

-- as the old menu did it
function radio_vmu_load()
   if not ram_path and ramdisk_init then ramdisk_init() end
   if not ram_path then return end
   local vmufile = vmu_file and vmu_file()
   if vmufile then
      deltree(ram_path .. "/dcplaya")
      vmu_load_file(vmufile, ram_path .. "/dcplaya")
   elseif vmu_init then
      vmu_init()
   end
end

function radio_plug_help()
   gui_file_viewer(nil, home .. "lua/rsc/text/plugins.txt", nil, "plugins")
end

function radio_menu_move(r, d)
   local lv = r.menu[getn(r.menu)]
   local n = getn(lv.items)
   if n == 0 then return end
   lv.pos = lv.pos + d
   if lv.pos < 1 then lv.pos = n end
   if lv.pos > n then lv.pos = 1 end
   r.dirty = 1
end

radio_menu_rows = 12

function radio_draw_menu(r)
   local dl = r.back
   local c = radio_col
   local lv = r.menu[getn(r.menu)]
   local n = getn(lv.items)
   local rows = (n < radio_menu_rows and n) or radio_menu_rows
   local w, rh = 400, 24
   local h = 44 + rows * rh + 10
   local x = 320 - w / 2
   local y = 228 - h / 2
   local i

   if lv.pos < lv.top then lv.top = lv.pos end
   if lv.pos >= lv.top + rows then lv.top = lv.pos - rows + 1 end
   if lv.top < 1 then lv.top = 1 end

   -- everything behind goes dark, the pop-up sits on top
   dl_draw_box1(dl, 0, 0, 640, 444, 40, 0.6, 0, 0, 0)
   dl_draw_box(dl, x, y, x+w, y+h, 42, 0.97, 0.16, 0.09, 0.02,
	       0.97, 0.05, 0.03, 0.02, 2)
   dl_draw_box1(dl, x, y, x+w, y+2, 44, 1, 1, 0.54, 0.10)
   dl_draw_box1(dl, x, y+h-2, x+w, y+h, 44, 1, 1, 0.54, 0.10)
   dl_draw_box1(dl, x, y, x+2, y+h, 44, 1, 1, 0.54, 0.10)
   dl_draw_box1(dl, x+w-2, y, x+w, y+h, 44, 1, 1, 0.54, 0.10)

   local title = radio_menu_titles[lv.id] or "MENU"
   if lv.id == "plugtype" and lv.arg then title = "PLUGINS : " .. lv.arg end
   dl_text_prop(dl, 0, 16)
   dl_draw_text(dl, x + 16, y + 12, 50, 1, 1, 0.60, 0.12, title)
   if n > rows then
      local t = format("%d / %d", lv.pos, n)
      dl_text_prop(dl, 0, 12)
      dl_draw_text(dl, x + w - 16 - radio_width(t, 12), y + 15, 50,
		   1, 0.91, 0.88, 0.78, t)
   end
   dl_draw_box1(dl, x + 12, y + 36, x + w - 12, y + 37, 44,
		1, 0.48, 0.29, 0.06)

   for i = 0, rows - 1 do
      local idx = lv.top + i
      local it = lv.items[idx]
      if it then
	 local ry = y + 44 + i * rh
	 local sel = (idx == lv.pos)
	 if sel then
	    dl_draw_box(dl, x + 8, ry, x + w - 8, ry + rh - 2, 46,
			1, 0.78, 0.42, 0.02, 1, 0.45, 0.22, 0, 1)
	 end
	 dl_text_prop(dl, 0, 16)
	 local cr, cg, cb = 1, 0.85, 0.29
	 if sel then cr, cg, cb = 1, 1, 1 end
	 if it.on then
	    dl_draw_text(dl, x + 16, ry + 4, 50, 1, 0.36, 1, 0.42, ">")
	 end
	 local val = it.val
	 if it.sub and not val then val = "+" end
	 dl_draw_text(dl, x + 34, ry + 4, 50, 1, cr, cg, cb,
		      radio_fit(it.name, 16, (it.val and 210) or 330))
	 if val then
	    val = radio_fit(val, 14, 150)
	    dl_text_prop(dl, 0, 14)
	    if sel then
	       dl_draw_text(dl, x + w - 18 - radio_width(val, 14), ry + 5,
			    50, 1, 1, 1, 1, val)
	    else
	       dl_draw_text(dl, x + w - 18 - radio_width(val, 14), ry + 5,
			    50, 1, 0.91, 0.88, 0.78, val)
	    end
	 end
	 radio_hit(r, x + 8, ry, w - 16, rh, "mrow", idx)
      end
   end

   radio_draw_hints(r, {
		       { "A", "Choose", "a" },
		       { "B", "Back", "b" },
		       { "< >", "Change", nil },
		       { "Start", "Close", "menu" },
		    })
end

-- ----------------------------------------------------------------------
-- views
-- ----------------------------------------------------------------------

function radio_now(r)
   local name = r.now and r.now.name
   local song, fmt
   local info = r.playing and r.info
   if type(info) == "table" then
      local t, a = info.title, info.artist
      if t == "N/A" or t == "" then t = nil end
      if a == "N/A" or a == "" then a = nil end
      if t and name and t == name then t = nil end
      -- with no tag the player makes a title from the file name : not a song
      if t and r.now and r.now.url
	 and strfind(strlower(r.now.url), "/" .. strlower(t), 1, 1) then
	 t = nil
      end
      if t and a then song = a .. " - " .. t else song = t or a end
      fmt = info.format
      if fmt == "N/A" then fmt = nil end
   end
   return name, song, fmt
end

-- Bottom line : what each button does. Each entry can be clicked.
function radio_draw_hints(r, hints)
   local dl = r.back
   local c = radio_col
   -- with the pop-up open only its own line of buttons is shown
   if r.menu then
      if r.hints_done then return end
      if hints[1][2] ~= "Choose" then return end
      r.hints_done = 1
   end
   -- a solid bar, so the visualizer behind never washes the text out
   radio_box(dl, 0, 442, 640, 38, 5, radio_bar)
   radio_box(dl, 0, 442, 640, 1, 6, c.dark)
   local x = 24
   local i
   for i = 1, getn(hints) do
      local h = hints[i]
      local kw = radio_width(h[1], 12) + 12
      local lw = radio_width(h[2], 14)
      -- key cap : dark, orange edge, bright letter
      radio_frame(dl, x, 451, kw, 19, radio_cap, c.frame)
      radio_text(dl, x + 6, 454, 12, c.star, h[1])
      radio_text(dl, x + kw + 7, 453, 14, c.dim, h[2])
      radio_hit(r, x - 4, 446, kw + lw + 14, 30, "key", h[3])
      x = x + kw + lw + 24
   end
end

function radio_draw_clock(r)
   local c = radio_col
   radio_text(r.back, 470, 20, 24, (r.playing and c.text) or c.dark,
	      (r.playing and (r.time or "--:--")) or "STOPPED")
end

function radio_draw_main(r)
   local dl = r.back
   local c = radio_col
   local name, song, fmt = radio_now(r)

   if dash_draw_status then dash_draw_status(r) end
   radio_box(dl, 0, 78, 640, 112, 5, c.shade)
   radio_text(dl, 40, 86, 14, c.label, "NOW PLAYING")
   -- playing time (or stopped) on the right of the panel
   local st = (r.playing and (r.time or "--:--")) or "STOPPED"
   radio_text(dl, 600 - radio_width(st, 16), 85, 16,
	      (r.playing and c.text) or c.dark, st)
   if name then
      local size = 30
      if radio_width(name, size) > 560 then size = 22 end
      radio_text(dl, 40, 106, size, c.white, radio_fit(name, size, 560))
   else
      radio_text(dl, 40, 110, 22, c.white,
		 "Nothing yet : L for your music, X to browse")
   end
   if song then
      radio_text(dl, 40, 142, 20, c.green, radio_fit(song, 20, 560))
   end
   if fmt then
      radio_text(dl, 40, 168, 12, c.dim, radio_fit(fmt, 12, 560))
   end
   if r.toast then
      local w = radio_width(r.toast, 16) + 24
      radio_frame(dl, 40, 204, w, 28, c.fill, c.dark)
      radio_text(dl, 52, 210, 16, c.text, r.toast)
   end

   if not dash_draw_dock then return end
   local d = r.dash
   if r.menu then
      -- the pop-up has its own line of buttons at the bottom
      dash_draw_status(r)
      return
   end
   if not d.panel then
      dash_draw_keys(r, {
			{ "A", "Open", "a" },
			{ "L", "My music", "l" },
			{ "R", "Live", "r" },
			{ "X", "Browse", "x" },
			{ "^v", "Visualizer", "v" },
			{ "Y", "Hide", "y" },
			{ "START", "Menu", "menu" },
		     }, 410)
   else
      dash_draw_keys(r, {
			{ "A", "Choose", "a" },
			{ "^v", "Move", nil },
			{ "B", "Close", "b" },
		     }, 410)
   end
   dash_draw_dock(r)
   dash_draw_panel(r)
   dash_draw_banner(r, 372)
end

function radio_draw_browse(r)
   local dl = r.back
   local c = radio_col
   local i
   local items = radio_items(r)
   local n = getn(items)
   local s = r.sec

   -- sections
   local x = 24
   for i = 1, radio_nsec do
      local w = radio_width(radio_sections[i], 14) + 24
      local act = (i == s)
      radio_frame(dl, x, 22, w, 26, (act and c.sel) or c.fill,
		  (act and c.frame) or c.dark, (act and c.sel2) or c.fill2)
      radio_text(dl, x+12, 28, 14, (act and c.white) or c.dim,
		 radio_sections[i])
      radio_hit(r, x, 22, w, 26, "sec", i)
      x = x + w + 6
   end
   radio_draw_clock(r)

   -- list
   radio_frame(dl, 24, 60, 592, 306, c.fill, c.frame, c.fill2)
   local head
   if r.search then
      head = "Find : " .. r.search .. "_"
   elseif s == 3 then
      head = r.fpath or "/"
      if head == "/" then head = "Choose where to look" end
   elseif s == 4 then
      head = "A changes or opens a line"
   elseif s == 2 then
      head = "Your favourites : also in My music (L) and on keys 1-5"
   else
      head = format("%d stations", n)
   end
   radio_text(dl, 36, 68, 12, (r.search and c.white) or c.label,
	      radio_fit(head, 12, 500))
   if n > 0 then
      local t = format("%d / %d", r.pos[s], n)
      radio_text(dl, 604 - radio_width(t, 12), 68, 12, c.dim, t)
   end
   radio_box(dl, 34, 85, 572, 1, 15, c.dark)

   if n == 0 then
      local msg = "Nothing here"
      if s == 2 then msg = "No favourites yet : press X on a station" end
      if s == 1 then msg = "No station list on this disc" end
      radio_text(dl, 44, radio_list_y + 8, 16, c.dim, msg)
   end
   for i = 0, radio_rows - 1 do
      local idx = r.top[s] + i
      local it = items[idx]
      if it then
	 local y = radio_list_y + i * radio_row_h
	 local sel = (idx == r.pos[s])
	 local playing = r.now and it.url and it.url == r.now.url
	    and r.playing
	 if sel then
	    radio_grad(dl, 30, y-1, 568, radio_row_h - 1, 15,
		       c.sel, c.sel2, 1)
	 end
	 local col = (sel and c.white) or (playing and c.green) or c.text
	 local mark
	 if it.kind == "dir" or it.kind == "list" then
	    mark = "+"
	 elseif playing then
	    mark = ">"
	 elseif it.url and radio_find_url(r.fav, it.url) then
	    mark = "*"
	 end
	 if mark then
	    radio_text(dl, 37, y+2, 16,
		       (sel and c.white) or (playing and c.green) or c.star,
		       mark)
	 end
	 radio_text(dl, 56, y+2, 16, col, radio_fit(it.name, 16, 530))
	 radio_hit(r, 30, y-1, 568, radio_row_h, "row", idx)
      end
   end
   -- scroll bar
   if n > radio_rows then
      local th = radio_rows * radio_row_h - 2
      local bh = floor(th * radio_rows / n)
      if bh < 12 then bh = 12 end
      local by = floor((th - bh) * (r.top[s] - 1) / (n - radio_rows))
      radio_box(dl, 603, radio_list_y, 5, th, 15, c.dark)
      radio_box(dl, 603, radio_list_y + by, 5, bh, 16, c.frame)
   end

   -- now playing
   local name, song = radio_now(r)
   radio_frame(dl, 24, 376, 592, 58, c.fill, c.dark, c.fill2)
   radio_text(dl, 36, 382, 12, c.label, "NOW PLAYING")
   if name and r.playing then
      radio_text(dl, 36, 398, 16, c.green, radio_fit(song or name, 16, 568))
      if song then
	 radio_text(dl, 36, 418, 12, c.dim, radio_fit(name, 12, 568))
      end
   else
      radio_text(dl, 36, 400, 16, c.dim, "Nothing playing")
   end
   radio_hit(r, 24, 376, 592, 58, "key", "b")

   local it = items[r.pos[s]]
   local a = "Play"
   if it and (it.kind == "dir" or it.kind == "list") then a = "Open" end
   if it and it.kind == "setting" then a = "Change" end
   local xh = { "X", "Favourite", "x" }
   if s == 4 then xh = { "X", "Back a step", "x" } end
   radio_draw_hints(r, {
		       { "A", a, "a" },
		       xh,
		       { "< >", "Section", "sec" },
		       { "B", (s == 3 and r.fpath ~= "/" and "Up") or "Back",
			  "b" },
		       { "Start", "Menu", "menu" },
		    })
end

radio_help_text = {
   { "CONTROLLER" },
   { "A", "Open the app on the bar, play, or change the line" },
   { "B", "Back, one folder up, or stop the music" },
   { "X", "Browse; in a list : add or remove a favourite" },
   { "Y", "Hide the screen and leave the visualizer" },
   { "START", "The menu : network, background, visualizer, memory card" },
   { "L  R", "L : my music (favourites, recent).  R : live, who is online" },
   { "D-pad", "Home : left, right the app bar; up, down the visualizer" },
   { "KEYBOARD" },
   { "Enter Esc", "A and B.  Backspace is X.  F1 help  F2 menu  F3 F6 L R" },
   { "F4", "Chat : IRC #dc99 and KosNet (also in the START menu)" },
   { "Letters", "In a list, type the start of a name to jump to it" },
   { "1 to 5", "Play that favourite.  Space plays or stops" },
   { "PgUp PgDn", "A page up or down.  Home, End.  Tab : next section" },
   { "MOUSE" },
   { "Left", "Play or open what is under the pointer" },
   { "Right", "Back.  The wheel scrolls a list" },
}

function radio_draw_help(r)
   local dl = r.back
   local c = radio_col
   local i
   radio_text(dl, 28, 26, 22, c.white, "HELP")
   radio_draw_clock(r)
   radio_frame(dl, 24, 60, 592, 374, c.fill, c.frame, c.fill2)
   local y = 70
   local txt = radio_help_text
   if r.prev_mode == "chat" and rchat_help_text then txt = rchat_help_text end
   for i = 1, getn(txt) do
      local h = txt[i]
      if not h[2] then
	 y = y + 4
	 radio_text(dl, 36, y, 12, c.label, h[1])
	 y = y + 18
      else
	 radio_text(dl, 44, y, 14, c.star, h[1])
	 radio_text(dl, 150, y, 14, c.text, radio_fit(h[2], 14, 452))
	 y = y + 22
      end
   end
   radio_hit(r, 24, 60, 592, 374, "key", "b")
   radio_draw_hints(r, {
		       { "B", "Back", "b" },
		    })
end

-- A box around what the pointer is on, when a click would do something.
function radio_draw_hover(r)
   local h = r.mouse_on and r.hover
   if not h then return end
   local dl = r.back
   local x1, y1, x2, y2 = h[1], h[2], h[3], h[4]
   dl_draw_box1(dl, x1, y1, x2, y2, 70, 0.22, 1, 1, 1)
   dl_draw_box1(dl, x1, y1, x2, y1 + 2, 71, 1, 1, 1, 1)
   dl_draw_box1(dl, x1, y2 - 2, x2, y2, 71, 1, 1, 1, 1)
   dl_draw_box1(dl, x1, y1, x1 + 2, y2, 71, 1, 1, 1, 1)
   dl_draw_box1(dl, x2 - 2, y1, x2, y2, 71, 1, 1, 1, 1)
end

-- Draw in the list that is not on screen, then swap : nothing flashes.
function radio_draw(r)
   dl_clear(r.back)
   r.hits = { n = 0 }
   r.hints_done = nil
   if r.mode == "browse" then
      radio_draw_browse(r)
   elseif r.mode == "chat" and radio_draw_chat then
      radio_draw_chat(r)
   elseif r.mode == "online" and radio_draw_online then
      radio_draw_online(r)
   elseif r.mode == "diag" and radio_draw_diag then
      radio_draw_diag(r)
   elseif r.mode == "weather" and radio_draw_weather then
      radio_draw_weather(r)
   elseif r.mode == "help" then
      radio_draw_help(r)
   else
      radio_draw_main(r)
   end
   if dash_draw_banner and not r.menu and r.mode ~= "main" then
      dash_draw_banner(r, 404)
   end
   if r.menu then
      radio_draw_menu(r)
   end
   radio_draw_hover(r)
   if r.busy then
      local c = radio_col
      local w = radio_width(r.busy, 16) + 48
      radio_frame(r.back, 320 - w/2, 216, w, 48, c.black, c.frame)
      dl_text_prop(r.back, 0, 16)
      dl_draw_text(r.back, 320 - w/2 + 24, 232, 60, 1, 1, 1, 1, r.busy)
   end
   dl_set_active2(r.back, r.front, 1)
   r.back, r.front = r.front, r.back
   r.dirty = nil
end

-- Show or hide this screen; the other dcplaya panels do the opposite.
function radio_show(r, on)
   r.shown = on
   if on then
      r.classic = nil
      if song_browser then song_browser:close() end
      if song_info then song_info:close() end
      if fifo_tracker then
	 if not r.ft_mode then r.ft_mode = fifo_tracker.hidden_mode end
	 fifo_tracker.hidden_mode = 2
      end
      r.dirty = 1
   else
      dl_set_active2(r.back, r.front, 0)
      dl_set_active(r.cursor, 0)
      -- the old panels come back only when "Classic dcplaya menus" was
      -- chosen; a viewer or a dialog opened from our menu leaves them asleep
      if r.classic then
	 if r.vis then radio_vis_hide(r.vis) end
	 if song_browser then song_browser:open() end
	 if song_info then song_info:open() end
	 if fifo_tracker then fifo_tracker.hidden_mode = r.ft_mode or 1 end
	 r.ft_mode = nil
      end
   end
end

-- ----------------------------------------------------------------------
-- actions shared by the controller, the keyboard and the mouse
-- ----------------------------------------------------------------------

function radio_main_confirm(r)
   if radio_is_playing() then
      radio_stop(r)
   elseif r.now then
      radio_play_item(r, r.now, r.queue, r.qpos)
   else
      r.mode = "browse"
      radio_set_section(r, r.list_sec or 1)
   end
end

function radio_browse_select(r)
   local items = radio_items(r)
   local it = items[r.pos[r.sec]]
   if it and it.kind == "setting" then
      radio_setting(r, it.id, -1)
   elseif it and it.url then
      radio_toggle_fav(r, it)
      radio_clamp(r)
   end
end

-- Y : leave only the visualizer on screen. Any button brings us back.
function radio_hud(r, on)
   r.hud_off = (not on) or nil
   if on then
      r.dirty = 1
   else
      dl_set_active2(r.back, r.front, 0)
      dl_set_active(r.cursor, 0)
      r.mouse_on = nil
   end
end

-- name : "a" "b" "x" "y" "sec" "v"
function radio_action(r, name)
   if r.mode == "chat" and not r.menu and name ~= "menu" and rchat_action then
      rchat_action(r, name)
      return
   end
   if r.mode == "online" and not r.menu and name ~= "menu" and dash_online_action then
      dash_online_action(r, name)
      return
   end
   if r.mode == "diag" and not r.menu and name ~= "menu" and dash_diag_action then
      dash_diag_action(r, name)
      return
   end
   if r.mode == "weather" and not r.menu and name ~= "menu" and wx_action then
      wx_action(r, name)
      return
   end
   if r.mode == "main" and not r.menu and r.dash and (name == "l" or name == "r") then
      dash_panel(r, name)
      return
   end
   if r.mode == "main" and not r.menu and r.dash and r.dash.panel
      and name ~= "menu" and name ~= "y" then
      if name == "b" then dash_panel(r, nil)
      elseif name == "a" then dash_key(r, KBD_CONT1_A) end
      r.dirty = 1
      return
   end
   if name == "y" then
      radio_hud(r, nil)
      return
   end
   if name == "menu" then
      if r.menu then radio_menu_close(r) else radio_menu_open(r) end
      return
   end
   if name == "bar" then
      r.bar_off = (not r.bar_off) or nil
      radio_save_cfg(r, 1)
      r.dirty = 1
      return
   end
   if r.menu then
      if name == "a" then radio_menu_do(r, 1)
      elseif name == "b" then radio_menu_back(r)
      end
      r.dirty = 1
      return
   end
   if r.mode == "help" then
      r.mode = r.prev_mode or "main"
      r.dirty = 1
      return
   end
   if r.mode == "browse" then
      if name == "a" then radio_activate(r)
      elseif name == "b" then radio_back(r)
      elseif name == "x" then radio_browse_select(r)
      elseif name == "sec" then radio_set_section(r, r.sec + 1)
      end
   else
      if name == "a" then
	 if r.dash then dash_open_app(r, dash_apps[r.dash.dock].id)
	 else radio_main_confirm(r) end
      elseif name == "b" then if radio_is_playing() then radio_stop(r) end
      elseif name == "x" then
	 r.mode = "browse"
	 radio_set_section(r, r.list_sec or 1)
      elseif name == "v" then radio_next_visual(r, 1)
      end
   end
   r.dirty = 1
end

-- ----------------------------------------------------------------------
-- mouse
-- ----------------------------------------------------------------------

function radio_hit_at(r, x, y)
   local i
   for i = getn(r.hits), 1, -1 do
      local h = r.hits[i]
      if x >= h[1] and x < h[3] and y >= h[2] and y < h[4] then
	 return h
      end
   end
end

function radio_mouse(r, frametime)
   if not mouse_get then return end
   local dx, dy, dz, lb, rb, click, rclick = mouse_get()
   if not dx then
      if r.mouse_on then
	 r.mouse_on = nil
	 dl_set_active(r.cursor, 0)
      end
      return
   end
   local moved = (dx ~= 0 or dy ~= 0)
   if moved then
      r.mx = r.mx + dx
      r.my = r.my + dy
      if r.mx < 0 then r.mx = 0 end
      if r.mx > 639 then r.mx = 639 end
      if r.my < 0 then r.my = 0 end
      if r.my > 479 then r.my = 479 end
      dl_set_trans(r.cursor, mat_trans(r.mx, r.my, radio_z))
   end
   click = (click == 1) or nil
   rclick = (rclick == 1) or nil
   if r.hud_off then
      if moved or click or rclick then radio_hud(r, 1) end
      return
   end
   if moved or click or rclick or dz ~= 0 then
      r.mouse_idle = 0
      if not r.mouse_on then
	 r.mouse_on = 1
	 dl_set_active(r.cursor, 1)
      end
   else
      r.mouse_idle = (r.mouse_idle or 0) + frametime
      if r.mouse_on and r.mouse_idle > 6 then
	 r.mouse_on = nil
	 dl_set_active(r.cursor, 0)
      end
   end

   -- pointing at something selects it
   local h = (moved or click) and radio_hit_at(r, r.mx, r.my)
   if h and r.menu and h.kind ~= "mrow" and h.kind ~= "key" then
      h = nil -- the pop-up is in front of the rest
   end
   if h and r.dash and r.dash.panel and h.kind ~= "dprow" and h.kind ~= "key"
      and r.mode == "main" then
      h = nil -- so is a side panel
   end
   if h and h.kind == "key" and not h.arg then
      h = nil -- a hint that is only a reminder
   end
   if moved or click then
      local o = r.hover
      if (h and not o) or (o and not h)
	 or (h and o and (h[1] ~= o[1] or h[2] ~= o[2])) then
	 r.hover = h
	 r.dirty = 1
      end
   end
   if h then
      if h.kind == "mrow" then
	 local lv = r.menu and r.menu[getn(r.menu)]
	 if lv and lv.pos ~= h.arg then
	    lv.pos = h.arg
	    r.dirty = 1
	 end
      elseif h.kind == "row" and r.pos[r.sec] ~= h.arg then
	 r.pos[r.sec] = h.arg
	 r.dirty = 1
      elseif strsub(h.kind or "", 1, 1) == "d" and dash_hover then
	 dash_hover(r, h)
      end
   end
   if click and h then
      if h.kind == "mrow" then
	 radio_action(r, "a")
      elseif h.kind == "row" then
	 radio_action(r, "a")
      elseif h.kind == "slot" then
	 radio_action(r, "a")
      elseif h.kind == "sec" then
	 radio_set_section(r, h.arg)
	 r.dirty = 1
      elseif h.kind == "key" and h.arg then
	 radio_action(r, h.arg)
      elseif strsub(h.kind or "", 1, 1) == "c" and rchat_click then
	 rchat_click(r, h)
      elseif strsub(h.kind or "", 1, 1) == "d" and dash_click then
	 dash_click(r, h)
      end
   end
   if rclick then
      radio_action(r, "b")
   end
   if dz ~= 0 and r.menu then
      radio_menu_move(r, (dz > 0 and 1) or -1)
   elseif dz ~= 0 and r.mode == "online" and dash_online_key then
      dash_online_key(r, (dz > 0 and KBD_KEY_PGDOWN) or KBD_KEY_PGUP)
   elseif dz ~= 0 and r.mode == "chat" and rchat_scroll then
      rchat_scroll(r, (dz > 0 and -3) or 3)
   elseif dz ~= 0 and r.mode == "browse" then
      radio_move(r, (dz > 0 and 3) or -3)
      r.dirty = 1
   end
end

function radio_make_cursor(r)
   local dl = dl_new_list(1024, 0)
   local i
   local c = radio_col
   -- an arrow made of lines, dark edge under a white body
   for i = 0, 13 do
      local w = (i < 10 and i + 1) or (14 - i) * 2
      dl_draw_box1(dl, -1, i-1, w + 1, i + 2, 60, 1, 0, 0, 0)
   end
   for i = 0, 13 do
      local w = (i < 10 and i + 1) or (14 - i) * 2
      dl_draw_box1(dl, 0, i, w, i + 1, 61, 1, 1, 1, 1)
   end
   dl_set_trans(dl, mat_trans(r.mx, r.my, radio_z))
   r.cursor = dl
end

-- ----------------------------------------------------------------------
-- application
-- ----------------------------------------------------------------------

-- L or R on the controller : favourites bar on or off.
function radio_triggers(r)
   if not controler_read then return end
   r.trig_n = (r.trig_n or 0) + 1
   if mod(r.trig_n, 4) ~= 0 then return end
   local c = controler_read(1)
   if type(c) ~= "table" then return end
   local l = ((c.ltrig or 0) > 0.5) or nil
   local rt = ((c.rtrig or 0) > 0.5) or nil
   if l and not r.ltrig_down and dash_trigger then dash_trigger(r, "l") end
   if rt and not r.rtrig_down and dash_trigger then dash_trigger(r, "r") end
   r.ltrig_down, r.rtrig_down = l, rt
end

function radio_update(r, frametime)
   if rchat_update then rchat_update(r, frametime) end
   if dash_update then dash_update(r, frametime) end
   if wx_update then wx_update(r, frametime) end
   if r.modal then return end
   local foc = (r.owner and r.owner.sub == r) or nil
   if not foc and not r.classic and r.owner then
      -- a viewer opened from our menu was closed and one of the old panels
      -- inherited the focus : take it back
      local sub = r.owner.sub
      if sub and (sub == song_browser or sub == song_info
		  or sub == control_center or sub == fifo_tracker) then
	 gui_new_focus(r.owner, r)
	 foc = 1
      end
   end
   if foc ~= r.shown then
      radio_show(r, foc)
   end
   if not r.shown then return end

   if r.vis then radio_vis_update(r.vis, frametime) end
   if r.bg_pending then
      r.bg_wait = r.bg_wait - 1
      if r.bg_wait <= 0 then
	 radio_set_background(r, r.bg_pending)
	 r.bg_pending, r.busy = nil, nil
	 r.dirty = 1
      end
   end
   radio_mouse(r, frametime)
   radio_triggers(r)
   if r.hud_off then return end

   if r.vis_check then
      r.vis_check = r.vis_check - frametime
      if r.vis_check <= 0 then radio_check_visual(r) end
   end
   if r.toast_t then
      r.toast_t = r.toast_t - frametime
      if r.toast_t <= 0 then
	 r.toast, r.toast_t = nil, nil
	 r.dirty = 1
      end
   end
   if r.search then
      r.search_t = (r.search_t or 0) + frametime
      if r.search_t > 4 then
	 r.search = nil
	 r.dirty = 1
      end
   end

   r.elapsed = r.elapsed + frametime
   if r.elapsed > 0.5 then
      if r.started then
	 r.started = r.started - r.elapsed
	 if r.started <= 0 then r.started = nil end
      end
      r.elapsed = 0
      local p = radio_is_playing() or nil
      local s, t = playtime()
      local id = playa_info_id()
      if r.playing and not p and not r.stopped and not r.started
	 and r.now and r.now.kind == "file" then
	 -- the file reached its end
	 if radio_next(r) then p = 1 end
      end
      if id ~= r.info_id then
	 r.info = playa_info(1)
      end
      if p ~= r.playing or t ~= r.time or id ~= r.info_id then
	 r.playing, r.time, r.info_id = p, t, id
	 r.dirty = 1
      end
   end
   if r.dirty then
      radio_draw(r)
   end
end

function radio_handle(r, evt)
   local key = evt.key

   if key == evt_shutdown_event then
      dl_set_active2(r.back, r.front, 0)
      dl_set_active(r.cursor, 0)
      return evt
   elseif key == gui_focus_event or key == gui_unfocus_event then
      return
   end
   if not r.shown or r.modal then return evt end
   if type(key) ~= "number" then return evt end

   if r.hud_off then
      -- any button brings the screen back
      radio_hud(r, 1)
      return
   end
   if key == KBD_CONT1_START or key == KBD_CONT2_START
      or key == KBD_CONT3_START or key == KBD_CONT4_START
      or key == KBD_KEY_F2 then
      radio_action(r, "menu")
      return
   end
   if key == KBD_KEY_F1 then
      r.menu = nil
      if r.mode ~= "help" then r.prev_mode = r.mode end
      r.mode = "help"
      r.dirty = 1
      return
   end
   if (key == KBD_KEY_F3 or key == KBD_KEY_F6) and r.dash then
      if r.mode ~= "main" or r.menu then
	 r.menu = nil
	 if r.mode == "chat" and rchat_close then rchat_close(r) end
	 r.mode = "main"
      end
      dash_key(r, key)
      r.dirty = 1
      return
   end
   if key == KBD_KEY_F4 and r.chat then
      if r.mode == "chat" then rchat_close(r) else rchat_open(r) end
      return
   end
   if r.mode == "chat" and not r.menu and rchat_key then
      rchat_key(r, key)
      r.dirty = 1
      return
   end
   if r.mode == "online" and not r.menu and dash_online_key then
      dash_online_key(r, key)
      return
   end
   if r.mode == "diag" and not r.menu and dash_diag_key then
      dash_diag_key(r, key)
      return
   end
   if r.mode == "weather" and not r.menu and wx_key then
      wx_key(r, key)
      return
   end
   if r.mode == "main" and not r.menu and r.dash and dash_key(r, key) then
      r.dirty = 1
      return
   end
   if gui_keymenu[key] then
      radio_hud(r, nil)
      return
   end
   if r.mode == "help" then
      r.mode = r.prev_mode or "main"
      r.dirty = 1
      return
   end
   if r.menu then
      if gui_keyup[key] then radio_menu_move(r, -1)
      elseif gui_keydown[key] then radio_menu_move(r, 1)
      elseif gui_keyconfirm[key] or gui_keyright[key] then
	 radio_menu_do(r, 1)
      elseif gui_keyleft[key] then radio_menu_do(r, -1)
      elseif gui_keycancel[key] then radio_menu_back(r)
      elseif key == KBD_KEY_PGUP then radio_menu_move(r, -5)
      elseif key == KBD_KEY_PGDOWN then radio_menu_move(r, 5)
      end
      return
   end

   if r.mode == "browse" then
      -- typed text looks for a line
      if key >= 32 and key < 127 and key ~= 96
	 and (r.search or key ~= 32) then
	 r.search = (r.search or "") .. strlower(strchar(key))
	 r.search_t = 0
	 radio_search(r)
      elseif key == KBD_BACKSPACE and r.search then
	 local n = strlen(r.search)
	 r.search = (n > 1 and strsub(r.search, 1, n-1)) or nil
	 r.search_t = 0
	 radio_search(r)
      elseif gui_keyup[key] then
	 r.search = nil
	 radio_move(r, -1, 1)
      elseif gui_keydown[key] then
	 r.search = nil
	 radio_move(r, 1, 1)
      elseif key == KBD_KEY_PGUP then
	 radio_move(r, -radio_rows)
      elseif key == KBD_KEY_PGDOWN then
	 radio_move(r, radio_rows)
      elseif key == KBD_KEY_HOME then
	 radio_move(r, -100000)
      elseif key == KBD_KEY_END then
	 radio_move(r, 100000)
      elseif gui_keyleft[key] then
	 radio_set_section(r, r.sec - 1)
      elseif gui_keyright[key] or key == KBD_KEY_TAB then
	 radio_set_section(r, r.sec + 1)
      elseif gui_keyconfirm[key] then
	 radio_activate(r)
      elseif gui_keyselect[key] or key == KBD_KEY_INSERT then
	 radio_browse_select(r)
      elseif gui_keycancel[key] then
	 radio_back(r)
      else
	 return evt
      end
      r.dirty = 1
      return
   end

   -- main view (left, right and A : the app bar, in radio_dash.lua)
   if gui_keyup[key] then
      radio_next_visual(r, 1)
   elseif gui_keydown[key] then
      radio_next_visual(r, -1)
   elseif key >= 49 and key <= 48 + radio_max_slots then
      -- keyboard 1..5 : that favourite, now
      r.slot = key - 48
      if r.fav[r.slot] then radio_play_item(r, r.fav[r.slot]) end
   elseif gui_keyconfirm[key] or key == 32 then
      radio_main_confirm(r)
   elseif gui_keyselect[key] or key == KBD_KEY_TAB then
      r.mode = "browse"
      radio_set_section(r, r.list_sec or 1)
   elseif gui_keycancel[key] then
      if radio_is_playing() then radio_stop(r) end
   else
      return evt
   end
   r.dirty = 1
end

function radio_create(owner)
   owner = owner or evt_desktop_app
   local r = {
      name = "radio",
      version = 2.0,
      handle = radio_handle,
      update = radio_update,
      icon_name = "song-browser",
      z = gui_guess_z(owner),
      mode = "main",
      slot = 1,
      sec = 1,
      pos = { 1, 1, 1, 1 },
      top = { 1, 1, 1, 1 },
      fhist = { n = 0 },
      hits = { n = 0 },
      elapsed = 1,
      mx = 320,
      my = 240,
   }
   r.front = dl_new_list(65536, 0)
   r.back = dl_new_list(65536, 0)
   dl_set_trans(r.front, mat_trans(0, 0, radio_z))
   dl_set_trans(r.back, mat_trans(0, 0, radio_z))
   radio_make_cursor(r)
   r.st = radio_load_list(radio_list_filename)
   radio_load_cfg(r)
   if rchat_init then rchat_init(r) end
   if dash_init then dash_init(r) end
   if wx_init and r.dash then wx_init(r) end
   if r.bg and strlower(r.bg) ~= "original" then
      radio_set_background(r, r.bg)
   end
   r.bg = r.bg or "Original"
   -- the visualizer chosen last time, or the classic bars
   if radio_vis_create then
      r.vis = radio_vis_create(radio_z - 80)
   end
   -- (a test disc can name the visualizer to start with)
   if radio_test_vis then r.vis_saved = radio_test_vis end
   local v = radio_visuals()
   local k, i = 1, nil
   for i = 1, getn(v) do
      if r.vis_saved and v[i].name == r.vis_saved then k = i end
   end
   if r.vis_saved == "off" then k = 0 end
   radio_apply_visual(r, k)
   evt_app_insert_first(owner, r)
   return r
end

function radio_kill()
   if radio_app then
      evt_shutdown_app(radio_app)
      radio_app = nil
   end
end

radio_kill()
radio_app = radio_create()
radio_loaded = 1
return radio_loaded
