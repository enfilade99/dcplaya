--- @file     radio_wx.lua
--- @date     2026/11/18
--- @brief    DCPlaya weather : a corner of the home screen and its own
---           screen (now, five days, choose the city).
---
--- Data : Open-Meteo (open-meteo.com), plain HTTP, no key. The forecast
--- also gives the city's time zone, which sets the clock when the
--- console's own clock is flat.

wx_every = 20 * 60 -- seconds between two reads

-- WMO weather codes : words and the little picture
wx_codes = {
   [0] = { "Clear", "sun" }, [1] = { "Mostly clear", "sun" },
   [2] = { "Partly cloudy", "part" }, [3] = { "Cloudy", "cloud" },
   [45] = { "Fog", "fog" }, [48] = { "Freezing fog", "fog" },
   [51] = { "Light drizzle", "rain" }, [53] = { "Drizzle", "rain" },
   [55] = { "Heavy drizzle", "rain" }, [56] = { "Freezing drizzle", "rain" },
   [57] = { "Freezing drizzle", "rain" }, [61] = { "Light rain", "rain" },
   [63] = { "Rain", "rain" }, [65] = { "Heavy rain", "rain" },
   [66] = { "Freezing rain", "rain" }, [67] = { "Freezing rain", "rain" },
   [71] = { "Light snow", "snow" }, [73] = { "Snow", "snow" },
   [75] = { "Heavy snow", "snow" }, [77] = { "Snow grains", "snow" },
   [80] = { "Showers", "rain" }, [81] = { "Showers", "rain" },
   [82] = { "Heavy showers", "rain" }, [85] = { "Snow showers", "snow" },
   [86] = { "Snow showers", "snow" }, [95] = { "Thunderstorm", "storm" },
   [96] = { "Storm, hail", "storm" }, [99] = { "Storm, hail", "storm" },
}

function wx_init(r)
   local d = r.dash
   r.wx = { t = 5, sel = 1, results = { n = 0 }, q = "" }
   local cf = d.cfg
   -- (kept in dash.cfg : wx_name, wx_lat, wx_lon, wx_f)
   if not cf.wx_f then cf.wx_f = 0 end
end

-- ----------------------------------------------------------------------
-- reading
-- ----------------------------------------------------------------------

function wx_city(r)
   local cf = r.dash.cfg
   if cf.wx_lat and cf.wx_lat ~= "" then return cf.wx_name or "" end
end

function wx_ask_forecast(r)
   local w = r.wx
   local cf = r.dash.cfg
   if not chat_http or not net_connected or not wx_city(r) then return end
   local q = "latitude=" .. cf.wx_lat .. "&longitude=" .. cf.wx_lon
      .. "&current=temperature_2m,apparent_temperature,relative_humidity_2m,"
      .. "weather_code,wind_speed_10m"
      .. "&daily=weather_code,temperature_2m_max,temperature_2m_min"
      .. "&forecast_days=5&timezone=auto"
   if chat_http("api.open-meteo.com", "/v1/forecast", q) then
      w.pending = "fc"
      w.busy = 1
      return 1
   end
end

function wx_urlenc(s)
   return gsub(s, "([^%w%-%.])",
	       function (c) return format("%%%02X", strbyte(c)) end)
end

function wx_ask_search(r)
   local w = r.wx
   if not chat_http or w.q == "" then return end
   if not net_connected then
      w.msg = "Not connected to the internet."
      return
   end
   if chat_http("geocoding-api.open-meteo.com", "/v1/search",
		"name=" .. wx_urlenc(w.q) .. "&count=8&language=en&format=json") then
      w.pending = "geo"
      w.busy = 1
      w.msg = "Searching..."
   else
      w.msg = "Busy : try again in a moment."
   end
   r.dirty = 1
end

-- only plain letters on screen
function wx_ascii(s)
   s = gsub(s or "", "\195[\128-\134]", "A")
   s = gsub(s, "\195[\136-\139]", "E")
   s = gsub(s, "\195[\160-\166]", "a")
   s = gsub(s, "\195\167", "c")
   s = gsub(s, "\195[\168-\171]", "e")
   s = gsub(s, "\195[\172-\175]", "i")
   s = gsub(s, "\195[\178-\182]", "o")
   s = gsub(s, "\195[\185-\188]", "u")
   s = gsub(s, "\195\177", "n")
   s = gsub(s, "[\128-\255]", "")
   return s
