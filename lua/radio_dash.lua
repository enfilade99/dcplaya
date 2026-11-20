--- @file     radio_dash.lua
--- @date     2026/11/18
--- @brief    DCPlaya home dashboard : status line, app bar, notifications,
---           the L and R panels and the Online screen.
---
--- Home keeps what is playing over the visualizer. Around it :
---  - top line   : players online (Dreamcast Now, DCNet), IRC, date, time
---  - app bar    : Favourites, Radio, Chat, Online, Settings (left/right, A)
---  - L panel    : My music (favourites, recently played)
---  - R panel    : Live (counts, who is playing, notifications, chat)
---  - notes      : chat mentions, private messages, players coming online
--- The numbers come from the server's plain-text feed (?s=online), read
--- quietly in the background : nothing waits for it, nothing pops up.

dash_cfg_filename = "/ram/dcplaya/configs/dash.cfg"
dash_every_home = 60    -- seconds between two reads, home screen
dash_every_online = 20  -- the Online screen is open
dash_max_notes = 12
dash_rows = 12
dash_row_h = 22

dash_apps = {
   { name = "FAVOURITES", id = "fav" },
   { name = "RADIO", id = "radio" },
   { name = "CHAT", id = "chat" },
   { name = "ONLINE", id = "online" },
   { name = "WEATHER", id = "weather" },
   { name = "SETTINGS", id = "settings" },
}

dash_shade = { 0.80, 0.00, 0.00, 0.00 }

dash_days = { "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" }
dash_months = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG",
		"SEP", "OCT", "NOV", "DEC" }

-- ----------------------------------------------------------------------
-- settings
-- ----------------------------------------------------------------------

function dash_init(r)
   local d = {
      dp = -1, dn = -1, irc = -1,
      people = { n = 0 }, games = { n = 0 },
      notes = { n = 0 }, unread = 0,
      dock = 2,
      fetch_t = 3,
      sec = 1, pos = { 1, 1 }, top = { 1, 1 },
      lsel = 1, rsel = 1, anim = 0,
      cfg = { clock = 0, tz = 99, counts = 1, alerts = 1, wx_f = 0 },
      recent = { n = 0 },
   }
   dash_saved = nil
   local file = openfile(dash_cfg_filename, "r")
   if file then
      closefile(file)
      dofile(dash_cfg_filename)
   end
   if type(dash_saved) == "table" then
      local k, v
      for k, v in dash_saved do
	 if type(d.cfg[k]) == "number" and type(v) == "number" then
	    d.cfg[k] = v
	 end
      end
      if type(dash_saved.wx_lat) == "string" then
	 d.cfg.wx_name = dash_saved.wx_name or ""
	 d.cfg.wx_lat = dash_saved.wx_lat
	 d.cfg.wx_lon = dash_saved.wx_lon or "0"
      end
      if type(dash_saved.recent) == "table" then
	 local i
	 for i = 1, getn(dash_saved.recent) do
	    local it = dash_saved.recent[i]
	    if type(it) == "table" and it.url then
	       tinsert(d.recent, { name = it.name or it.url, url = it.url,
				  kind = it.kind or "station" })
	    end
	 end
      end
   end
   dash_saved = nil
   r.dash = d
   return d
end

-- tovmu : also write the memory card (settings changed)
function dash_save(r, tovmu)
   local d = r.dash
   local file = openfile(dash_cfg_filename, "w")
   if not file then return end
   local cf = d.cfg
   write(file, format("dash_saved = { clock=%d, tz=%d, counts=%d, alerts=%d,"
		      .. " wx_f=%d,\n", cf.clock, cf.tz, cf.counts, cf.alerts,
		      cf.wx_f or 0))
   if cf.wx_lat and cf.wx_lat ~= "" then
      write(file, format(" wx_name=%q, wx_lat=%q, wx_lon=%q,\n",
			 cf.wx_name or "", cf.wx_lat, cf.wx_lon or "0"))
   end
   write(file, " recent = {\n")
   local i
   for i = 1, getn(d.recent) do
      local f = d.recent[i]
      write(file, format(" { name=%q, url=%q, kind=%q },\n",
			 f.name, f.url, f.kind or "station"))
   end
   write(file, "} }\n")
   closefile(file)
   if tovmu and vmu_save then vmu_save(nil, 1) end
end

-- a station or file was started : first in "recently played"
function dash_recent(r, item)
   local d = r.dash
   if not d or not item or not item.url then return end
   local i
   for i = getn(d.recent), 1, -1 do
      if d.recent[i].url == item.url then tremove(d.recent, i) end
   end
   tinsert(d.recent, 1, { name = item.name or item.url, url = item.url,
			  kind = item.kind or "station" })
   while getn(d.recent) > 6 do tremove(d.recent) end
   dash_save(r)
end

-- ----------------------------------------------------------------------
-- the feed
-- ----------------------------------------------------------------------

-- "a\tb\tc" -> { "a", "b", "c" }
function dash_split(s, sep)
   local t = { n = 0 }
   local p = 1
   while 1 do
      local e = strfind(s, sep, p, 1)
      if not e then
	 tinsert(t, strsub(s, p))
	 break
      end
      tinsert(t, strsub(s, p, e - 1))
      p = e + 1
   end
   return t
end

function dash_feed(r, e)
   local d = r.dash
   if not d or not chat_feed_body then return end
   if e and e.text == "test" then
      dash_diag_poll(r)
      return
   end
   if e and e.text == "http" then
      if wx_got then wx_got(r) end
      return
   end
   local body, q, err = chat_feed_body()
   d.busy = nil
   if not body then
      d.failed = err or "No answer from the server."
      r.dirty = 1
      return
   end
   d.failed = nil
   local lines = dash_split(body, "\n")
   local people, games = { n = 0 }, { n = 0 }
   local got_stat
   local i
   for i = 1, lines.n do
      local f = dash_split(lines[i], "\t")
      local k = f[1]
      if k == "DC99" and f[3] and chat_time then
	 local t = tonumber(f[3])
	 if t then d.toff = t - chat_time() end
      elseif k == "STAT" then
	 d.dp = tonumber(f[2] or "") or -1
	 d.dn = tonumber(f[3] or "") or -1
	 d.irc = tonumber(f[4] or "") or -1
	 got_stat = 1
      elseif k == "P" then
	 tinsert(people, { name = f[2] or "?", game = f[3] or "",
			   net = f[4] or "", cc = f[5] or "" })
      elseif k == "G" then
	 tinsert(games, { name = f[2] or "?", n = tonumber(f[3] or "") or 1 })
      end
   end
   if not got_stat then return end
   -- who just came online (not on the first read)
   if d.people_known and d.cfg.alerts == 1 then
      local old = {}
      for i = 1, d.people.n do old[strlower(d.people[i].name)] = 1 end
      local said = 0
      for i = 1, people.n do
	 local p = people[i]
	 if not old[strlower(p.name)] and said < 3 then
	    local t = p.name .. " is online"
	    if p.game ~= "" then t = t .. " : " .. p.game end
	    dash_notify(r, "online", t)
	    said = said + 1
	 end
      end
   end
   d.people, d.games = people, games
   d.people_known = 1
   r.dirty = 1
end

-- every frame
function dash_update(r, frametime)
   local d = r.dash
   if not d then return end
   -- read the feed now and then, quietly
   if net_connected and chat_feed then
      d.fetch_t = d.fetch_t - frametime
      if d.fetch_t <= 0 and not d.busy then
	 if chat_feed("s=online") then
	    d.busy = 1
	    d.busy_t = 30
	    d.fetch_t = (r.mode == "online" and dash_every_online)
	       or dash_every_home
	 else
	    d.fetch_t = 2 -- the worker is busy (KosNet) : soon
	 end
      end
      if d.busy then
	 d.busy_t = d.busy_t - frametime
	 if d.busy_t <= 0 then d.busy = nil end
      end
   end
   -- the clock : redraw when the minute changes
   if r.mode == "main" or r.mode == "online" then
      local t = dash_now(r)
      local m = floor(t / 60)
      if m ~= d.minute then
	 d.minute = m
	 r.dirty = 1
      end
   end
   -- panels slide in and out
   local want = (d.panel and 1) or 0
   if d.anim ~= want then
      local step = frametime * 6
      if d.anim < want then d.anim = min(1, d.anim + step)
      else d.anim = max(0, d.anim - step) end
      if d.anim == 0 then d.shown_panel = nil end
      r.dirty = 1
   end
   dash_diag_update(r, frametime)
   if d.banner_t then
      local was = d.banner_t
      d.banner_t = d.banner_t - frametime
      if d.banner_t <= 0 then
	 d.banner_t = nil
	 r.dirty = 1
      elseif 7 - was < 0.4 then
	 r.dirty = 1 -- still sliding in
      end
   end
end

-- the Online screen was opened : fresh numbers soon
function dash_hurry(r)
   local d = r.dash
   if d and d.fetch_t > 1 then d.fetch_t = 0.5 end
end

-- ----------------------------------------------------------------------
-- time
-- ----------------------------------------------------------------------

-- seconds, local time : the console clock when it looks right, otherwise
-- the server's (many consoles have a flat clock battery)
function dash_now(r)
   local d = r.dash
   if not chat_time then return 0 end
   local t = chat_time()
   local cf = d.cfg
   if cf.tz ~= 99 and d.toff then
      -- a zone was chosen : the server's time in that zone
      return t + d.toff + cf.tz * 1800
   end
   if d.toff and abs(d.toff) > 16 * 3600 then
      -- console clock is off by more than any time zone : the server's
      -- time, in the weather city's zone when there is one
      if r.wx and r.wx.off then
	 d.utc = nil
	 return t + d.toff + r.wx.off
      end
      d.utc = 1
      return t + d.toff
   end
   d.utc = nil
   return t
end

function dash_civil(t)
   local days = floor(t / 86400)
   local secs = t - days * 86400
   local z = days + 719468
   local era = floor(z / 146097)
   local doe = z - era * 146097
   local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524)
		      - floor(doe / 146096)) / 365)
   local y = yoe + era * 400
   local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
   local mp = floor((5 * doy + 2) / 153)
   local dd = doy - floor((153 * mp + 2) / 5) + 1
   local m = mp + 3
   if mp >= 10 then m = mp - 9 end
   if m <= 2 then y = y + 1 end
   local wd = mod(days + 4, 7)
   if wd < 0 then wd = wd + 7 end
   return y, m, dd, floor(secs / 3600), mod(floor(secs / 60), 60), wd
end