end

function wx_num(s, key)
   local _, _, v = strfind(s, '"' .. key .. '":(%-?[%d%.]+)')
   return tonumber(v or "")
end

function wx_str(s, key)
   local _, _, v = strfind(s, '"' .. key .. '":"([^"]*)"')
   return v
end

function wx_array(s, key)
   local _, _, v = strfind(s, '"' .. key .. '":%[([^%]]*)%]')
   if not v then return { n = 0 } end
   local t = dash_split(v, ",")
   local i
   for i = 1, t.n do t[i] = gsub(t[i], '"', "") end
   return t
end

-- an answer arrived (feed event "http")
function wx_got(r)
   local w = r.wx
   local body, q, err = chat_feed_body()
   w.busy = nil
   if not body then
      if w.pending == "geo" then w.msg = err or "No answer." end
      w.err = err
      r.dirty = 1
      return
   end
   if w.pending == "geo" then
      w.results = { n = 0 }
      local _, p = strfind(body, '"results":%[')
      while p do
	 local s, e, obj = strfind(body, "(%b{})", p)
	 if not s then break end
	 local lat, lon = wx_num(obj, "latitude"), wx_num(obj, "longitude")
	 if lat and lon then
	    local name = wx_ascii(wx_str(obj, "name"))
	    local where = wx_ascii(wx_str(obj, "admin1"))
	    local country = wx_ascii(wx_str(obj, "country"))
	    local full = name
	    if where ~= "" and where ~= name then full = full .. ", " .. where end
	    if country ~= "" then full = full .. ", " .. country end
	    local i, seen = 1, nil
	    for i = 1, w.results.n do
	       if w.results[i].full == full then seen = 1 end
	    end
	    if not seen then
	       tinsert(w.results, { name = name, full = full,
				    lat = format("%.3f", lat),
				    lon = format("%.3f", lon) })
	    end
	 end
	 p = e + 1
	 if w.results.n >= 5 then break end
      end
      w.sel = 1
      if w.results.n == 0 then
	 w.msg = "No city by that name."
      else
	 -- the list is next : the keyboard steps aside
	 w.msg = nil
	 w.picked = 1
	 if r.chat then r.chat.osk_on = nil end
      end
   else
      local _, _, cur = strfind(body, '"current":(%b{})')
      if not cur then
	 w.err = "No weather in the answer."
	 r.dirty = 1
	 return
      end
      w.temp = wx_num(cur, "temperature_2m")
      w.feels = wx_num(cur, "apparent_temperature")
      w.hum = wx_num(cur, "relative_humidity_2m")
      w.code = wx_num(cur, "weather_code")
      w.wind = wx_num(cur, "wind_speed_10m")
      w.off = wx_num(body, "utc_offset_seconds")
      local _, _, daily = strfind(body, '"daily":(%b{})')
      w.days = { n = 0 }
      if daily then
	 local dt = wx_array(daily, "time")
	 local dc = wx_array(daily, "weather_code")
	 local hi = wx_array(daily, "temperature_2m_max")
	 local lo = wx_array(daily, "temperature_2m_min")
	 local i
	 for i = 1, dt.n do
	    tinsert(w.days, { date = dt[i], code = tonumber(dc[i] or ""),
			      hi = tonumber(hi[i] or ""), lo = tonumber(lo[i] or "") })
	 end
      end
      w.err = nil
      w.when = 1
      local date, tm = dash_clock(r)
      w.updated = tm
   end
   r.dirty = 1
end

function wx_update(r, ft)
   local w = r.wx
   if not w then return end
   if w.busy then return end
   w.t = w.t - ft
   if w.t <= 0 then
      if wx_city(r) and net_connected then
	 if wx_ask_forecast(r) then w.t = wx_every else w.t = 3 end
      else
	 w.t = 5
      end
   end