-- "WED 18 NOV", "12:34 AM"
function dash_clock(r)
   local d = r.dash
   if d.cfg.clock == 2 or not chat_time then return end
   local t = dash_now(r)
   local y, m, dd, h, mi, wd = dash_civil(t)
   if y < 2001 then return end -- a dead clock and no server time yet
   local date = format("%s %d %s", dash_days[wd + 1], dd, dash_months[m])
   local tm
   if d.cfg.clock == 1 then
      tm = format("%02d:%02d", h, mi)
   else
      local h12 = mod(h, 12)
      if h12 == 0 then h12 = 12 end
      tm = format("%d:%02d %s", h12, mi, (h < 12 and "AM") or "PM")
   end
   if d.utc then tm = tm .. " UTC" end
   return date, tm
end

-- ----------------------------------------------------------------------
-- notifications
-- ----------------------------------------------------------------------

-- kind : "chat" "dm" "online" ; arg : conversation for chat
function dash_notify(r, kind, text, arg)
   local d = r.dash
   if not d then return end
   local when
   local dt, tm = dash_clock(r)
   if tm then tm = gsub(tm, " UTC", "") end
   tinsert(d.notes, 1, { kind = kind, text = text, arg = arg, when = tm })
   while getn(d.notes) > dash_max_notes do tremove(d.notes) end
   d.unread = d.unread + 1
   d.banner = d.notes[1]
   d.banner_t = 7
   r.dirty = 1
end

function dash_open_note(r, n)
   if not n then return end
   if (n.kind == "chat" or n.kind == "dm") and rchat_open then
      dash_panel(r, nil)
      rchat_open(r, 1, n.arg)
   elseif n.kind == "online" then
      dash_panel(r, nil)
      dash_open_online(r)
   end
end

-- ----------------------------------------------------------------------
-- apps and panels
-- ----------------------------------------------------------------------

function dash_panel(r, which)
   local d = r.dash
   if not d then return end
   if which and d.panel == which then which = nil end
   d.panel = which
   if which then
      d.shown_panel = which
      if which == "l" then d.lsel = 1 end
      if which == "r" then
	 d.rsel = 1
	 d.unread = 0
      end
   end
   r.dirty = 1
end

function dash_open_online(r)
   local d = r.dash
   r.online_prev = (r.mode ~= "online" and r.mode) or r.online_prev or "main"
   r.mode = "online"
   r.menu = nil
   dash_hurry(r)
   r.dirty = 1
end

function dash_open_app(r, id)
   local d = r.dash
   dash_panel(r, nil)
   if id == "fav" then
      r.mode = "browse"
      radio_set_section(r, 2)
   elseif id == "radio" then
      r.mode = "browse"
      radio_set_section(r, 1)
   elseif id == "chat" then
      if rchat_open then rchat_open(r) end
   elseif id == "online" then
      dash_open_online(r)
   elseif id == "weather" then
      if wx_open then wx_open(r) end
   elseif id == "settings" then
      radio_menu_open(r)
   end
   r.dirty = 1
end

-- the selectable lines of a panel : { label, sub, action, arg, head }
-- the lines of a panel : { head } or { label, right, act, arg, dot, key }
-- or { btn = 1, label, act, arg } (the buttons at the bottom, last)
function dash_panel_items(r, which)
   local d = r.dash
   local it = { n = 0 }
   local i
   if which == "l" then
      tinsert(it, { head = "FAVOURITES" })
      if getn(r.fav) == 0 then
	 tinsert(it, { label = "None yet : X on a station adds it", dim = 1 })
      end
      for i = 1, min(getn(r.fav), 5) do
	 tinsert(it, { label = r.fav[i].name, act = "play", arg = r.fav[i],
		       right = (i <= 5 and format("%d", i)) or nil })
      end
      if getn(d.recent) > 0 then
	 tinsert(it, { head = "RECENTLY PLAYED" })
	 for i = 1, min(getn(d.recent), 3) do
	    tinsert(it, { label = d.recent[i].name, act = "play",
			  arg = d.recent[i] })
	 end
      end
      tinsert(it, { btn = 1, label = "ALL STATIONS", act = "app", arg = "radio" })
      tinsert(it, { btn = 1, label = "FAVOURITES", act = "app", arg = "fav" })
   else
      tinsert(it, { head = "PLAYING NOW" })
      if not d.people_known then
	 tinsert(it, { label = (net_connected and "Looking...")
			  or "Not connected", dim = 1 })
      elseif d.people.n == 0 then
	 tinsert(it, { label = "Nobody right now", dim = 1 })
      end
      for i = 1, min(d.people.n, 4) do
	 local p = d.people[i]
	 tinsert(it, { label = p.name, right = p.game, act = "online", dot = 1 })
      end
      -- chat news only : who comes online is already in the list above
      local shown = 0
      for i = 1, getn(d.notes) do
	 local n = d.notes[i]
	 if n.kind ~= "online" and shown < 2 then
	    if shown == 0 then tinsert(it, { head = "MESSAGES" }) end
	    tinsert(it, { label = n.text, right = n.when, act = "note", arg = n })
	    shown = shown + 1
	 end
      end
      tinsert(it, { btn = 1, label = "OPEN CHAT", act = "app", arg = "chat" })
      tinsert(it, { btn = 1, label = "WHO IS ONLINE", act = "online" })
   end
   return it
end

function dash_panel_move(r, dir)
   local d = r.dash
   local it = dash_panel_items(r, d.panel)
   local k = (d.panel == "l" and "lsel") or "rsel"
   local s = d[k]
   local n = getn(it)
   local tries = 0
   repeat
      s = s + dir
      if s < 1 then s = n end
      if s > n then s = 1 end
      tries = tries + 1
   until (it[s] and not it[s].head and not it[s].dim) or tries > n
   d[k] = s
   r.dirty = 1
end

function dash_panel_do(r, item)
   if not item or item.head then return end
   local d = r.dash
   if item.act == "play" then
      radio_play_item(r, item.arg)
      dash_panel(r, nil)
   elseif item.act == "app" then
      dash_open_app(r, item.arg)
   elseif item.act == "online" then
      dash_panel(r, nil)
      dash_open_online(r)
   elseif item.act == "note" then
      dash_open_note(r, item.arg)
   end
   r.dirty = 1
end

-- keys on the home screen ; returns 1 when used
function dash_key(r, key)
   local d = r.dash
   if not d then return end
   if key == KBD_KEY_F3 then dash_panel(r, "l") return 1 end
   if key == KBD_KEY_F6 then dash_panel(r, "r") return 1 end
   if d.panel then
      local it = dash_panel_items(r, d.panel)
      local k = (d.panel == "l" and "lsel") or "rsel"
      -- the selection starts on the first line that can be chosen
      if not it[d[k]] or it[d[k]].head or it[d[k]].dim then
	 dash_panel_move(r, 1)
      end
      if gui_keyup[key] then dash_panel_move(r, -1)
      elseif gui_keydown[key] then dash_panel_move(r, 1)
      elseif gui_keyconfirm[key] then dash_panel_do(r, it[d[k]])
      elseif gui_keycancel[key] then dash_panel(r, nil)
      elseif gui_keyleft[key] then
	 if d.panel == "r" then dash_panel(r, nil) end
      elseif gui_keyright[key] then
	 if d.panel == "l" then dash_panel(r, nil) end
      else
	 return
      end
      return 1
   end
   if gui_keyleft[key] then
      d.dock = d.dock - 1
      if d.dock < 1 then d.dock = getn(dash_apps) end
      r.dirty = 1
      return 1
   elseif gui_keyright[key] then
      d.dock = d.dock + 1
      if d.dock > getn(dash_apps) then d.dock = 1 end
      r.dirty = 1
      return 1
   elseif gui_keyconfirm[key] then
      dash_open_app(r, dash_apps[d.dock].id)
      return 1
   end
end

-- L and R on the controller
function dash_trigger(r, which)
   if r.mode == "chat" and not r.menu and rchat_view then
      rchat_view(r, (which == "l" and 1) or 2)
      return
   end
   if r.mode ~= "main" or r.menu or r.hud_off then return end
   dash_panel(r, which)
end

function dash_click(r, h)
   local d = r.dash
   if h.kind == "dock" then
      d.dock = h.arg
      dash_open_app(r, dash_apps[h.arg].id)
   elseif h.kind == "dprow" then
      local it = dash_panel_items(r, d.panel)
      dash_panel_do(r, it[h.arg])
   elseif h.kind == "dlive" then
      dash_panel(r, "r")
   elseif h.kind == "dwx" then
      if wx_open then wx_open(r) end
   elseif h.kind == "dwxres" then
      if r.wx and r.wx.results[h.arg] then wx_pick(r, r.wx.results[h.arg]) end
   elseif h.kind == "dmusic" then
      dash_panel(r, "l")
   elseif h.kind == "dbanner" then
      local b = d.banner
      d.banner_t = nil
      dash_open_note(r, b)
   elseif h.kind == "dsec" then
      d.sec = h.arg
   elseif h.kind == "drow" then
      d.pos[d.sec] = h.arg
   end
   r.dirty = 1
end

-- pointing at something selects it
function dash_hover(r, h)
   local d = r.dash
   if h.kind == "dock" and d.dock ~= h.arg and not d.panel then
      d.dock = h.arg
      r.dirty = 1
   elseif h.kind == "dprow" and d.panel then
      local k = (d.panel == "l" and "lsel") or "rsel"
      if d[k] ~= h.arg then
	 d[k] = h.arg
	 r.dirty = 1
      end
   end
end

-- ----------------------------------------------------------------------
-- drawing
-- ----------------------------------------------------------------------

function dash_text(dl, x, y, size, c, s, z)
   dl_text_prop(dl, 0, size)
   dl_draw_text(dl, x, y, z or 30, c[1], c[2], c[3], c[4], s)
end

function dash_count_txt(label, n)
   if not n or n < 0 then return label .. " --" end
   return format("%s %d", label, n)
end

-- the IRC number : live from our own connection when there is one
function dash_irc(r)
   local ch = r.chat
   if ch and ch.state == 3 and ch.users and ch.users.n > 0 then
      return ch.users.n
   end
   return r.dash.irc
end