end

-- ----------------------------------------------------------------------
-- drawing
-- ----------------------------------------------------------------------

function wx_box(dl, x1, y1, x2, y2, z, c)
   dl_draw_box1(dl, x1, y1, x2, y2, z, c[1], c[2], c[3], c[4])
end

wx_sun = { 1, 1, 0.80, 0.15 }
wx_cloud = { 1, 0.82, 0.84, 0.88 }
wx_dark = { 1, 0.52, 0.54, 0.60 }
wx_drop = { 1, 0.35, 0.65, 1.00 }

-- i = 1 : the words, 2 : the picture
function wx_info(code, i)
   local t = wx_codes[code or -1]
   if not t then
      if i == 2 then return "cloud" end
      return ""
   end
   return t[i]
end

-- a little picture, s pixels square, top left at x, y
function wx_icon(dl, x, y, s, code, z)
   local k = wx_info(code, 2)
   local u = s / 16
   z = z or 30
   if k == "sun" or k == "part" then
      local cx, cy, rr = x + 8 * u, y + 8 * u, 3.5 * u
      if k == "part" then cx, cy = x + 6 * u, y + 6 * u end
      wx_box(dl, cx - rr, cy - rr, cx + rr, cy + rr, z, wx_sun)
      wx_box(dl, cx - 0.7 * u, cy - 7 * u, cx + 0.7 * u, cy - 5 * u, z, wx_sun)
      wx_box(dl, cx - 0.7 * u, cy + 5 * u, cx + 0.7 * u, cy + 7 * u, z, wx_sun)
      wx_box(dl, cx - 7 * u, cy - 0.7 * u, cx - 5 * u, cy + 0.7 * u, z, wx_sun)
      wx_box(dl, cx + 5 * u, cy - 0.7 * u, cx + 7 * u, cy + 0.7 * u, z, wx_sun)
      if k == "sun" then return end
   end
   if k == "fog" then
      local i
      for i = 0, 2 do
	 wx_box(dl, x + (1 + mod(i, 2) * 2) * u, y + (5 + i * 3.5) * u,
		x + (14 - mod(i + 1, 2) * 2) * u, y + (6.5 + i * 3.5) * u, z,
		wx_cloud)
      end
      return
   end
   -- the cloud
   local col = (k == "storm" and wx_dark) or wx_cloud
   local cy = y + ((k == "cloud" or k == "part") and 4 or 2) * u
   if k == "part" then cy = y + 6 * u end
   wx_box(dl, x + 1 * u, cy + 4 * u, x + 15 * u, cy + 8.5 * u, z + 1, col)
   wx_box(dl, x + 4 * u, cy + 1.5 * u, x + 10 * u, cy + 5 * u, z + 1, col)
   wx_box(dl, x + 8.5 * u, cy + 2.8 * u, x + 13 * u, cy + 5 * u, z + 1, col)
   if k == "rain" then
      local i
      for i = 0, 2 do
	 local dx = x + (3.5 + i * 4) * u
	 wx_box(dl, dx, cy + 10 * u, dx + 1.2 * u, cy + 13 * u, z, wx_drop)
      end
   elseif k == "snow" then
      local i
      for i = 0, 2 do
	 local dx = x + (3 + i * 4) * u
	 wx_box(dl, dx, cy + 10.5 * u, dx + 1.8 * u, cy + 12.3 * u, z,
		{ 1, 1, 1, 1 })
      end
   elseif k == "storm" then
      wx_box(dl, x + 8 * u, cy + 9 * u, x + 10 * u, cy + 11 * u, z, wx_sun)
      wx_box(dl, x + 7 * u, cy + 11 * u, x + 9 * u, cy + 13.5 * u, z, wx_sun)
   end
end

function wx_temp(r, v)
   if not v then return "--" end
   if r.dash.cfg.wx_f == 1 then v = v * 9 / 5 + 32 end
   return format("%d", floor(v + 0.5))
end