-- top line : Dreamcast Now players left, date and time in the middle,
-- the weather right
function dash_draw_status(r)
   local d = r.dash
   local dl = r.back
   local c = radio_col
   radio_box(dl, 0, 0, 640, 26, 5, radio_bar)
   radio_box(dl, 0, 26, 640, 1, 6, c.dark)
   if d.cfg.counts == 1 then
      local n = d.dp
      local s = dash_count_txt("DREAMCAST NOW", n)
      radio_box(dl, 24, 10, 6, 6, 15, (n and n > 0 and c.green) or c.dark)
      radio_text(dl, 36, 7, 12, c.dim, s)
      radio_hit(r, 20, 2, radio_width(s, 12) + 24, 22, "dlive", 1)
   end
   local date, tm = dash_clock(r)
   if date then
      local dw, tw = radio_width(date, 12), radio_width(tm, 12)
      local x = 320 - floor((dw + 10 + tw) / 2)
      radio_text(dl, x, 7, 12, c.dim, date)
      radio_text(dl, x + dw + 10, 7, 12, c.white, tm)
   end
   if wx_draw_corner then wx_draw_corner(r) end
end

-- small line of button reminders just above the app bar
function dash_draw_keys(r, keys, y)
   local dl = r.back
   local c = radio_col
   local x = 24
   local i
   radio_box(dl, 0, y - 6, 640, 28, 5, radio_bar)
   for i = 1, getn(keys) do
      local k = keys[i]
      local kw = radio_width(k[1], 12) + 10
      radio_frame(dl, x, y, kw, 17, radio_cap, c.frame)
      radio_text(dl, x + 5, y + 2, 12, c.star, k[1])
      radio_text(dl, x + kw + 6, y + 2, 12, c.dim, k[2])
      local w = kw + radio_width(k[2], 12) + 20
      if k[3] then radio_hit(r, x - 2, y - 2, w - 6, 21, "key", k[3]) end
      x = x + w
   end
end

-- the app bar with the notification corner
function dash_draw_dock(r)
   local d = r.dash
   local dl = r.back
   local c = radio_col
   radio_box(dl, 0, 432, 640, 48, 5, radio_bar)
   radio_box(dl, 0, 432, 640, 1, 6, c.dark)
   local x = 24
   local i
   for i = 1, getn(dash_apps) do
      local a = dash_apps[i]
      local badge
      if a.id == "chat" and rchat_unread then
	 local u = rchat_unread(r)
	 if u > 0 then badge = format("%d", u) end
      elseif a.id == "online" and d.people_known then
	 badge = format("%d", d.people.n)
      end
      local w = radio_width(a.name, 14) + 26
      if badge then w = w + radio_width(badge, 12) + 12 end
      local sel = (i == d.dock) and not d.panel
      radio_frame(dl, x, 440, w, 30, (sel and c.sel) or c.fill,
		  (sel and c.frame) or c.dark, (sel and c.sel2) or c.fill2)
      radio_text(dl, x + 13, 447, 14, (sel and c.white) or c.text, a.name)
      if badge then
	 local bx = x + w - radio_width(badge, 12) - 16
	 radio_box(dl, bx, 446, radio_width(badge, 12) + 8, 17, 25,
		   (a.id == "chat" and c.star) or c.dark)
	 radio_text(dl, bx + 4, 448, 12,
		    (a.id == "chat" and c.black) or c.white, badge)
      end
      radio_hit(r, x, 440, w, 30, "dock", i)
      x = x + w + 6
   end
   -- notifications : a count, the newest one
   local nx = x + 6
   local nw = 616 - nx
   if nw > 60 then
      local has = d.unread > 0
      radio_frame(dl, nx, 440, nw, 30, c.black, (has and c.frame) or c.dark)
      radio_box(dl, nx + 8, 450, 8, 8, 25, (has and c.star) or c.dark)
      local s
      if has then
	 s = format("%d NEW", d.unread)
      else
	 s = "R : LIVE"
      end
      radio_text(dl, nx + 22, 448, 12, (has and c.white) or c.dim,
		 radio_fit(s, 12, nw - 30))
      radio_hit(r, nx, 440, nw, 30, "dlive", 1)
   end
end

-- a new notification slides in above the bar for a few seconds
function dash_draw_banner(r, y)
   local d = r.dash
   if not d or not d.banner_t or not d.banner then return end
   if d.panel or d.anim > 0 then return end -- the panel shows them
   if r.mode == "chat" or r.mode == "help" then return end
   local dl = r.back
   local c = radio_col
   local b = d.banner
   local lab = (b.kind == "online" and "ONLINE") or (b.kind == "dm" and "MESSAGE")
      or "CHAT"
   local s = radio_fit(b.text, 14, 440)
   local w = radio_width(s, 14) + radio_width(lab, 12) + 60
   -- slide in from the right during the first half second
   local t = 7 - d.banner_t
   local x = 616 - w
   if t < 0.35 then x = x + floor((0.35 - t) / 0.35 * (w + 30)) end
   dl_draw_box1(dl, x, y, x + w, y + 32, 60, 0.92, 0.08, 0.04, 0.01)
   dl_draw_box1(dl, x, y, x + w, y + 2, 61, 1, 1, 0.54, 0.10)
   dl_draw_box1(dl, x, y + 30, x + w, y + 32, 61, 1, 1, 0.54, 0.10)
   dl_draw_box1(dl, x, y, x + 4, y + 32, 61, 1, 1, 0.69, 0)
   dash_text(dl, x + 14, y + 10, 12, c.star, lab, 62)
   dash_text(dl, x + 26 + radio_width(lab, 12), y + 8, 14, c.white, s, 62)
   radio_hit(r, x, y, w, 32, "dbanner", 1)
end

-- the slide-out panel (L : my music, R : live)
-- the slide-out panel (L : my music, R : live)
function dash_panel_txt(dl, x, y, size, col, s)
   dl_text_prop(dl, 0, size)
   dl_draw_text(dl, x, y, 50, col[1], col[2], col[3], col[4], s)
end

function dash_draw_panel(r)
   local d = r.dash
   local which = d.panel or d.shown_panel
   if not which or d.anim <= 0 then return end
   local dl = r.back
   local c = radio_col
   local w = 300
   local a = d.anim
   a = 1 - (1 - a) * (1 - a) -- ease out
   local x
   if which == "l" then x = floor(-w + w * a) else x = floor(640 - w * a) end
   local y, h = 27, 405
   local sel = (which == "l" and d.lsel) or d.rsel

   -- the rest of the screen steps back
   dl_draw_box1(dl, 0, 27, 640, 432, 40, 0.55 * a, 0, 0, 0)
   -- the panel : solid, dark, one orange edge toward the screen
   dl_draw_box(dl, x, y, x + w, y + h, 42, 1, 0.09, 0.05, 0.02,
	       1, 0.03, 0.02, 0.01, 2)
   local ex = (which == "l" and x + w - 2) or x
   dl_draw_box1(dl, ex, y, ex + 2, y + h, 44, 1, 1, 0.54, 0.10)

   local px = x + 22
   local pw = w - 44
   dash_panel_txt(dl, px, y + 16, 20, c.white,
		  (which == "l" and "My music") or "Live")
   local ry = y + 50

   if which == "r" then
      -- three numbers, side by side
      local list = { { "DC NOW", d.dp }, { "DCNET", d.dn },
		     { "IRC", dash_irc(r) } }
      local i
      local cw = floor(pw / 3)
      for i = 1, 3 do
	 local n = list[i][2]
	 local bx = px + (i - 1) * cw
	 local s = (n and n >= 0 and format("%d", n)) or "--"
	 dash_panel_txt(dl, bx, ry, 26, (n and n > 0 and c.green) or c.dim, s)
	 dash_panel_txt(dl, bx, ry + 30, 12, c.label, list[i][1])
	 if i > 1 then
	    dl_draw_box1(dl, bx - 10, ry + 2, bx - 9, ry + 42, 45,
			 1, 0.48, 0.29, 0.06)
	 end
      end
      ry = ry + 58
   end

   local it = dash_panel_items(r, which)
   local i
   local btns = {}
   local nb = 0
   local bottom = y + h - 58
   for i = 1, getn(it) do
      local e = it[i]
      if e.btn then
	 nb = nb + 1
	 btns[nb] = i
      elseif e.head then
	 if ry < bottom - 40 then
	    -- a quiet title with a hairline after it
	    ry = ry + 8
	    dash_panel_txt(dl, px, ry, 12, c.label, e.head)
	    local tw = radio_width(e.head, 12)
	    dl_draw_box1(dl, px + tw + 10, ry + 7, px + pw, ry + 8, 45,
			 1, 0.48, 0.29, 0.06)
	    ry = ry + 22
	 end
      elseif ry <= bottom - 24 then
	 local on = (i == sel) and d.panel
	 if on then
	    dl_draw_box1(dl, x + 10, ry - 3, x + w - 10, ry + 21, 46,
			 1, 0.32, 0.17, 0.03)
	    dl_draw_box1(dl, x + 10, ry - 3, x + 13, ry + 21, 47,
			 1, 1, 0.54, 0.10)
	 end
	 local tx = px
	 if e.dot then
	    dl_draw_box1(dl, tx, ry + 7, tx + 5, ry + 12, 48,
			 1, 0.36, 1, 0.42)
	    tx = tx + 12
	 end
	 local rw = 0
	 if e.right and e.right ~= "" then
	    local rs = radio_fit(e.right, 12, floor(pw * 0.45))
	    rw = radio_width(rs, 12) + 10
	    dash_panel_txt(dl, px + pw - rw + 10, ry + 3, 12,
			   (on and c.white) or c.dim, rs)
	 end
	 local col = (on and c.white) or ((e.dim or e.dim2) and c.dim) or c.text
	 dash_panel_txt(dl, tx, ry + 1, 14, col,
			radio_fit(e.label, 14, px + pw - rw - tx))
	 if d.panel and not e.dim then radio_hit(r, x + 10, ry - 3, w - 20, 24, "dprow", i) end
	 ry = ry + 24
      end
   end

   -- the buttons, side by side at the bottom
   if nb > 0 then
      local bw = floor((pw - 8 * (nb - 1)) / nb)
      local by = y + h - 46
      for i = 1, nb do
	 local e = it[btns[i]]
	 local on = (btns[i] == sel) and d.panel
	 local bx = px + (i - 1) * (bw + 8)
	 dl_draw_box(dl, bx, by, bx + bw, by + 30, 46,
		     1, (on and 0.78) or 0.16, (on and 0.42) or 0.09,
		     (on and 0.02) or 0.03,
		     1, (on and 0.45) or 0.07, (on and 0.22) or 0.04,
		     (on and 0.00) or 0.01, 2)
	 dl_draw_box1(dl, bx, by, bx + bw, by + 1, 47, 1, 1, 0.54, 0.10)
	 dl_draw_box1(dl, bx, by + 29, bx + bw, by + 30, 47, 1, 0.48, 0.29, 0.06)
	 local lw = radio_width(e.label, 12)
	 dash_panel_txt(dl, bx + floor((bw - lw) / 2), by + 9, 12,
			(on and c.white) or c.text, e.label)
	 if d.panel then radio_hit(r, bx, by, bw, 30, "dprow", btns[i]) end
      end
   end