-- a number with a little degree ring and the unit
function wx_draw_temp(r, dl, x, y, size, col, v, z, unit)
   local s = wx_temp(r, v)
   z = z or 30
   dl_text_prop(dl, 0, size)
   dl_draw_text(dl, x, y, z, col[1], col[2], col[3], col[4], s)
   local w = radio_width(s, size)
   local d = max(2, floor(size / 7))
   local dx, dy = x + w + 2, y + floor(size * 0.12)
   wx_box(dl, dx, dy, dx + d * 2, dy + d * 2, z, col)
   wx_box(dl, dx + d / 2, dy + d / 2, dx + d * 1.5, dy + d * 1.5, z + 1,
	  { 1, 0.05, 0.03, 0.02 })
   w = w + d * 2 + 4
   if unit then
      local u = (r.dash.cfg.wx_f == 1 and "F") or "C"
      local us = floor(size * 0.6)
      dl_text_prop(dl, 0, us)
      dl_draw_text(dl, x + w, y, z, col[1], col[2], col[3], col[4], u)
      w = w + radio_width(u, us) + 2
   end
   return w
end

-- top right of the home screen
function wx_draw_corner(r)
   local w = r.wx
   if not w then return end
   local dl = r.back
   local c = radio_col
   local city = wx_city(r)
   if not city then
      local s = "WEATHER : CHOOSE A CITY"
      radio_text(dl, 616 - radio_width(s, 12), 7, 12, c.dark, s)
      radio_hit(r, 616 - radio_width(s, 12) - 4, 2, radio_width(s, 12) + 8, 22,
		"dwx", 1)
      return
   end
   if not w.temp then return end
   local name = radio_fit(city, 12, 120)
   local nw = radio_width(name, 12)
   local x = 616 - nw
   radio_text(dl, x, 7, 12, c.dim, name)
   -- temperature : number and degree ring
   local ts = wx_temp(r, w.temp)
   local tw = radio_width(ts, 12) + 8
   x = x - tw - 8
   wx_draw_temp(r, dl, x, 7, 12, c.white, w.temp, 30)
   wx_icon(dl, x - 20, 5, 16, w.code, 30)
   radio_hit(r, x - 22, 2, 616 - x + 26, 22, "dwx", 1)
end

-- ----------------------------------------------------------------------
-- the Weather screen
-- ----------------------------------------------------------------------

function wx_open(r)
   r.wx_prev = (r.mode ~= "weather" and r.mode) or r.wx_prev or "main"
   r.mode = "weather"
   r.menu = nil
   if r.dash then dash_panel(r, nil) end
   local w = r.wx
   if not wx_city(r) then
      w.search = 1
      w.q = ""
      if r.chat then r.chat.osk_on = 1 end
   elseif not w.busy and (not w.temp or w.err) then
      w.t = 0
   end
   r.dirty = 1
end

function wx_close(r)
   local w = r.wx
   if r.chat then r.chat.osk_on = nil end
   w.search = nil
   r.mode = r.wx_prev or "main"
   r.dirty = 1
end

-- the on-screen keyboard's text, while searching
function wx_target(r)
   local w = r.wx
   if w.search then return "q", w, 30 end
end

function wx_enter(r)
   local w = r.wx
   if w.search then
      if w.results.n > 0 and w.picked then
	 wx_pick(r, w.results[w.sel])
      else
	 wx_ask_search(r)
      end
   end
   r.dirty = 1
end

function wx_pick(r, res)
   if not res then return end
   local w = r.wx
   local cf = r.dash.cfg
   cf.wx_name, cf.wx_lat, cf.wx_lon = res.name, res.lat, res.lon
   dash_save(r, 1)
   w.search = nil
   w.results = { n = 0 }
   w.temp = nil
   w.days = nil
   w.t = 0
   if r.chat then r.chat.osk_on = nil end
   r.dirty = 1
end

function wx_day_name(r, date, i)
   if i == 1 then return "TODAY" end
   local _, _, Y, M, D = strfind(date or "", "(%d+)%-(%d+)%-(%d+)")
   if not Y then return "" end
   local days = days_from_civil_lua(tonumber(Y), tonumber(M), tonumber(D))
   local wd = mod(days + 4, 7)
   if wd < 0 then wd = wd + 7 end
   return dash_days[wd + 1]
end

function days_from_civil_lua(y, m, d)
   if m <= 2 then y = y - 1 end
   local era = floor(y / 400)
   local yoe = y - era * 400
   local mp = m + 9
   if m > 2 then mp = m - 3 end
   local doy = floor((153 * mp + 2) / 5) + d - 1
   local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
   return era * 146097 + doe - 719468
end

function radio_draw_weather(r)
   local w = r.wx
   local dl = r.back
   local c = radio_col
   local cf = r.dash.cfg
   dash_draw_status(r)

   if w.search then
      radio_text(dl, 24, 36, 20, c.white, "Choose your city")
      radio_frame(dl, 24, 66, 592, 214, c.fill, c.frame, c.fill2)
      radio_text(dl, 40, 78, 12, c.label, "TYPE A CITY, THEN SEARCH")
      radio_frame(dl, 40, 96, 560, 30, c.black, c.frame)
      radio_text(dl, 52, 103, 16, c.white, rchat_tail(w.q .. "_", 16, 536))
      local i
      for i = 1, w.results.n do
	 local res = w.results[i]
	 local y = 138 + (i - 1) * 23
	 local on = (i == w.sel) and w.picked
	 if on then radio_grad(dl, 34, y - 2, 572, 22, 15, c.sel, c.sel2, 1) end
	 radio_text(dl, 48, y + 1, 14, (on and c.white) or c.text,
		    radio_fit(res.full, 14, 540))
	 radio_hit(r, 34, y - 2, 572, 22, "dwxres", i)
      end
      if w.msg then
	 radio_text(dl, 48, 140 + w.results.n * 23, 14, c.dim, w.msg)
      end
      if r.chat and r.chat.osk_on then rchat_draw_osk(r, 300)
      elseif w.picked and w.results.n > 0 then
	 radio_draw_hints(r, { { "A", "Choose", "a" }, { "^v", "Pick" },
			       { "B", "Type again", "b" } })
      else
	 radio_draw_hints(r, { { "A", "Keyboard", "a" }, { "B", "Back", "b" } })
      end
      return
   end

   local city = wx_city(r) or ""
   radio_text(dl, 24, 36, 20, c.white, radio_fit(city, 20, 420))
   if w.updated then
      local s = "UPDATED " .. w.updated
      radio_text(dl, 616 - radio_width(s, 12), 42, 12, c.dim, s)
   end
   -- now
   radio_frame(dl, 24, 68, 592, 170, c.fill, c.frame, c.fill2)
   if not w.temp then
      local m = (w.busy and "Looking at the sky...") or w.err
	 or (net_connected and "Looking at the sky...") or "Not connected"
      radio_text(dl, 48, 140, 18, c.dim, m)
   else
      wx_icon(dl, 48, 88, 96, w.code, 30)
      local x = 170
      wx_draw_temp(r, dl, x, 92, 56, c.white, w.temp, 30, 1)
      local cond = wx_info(w.code, 1)
      radio_text(dl, x, 158, 20, c.text, cond)
      local lines = {}
      if w.feels then
	 tinsert(lines, "FEELS LIKE " .. wx_temp(r, w.feels))
      end
      if w.wind then
	 if cf.wx_f == 1 then
	    tinsert(lines, format("WIND %d MPH", floor(w.wind / 1.609 + 0.5)))
	 else
	    tinsert(lines, format("WIND %d KM/H", floor(w.wind + 0.5)))
	 end
      end
      if w.hum then tinsert(lines, format("HUMIDITY %d%%", w.hum)) end
      local i
      for i = 1, getn(lines) do
	 radio_text(dl, 420, 96 + (i - 1) * 26, 14, c.dim, lines[i])
      end
      if w.err then
	 radio_text(dl, 170, 200, 12, rchat_bad or c.star,
		    radio_fit("Not updated : " .. w.err, 12, 420))
      end
   end
   -- five days
   if w.days and w.days.n > 0 then
      local n = min(w.days.n, 5)
      local cw = floor((592 - (n - 1) * 8) / n)
      local i
      for i = 1, n do
	 local dd = w.days[i]
	 local x = 24 + (i - 1) * (cw + 8)
	 radio_frame(dl, x, 250, cw, 150, c.fill, (i == 1 and c.frame) or c.dark,
		     c.fill2)
	 local dn = wx_day_name(r, dd.date, i)
	 radio_text(dl, x + floor((cw - radio_width(dn, 12)) / 2), 260, 12,
		    c.label, dn)
	 wx_icon(dl, x + floor((cw - 40) / 2), 282, 40, dd.code, 30)
	 local hs = wx_temp(r, dd.hi)
	 local ls = wx_temp(r, dd.lo)
	 local hw = radio_width(hs, 20) + 8
	 wx_draw_temp(r, dl, x + floor(cw / 2) - hw - 2, 334, 20, c.white, dd.hi, 30)
	 wx_draw_temp(r, dl, x + floor(cw / 2) + 8, 338, 14, c.dim, dd.lo, 30)
	 local cond = wx_info(dd.code, 1)
	 radio_text(dl, x + floor((cw - radio_width(radio_fit(cond, 12, cw - 8), 12)) / 2),
		    370, 12, c.dim, radio_fit(cond, 12, cw - 8))
      end
   end
   radio_draw_hints(r, {
		       { "A", "Change city", "a" },
		       { "X", (cf.wx_f == 1 and "Celsius") or "Fahrenheit", "x" },
		       { "Y", "Refresh", "y" },
		       { "B", "Back", "b" },
		       { "Start", "Menu", "menu" },
		    })