end

-- ----------------------------------------------------------------------
-- the Online screen : who is playing what
-- ----------------------------------------------------------------------

dash_online_secs = { "PLAYERS", "GAMES" }

function dash_online_items(r)
   local d = r.dash
   if d.sec == 2 then return d.games end
   return d.people
end

function radio_draw_online(r)
   local d = r.dash
   local dl = r.back
   local c = radio_col
   local i
   dash_draw_status(r)
   local x = 24
   for i = 1, 2 do
      local n = (i == 1 and d.people.n) or d.games.n
      local lab = dash_online_secs[i]
      if d.people_known then lab = format("%s  %d", lab, n) end
      local w = radio_width(lab, 14) + 24
      local act = (i == d.sec)
      radio_frame(dl, x, 34, w, 26, (act and c.sel) or c.fill,
		  (act and c.frame) or c.dark, (act and c.sel2) or c.fill2)
      radio_text(dl, x + 12, 40, 14, (act and c.white) or c.dim, lab)
      radio_hit(r, x, 34, w, 26, "dsec", i)
      x = x + w + 6
   end
   local items = dash_online_items(r)
   local n = items.n
   local s = d.sec
   radio_frame(dl, 24, 68, 592, 300, c.fill, c.frame, c.fill2)
   local head
   if s == 1 then head = "Players online now, and their game"
   else head = "Games being played now" end
   radio_text(dl, 36, 76, 12, c.label, head)
   if n > 0 then
      local t = format("%d / %d", d.pos[s], n)
      radio_text(dl, 604 - radio_width(t, 12), 76, 12, c.dim, t)
   end
   radio_box(dl, 34, 93, 572, 1, 15, c.dark)
   if n == 0 then
      local m
      if not net_connected then m = "Not connected : Start > Network settings"
      elseif not d.people_known then
	 m = (d.failed and radio_fit(d.failed, 16, 540)) or "Looking..."
      else m = "Nobody is online right now" end
      radio_text(dl, 44, 108, 16, c.dim, m)
   end
   if d.pos[s] > n then d.pos[s] = max(1, n) end
   if d.pos[s] < d.top[s] then d.top[s] = d.pos[s] end
   if d.pos[s] >= d.top[s] + dash_rows then d.top[s] = d.pos[s] - dash_rows + 1 end
   if d.top[s] < 1 then d.top[s] = 1 end
   for i = 0, dash_rows - 1 do
      local idx = d.top[s] + i
      local it = items[idx]
      if it then
	 local y = 100 + i * dash_row_h
	 local sel = (idx == d.pos[s])
	 if sel then radio_grad(dl, 30, y - 1, 568, dash_row_h - 1, 15,
				c.sel, c.sel2, 1) end
	 if s == 1 then
	    radio_box(dl, 38, y + 7, 6, 6, 18, c.green)
	    radio_text(dl, 52, y + 2, 16, (sel and c.white) or c.text,
		       radio_fit(it.name, 16, 170))
	    radio_text(dl, 232, y + 3, 14, (sel and c.white) or c.green,
		       radio_fit((it.game ~= "" and it.game) or "In the lobby",
				 14, 250))
	    local tag = (it.net == "DreamPi" and "DC NOW") or strupper(it.net)
	    if it.cc ~= "" then tag = tag .. "  " .. strupper(it.cc) end
	    radio_text(dl, 592 - radio_width(tag, 12), y + 4, 12,
		       (sel and c.white) or c.dim, tag)
	 else
	    radio_text(dl, 44, y + 2, 16, (sel and c.white) or c.text,
		       radio_fit(it.name, 16, 460))
	    local t = format("%d playing", it.n)
	    radio_text(dl, 592 - radio_width(t, 14), y + 3, 14,
		       (sel and c.white) or c.green, t)
	 end
	 radio_hit(r, 30, y - 1, 568, dash_row_h, "drow", idx)
      end
   end
   radio_draw_hints(r, {
		       { "< >", (s == 1 and "Games") or "Players", nil },
		       { "^ v", "Move", nil },
		       { "Y", "Refresh", "y" },
		       { "B", "Back", "b" },
		       { "Start", "Menu", "menu" },
		    })
end

function dash_online_key(r, key)
   local d = r.dash
   local items = dash_online_items(r)
   local n = items.n
   local s = d.sec
   if gui_keyup[key] then
      d.pos[s] = max(1, d.pos[s] - 1)
   elseif gui_keydown[key] then
      d.pos[s] = min(max(1, n), d.pos[s] + 1)
   elseif key == KBD_KEY_PGUP then
      d.pos[s] = max(1, d.pos[s] - dash_rows)
   elseif key == KBD_KEY_PGDOWN then
      d.pos[s] = min(max(1, n), d.pos[s] + dash_rows)
   elseif gui_keyleft[key] or gui_keyright[key] or key == KBD_KEY_TAB
      or key == 9 then
      d.sec = 3 - d.sec
   elseif gui_keymenu[key] then
      dash_hurry(r)
   elseif gui_keycancel[key] or gui_keyselect[key] then
      r.mode = r.online_prev or "main"
   end
   r.dirty = 1
end

function dash_online_action(r, name)
   if name == "b" then r.mode = r.online_prev or "main"
   elseif name == "y" then dash_hurry(r) end
   r.dirty = 1
end

-- ----------------------------------------------------------------------
-- Connection test : every step of reaching the server, in words
-- ----------------------------------------------------------------------

function dash_open_diag(r)
   local d = r.dash
   r.diag_prev = (r.mode ~= "diag" and r.mode) or r.diag_prev or "main"
   r.mode = "diag"
   r.menu = nil
   d.diag = nil
   d.diag_wait = 0
   d.diag_run = 1
   r.dirty = 1
end

function dash_diag_poll(r)
   local d = r.dash
   if not chat_test_log then return end
   local t, done = chat_test_log()
   d.diag = t
   if done == 1 then d.diag_run = nil end
   r.dirty = 1
end

-- every frame while the test screen is up
function dash_diag_update(r, ft)
   local d = r.dash
   if r.mode ~= "diag" then return end
   d.diag_wait = (d.diag_wait or 0) - ft
   if d.diag_wait > 0 then return end
   d.diag_wait = 0.5
   if d.diag_run == 1 then
      if not net_connected then
	 d.diag = "Not connected to the internet.\nStart > Network settings first."
	 d.diag_run = nil
      elseif chat_test and chat_test() then
	 d.diag_run = 2
      end
   elseif d.diag_run == 2 then
      dash_diag_poll(r)
   end
   r.dirty = 1
end

function radio_draw_diag(r)
   local d = r.dash
   local dl = r.back
   local c = radio_col
   radio_text(dl, 24, 24, 20, c.white, "CONNECTION TEST")
   radio_frame(dl, 24, 58, 592, 360, c.fill, c.frame, c.fill2)
   local t = d.diag or ""
   if d.diag_run then t = t .. "Working..." end
   local lines = dash_split(t, "\n")
   local i
   local y = 70
   for i = 1, lines.n do
      local l = lines[i]
      if l ~= "" then
	 local col = c.text
	 if strfind(l, "no answer", 1, 1) or strfind(l, "could not", 1, 1)
	    or strfind(l, "no STAT", 1, 1) or strfind(l, "answered", 1, 1) then
	    col = rchat_bad or c.star
	 elseif strfind(l, "found", 1, 1) or strfind(l, "connected", 1, 1)
	    or strfind(l, "STAT", 1, 1) then
	    col = c.green
	 elseif strsub(l, 1, 1) ~= " " then
	    col = c.white
	 end
	 radio_text(dl, 40, y, 14, col, radio_fit(l, 14, 560))
	 y = y + 20
      end
   end
   radio_draw_hints(r, { { "A", "Test again", "a" }, { "B", "Back", "b" },
			 { "Start", "Menu", "menu" } })
end

function dash_diag_key(r, key)
   if gui_keyconfirm[key] then
      if not r.dash.diag_run then dash_open_diag(r) end
   elseif gui_keycancel[key] then
      r.mode = r.diag_prev or "main"
   end
   r.dirty = 1
end

function dash_diag_action(r, name)
   if name == "a" then dash_diag_key(r, KBD_CONT1_A)
   elseif name == "b" then r.mode = r.diag_prev or "main" end
   r.dirty = 1
end

-- ----------------------------------------------------------------------
-- START menu : "Dashboard"
-- ----------------------------------------------------------------------

function dash_tz_name(v)
   if v == 99 then return "console clock" end
   local h = v / 2
   local s = (h < 0 and "-") or "+"
   h = abs(h)
   local hh = floor(h)
   if h > hh then return format("UTC%s%d:30", s, hh) end
   return format("UTC%s%d", s, hh)
end

function dash_menu_items(r, it)
   local cf = r.dash.cfg
   local clk = { "12 hour", "24 hour", "off" }
   tinsert(it, { name = "Clock", val = clk[cf.clock + 1], act = "dashclock" })
   tinsert(it, { name = "Time zone", val = "< " .. dash_tz_name(cf.tz) .. " >",
		 act = "dashtz" })
   tinsert(it, { name = "Players online", val = (cf.counts == 1 and "shown")
		    or "hidden", act = "dashcounts" })
   tinsert(it, { name = "Tell me when players come online",
		 val = (cf.alerts == 1 and "yes") or "no", act = "dashalerts" })
   tinsert(it, { name = "Connection test", act = "dashtest" })
end

-- dir : 1 (A or right) or -1 (left)
function dash_menu_do(r, item, dir)
   local cf = r.dash.cfg
   local act = item.act
   if act == "dashclock" then cf.clock = mod(cf.clock + 1, 3)
   elseif act == "dashtz" then
      -- console clock, then UTC-12 .. UTC+14 by half hours
      local v = cf.tz
      if v == 99 then v = (dir > 0 and -24) or 28
      else
	 v = v + dir
	 if v > 28 or v < -24 then v = 99 end
      end
      cf.tz = v
   elseif act == "dashcounts" then cf.counts = 1 - cf.counts
   elseif act == "dashalerts" then cf.alerts = 1 - cf.alerts
   elseif act == "dashtest" then
      dash_open_diag(r)
      return
   end
   dash_save(r, 1)
   r.dirty = 1
end