end

function wx_key(r, key)
   local w = r.wx
   local ch = r.chat
   if w.search then
      -- a real keyboard types ; the controller uses the keyboard on screen
      if key >= 32 and key < 127 then
	 if strlen(w.q) < 30 then w.q = w.q .. strchar(key) end
	 w.picked = nil
	 r.dirty = 1
	 return
      end
      if key == KBD_BACKSPACE then
	 w.q = strsub(w.q, 1, max(0, strlen(w.q) - 1))
	 w.picked = nil
	 r.dirty = 1
	 return
      end
      if key == KBD_ENTER then wx_enter(r) return end
      if ch and ch.osk_on then
	 if rchat_osk_key(r, key) then return end
      end
      if w.picked and w.results.n > 0 then
	 if gui_keyup[key] then
	    if w.sel > 1 then w.sel = w.sel - 1
	    else
	       w.picked = nil
	       if ch then ch.osk_on = 1 end
	    end
	 elseif gui_keydown[key] then
	    w.sel = min(w.results.n, w.sel + 1)
	 elseif gui_keyconfirm[key] then
	    wx_pick(r, w.results[w.sel])
	 elseif gui_keycancel[key] then
	    w.picked = nil
	    if ch then ch.osk_on = 1 end
	 end
	 r.dirty = 1
	 return
      end
      if gui_keyconfirm[key] and ch then
	 ch.osk_on = 1
      elseif key == KBD_ESC or gui_keycancel[key] then
	 if wx_city(r) then
	    w.search = nil
	    if ch then ch.osk_on = nil end
	 else
	    wx_close(r)
	 end
      end
      r.dirty = 1
      return
   end
   if gui_keyconfirm[key] then
      w.search = 1
      w.q = ""
      w.results = { n = 0 }
      w.msg = nil
      if ch then ch.osk_on = 1 end
   elseif gui_keyselect[key] then
      r.dash.cfg.wx_f = 1 - r.dash.cfg.wx_f
      dash_save(r, 1)
   elseif gui_keymenu[key] then
      if not w.busy then w.t = 0 end
   elseif gui_keycancel[key] or key == KBD_ESC then
      wx_close(r)
   end
   r.dirty = 1
end

function wx_action(r, name)
   if name == "a" then wx_key(r, KBD_CONT1_A)
   elseif name == "b" then wx_key(r, KBD_CONT1_B)
   elseif name == "x" then wx_key(r, KBD_CONT1_X)
   elseif name == "y" then wx_key(r, KBD_CONT1_Y) end
end
