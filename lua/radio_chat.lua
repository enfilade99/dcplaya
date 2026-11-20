--- @file     radio_chat.lua
--- @date     2026/11/17
--- @brief    Chat in the player : IRC #dc99 and KosNet global chat.
---
--- Two views, never mixed : IRC (live, #dc99 on irc.dc99.net, the same
--- room as the dc99.net web client) and KosNet global chat (through
--- dc99.net). The network work is done by the net plugin (chat.c) ; this
--- file keeps the conversations and draws them. The music keeps playing,
--- and a note pops up when someone says your name while the chat is shut.

rchat_cfg_filename = "/ram/dcplaya/configs/chat.cfg"
rchat_max_lines = 150
rchat_row_h = 18
rchat_kos_every = 12 -- seconds between two KosNet reads, view open

rchat_hues = {
   { "red", 0 }, { "orange", 28 }, { "yellow", 50 }, { "green", 100 },
   { "teal", 160 }, { "cyan", 190 }, { "blue", 215 }, { "purple", 265 },
   { "pink", 320 }, { "rose", 345 },
}

-- ----------------------------------------------------------------------
-- settings
-- ----------------------------------------------------------------------

function rchat_init(r)
   local ch = {
      view = 1,
      convs = { n = 0 },
      cur = 1,
      input = "",
      users = { n = 0 },
      hues = {},
      focus = 1,
      kfocus = 1,
      kscroll = 0,
      tick = 0,
      kos_t = 0,
      state = 0,
      cfg = { host = "irc.dc99.net", nick = "", pass = "", hue = -1,
	      ts = 0, sys = 0, ignore = "", token = "", kname = "" },
   }
   rchat_conv(ch, "#dc99")
   chat_saved = nil
   local file = openfile(rchat_cfg_filename, "r")
   if file then
      closefile(file)
      dofile(rchat_cfg_filename)
   end
   if type(chat_saved) == "table" then
      local k, v
      for k, v in chat_saved do
	 if ch.cfg[k] and type(v) == type(ch.cfg[k]) then ch.cfg[k] = v end
      end
      ch.saved = 1
   end
   chat_saved = nil
   -- (a test disc can point the chat at its own servers)
   if type(rchat_test_cfg) == "table" then
      local k, v
      for k, v in rchat_test_cfg do ch.cfg[k] = v end
   end
   if rchat_kos_host and chat_kos_server then
      chat_kos_server(rchat_kos_host, rchat_kos_port or 80,
		      rchat_kos_path or "/online/app.php")
   end
   r.chat = ch
   return ch
end

-- The DC99 app keeps its settings on the memory card (DC99NET) : the same
-- nickname, password, colour and KosNet sign-in work here. Read only.
function rchat_read_dc99(ch)
   if ch.dc99_done or not chat_dc99net then return end
   ch.dc99_done = 1
   local d = chat_dc99net()
   if type(d) ~= "table" then return end
   local cf = ch.cfg
   if cf.nick == "" and d.nick ~= "" then
      cf.nick, cf.pass = d.nick, d.pass
      if d.hue and d.hue >= 0 and d.hue < 360 then cf.hue = d.hue end
      cf.ts = d.ts or cf.ts
      cf.sys = d.sys or cf.sys
      if d.ignore ~= "" then cf.ignore = d.ignore end
      if d.host ~= "" then cf.host = d.host end
      ch.from_dc99 = 1
   end
   if cf.token == "" and d.token ~= "" then
      cf.token, cf.kname = d.token, d.kname
      ch.from_dc99 = 1
   end
end

function rchat_save(ch)
   local file = openfile(rchat_cfg_filename, "w")
   if not file then return end
   local cf = ch.cfg
   write(file, format("chat_saved = { host=%q, nick=%q, pass=%q, hue=%d,"
		      .. " ts=%d, sys=%d, ignore=%q, token=%q, kname=%q }\n",
		      cf.host, cf.nick, cf.pass, cf.hue, cf.ts, cf.sys,
		      cf.ignore, cf.token, cf.kname))
   closefile(file)
   if vmu_save then vmu_save(nil, 1) end
end

-- what chat.c wants
function rchat_ccfg(ch)
   local cf = ch.cfg
   local host, port = cf.host, 6667
   local i = strfind(host, ":", 1, 1)
   if i then
      port = tonumber(strsub(host, i + 1)) or 6667
      host = strsub(host, 1, i - 1)
   end
   if host == "" then host = "irc.dc99.net" end
   return { host = host, port = port, nick = cf.nick, pass = cf.pass,
	    hue = cf.hue, ts = cf.ts, sys = cf.sys, ignore = cf.ignore }
end

-- after a /color, /time ... the C side holds the new values
function rchat_take_cfg(ch)
   local c = chat_cfg and chat_cfg()
   if type(c) ~= "table" then return end
   local cf = ch.cfg
   cf.hue, cf.ts, cf.sys, cf.ignore = c.hue, c.ts, c.sys, c.ignore
   rchat_save(ch)
end

function rchat_set(ch, key, val)
   local cf = ch.cfg
   cf[key] = val
   if chat_cfg then chat_cfg(rchat_ccfg(ch)) end
   rchat_save(ch)
end

-- ----------------------------------------------------------------------
-- conversations
-- ----------------------------------------------------------------------

function rchat_conv(ch, name)
   local i
   for i = 1, ch.convs.n do
      if strlower(ch.convs[i].name) == strlower(name) then
	 return ch.convs[i], i
      end
   end
   if ch.convs.n >= 8 then
      tremove(ch.convs, ch.convs.n)
   end
   local c = { name = name, lines = { n = 0 }, unread = 0 }
   tinsert(ch.convs, c)
   return c, ch.convs.n
end

-- the colour of a name : hsl(hue, 62%, 68%), like the web client
function rchat_col(ch, nick, hue)
   local h = ch.hues[strlower(nick or "")] or hue or 30
   local s, l = 0.62, 0.68
   local c = (1 - abs(2 * l - 1)) * s
   local hp = h / 60
   local x = c * (1 - abs(mod(hp, 2) - 1))
   local r1, g1, b1 = 0, 0, 0
   if hp < 1 then r1, g1 = c, x
   elseif hp < 2 then r1, g1 = x, c
   elseif hp < 3 then g1, b1 = c, x
   elseif hp < 4 then g1, b1 = x, c
   elseif hp < 5 then r1, b1 = x, c
   else r1, b1 = c, x end
   local m = l - c / 2
   return { 1, r1 + m, g1 + m, b1 + m }
end

function rchat_visible(r)
   return r.shown and r.mode == "chat" and not r.hud_off and not r.menu
end

function rchat_event(r, e)
   local ch = r.chat
   local k = e.k
   if k == "msg" or k == "act" or k == "mine" or k == "sys" then
      local conv, ci = rchat_conv(ch, e.conv or "#dc99")
      local ln = { k = k, nick = e.nick or "", text = e.text or "",
		   ts = e.ts, hue = e.hue, mention = e.mention }
      if k == "mine" and not e.hist then ln.mention = nil end
      tinsert(conv.lines, ln)
      if conv.lines.n > rchat_max_lines then tremove(conv.lines, 1) end
      local looking = rchat_visible(r) and ch.view == 1 and ci == ch.cur
      if looking then
	 if ch.scroll and ch.scroll > 0 then
	    -- reading older lines : stay where we are
	    ch.scroll = ch.scroll + 1
	 end
      elseif k ~= "sys" and k ~= "mine" and not e.hist then
	 conv.unread = conv.unread + 1
	 local dm = strsub(conv.name, 1, 1) ~= "#"
	 if e.mention or dm then
	    conv.mention = 1
	    if dash_notify then
	       dash_notify(r, (dm and "dm") or "chat",
			   (e.nick or "?") .. ": " .. (e.text or ""), ci)
	    end
	 end
      end
      r.dirty = 1
   elseif k == "users" then
      if chat_irc_users then ch.users = chat_irc_users() end
      r.dirty = 1
   elseif k == "color" then
      if e.nick then ch.hues[strlower(e.nick)] = e.hue end
      r.dirty = 1
   elseif k == "state" then
      rchat_state(r)
   elseif k == "kos" then
      if chat_kos_list then ch.kos = chat_kos_list() end
      if rchat_debug and chat_dbg and ch.kos then
	 local i
	 chat_dbg(format("kos n=%d err=%s", ch.kos.n, ch.kos.err or "-"))
	 for i = 1, ch.kos.n do
	    chat_dbg(format("%d [%s] [%s] [%s]", i, ch.kos[i].name,
			    ch.kos[i].time, ch.kos[i].msg))
	 end
      end
      if ch.kos and ch.kos.err then ch.knote = ch.kos.err ch.kbad = 1
      elseif ch.knote == "Loading..." then ch.knote = nil end
      r.dirty = 1
   elseif k == "feed" then
      if dash_feed then dash_feed(r, e) end
   elseif k == "kostoken" then
      ch.cfg.token = e.text or ""
      ch.cfg.kname = e.nick or ""
      rchat_save(ch)
      ch.kform = nil
      ch.knote, ch.kbad = "Signed in to KosNet as " .. ch.cfg.kname, nil
      r.dirty = 1
   elseif k == "kossent" then
      ch.knote, ch.kbad = "Sent", nil
      ch.kscroll = 0
      r.dirty = 1
   elseif k == "koserr" then
      ch.knote, ch.kbad = e.text or "KosNet said no", 1
      if e.ended then
	 ch.cfg.token, ch.cfg.kname = "", ""
	 rchat_save(ch)
      end
      r.dirty = 1
   end
end

function rchat_state(r)
   local ch = r.chat
   if not chat_irc_state then return end
   local st, msg, me, np = chat_irc_state()
   if st ~= ch.state or msg ~= ch.msg or me ~= ch.me then
      if st == 3 and ch.state ~= 3 then
	 ch.focus = 0 -- the message line
	 ch.scroll = 0
      end
      if st ~= 3 and ch.state == 3 then ch.users = { n = 0 } end
      ch.state, ch.msg, ch.me = st, msg, me
      r.dirty = 1
   end
end

-- every frame, the chat shown or not
function rchat_update(r, frametime)
   local ch = r.chat
   if not ch or not chat_poll then return end
   local ev = chat_poll()
   if ev and ev.n > 0 then
      -- a burst of lines (logging in, channel history) redraws the screen
      -- at most five times a second, not every frame
      local was = r.dirty
      local i
      for i = 1, ev.n do rchat_event(r, ev[i]) end
      if r.dirty and not was then
	 r.dirty = nil
	 ch.pend = 1
      end
   end
   ch.redraw_t = (ch.redraw_t or 0) - frametime
   if ch.pend and ch.redraw_t <= 0 then
      ch.pend = nil
      ch.redraw_t = 0.2
      r.dirty = 1
   end
   if r.chat_toast then
      r.chat_toast.t = r.chat_toast.t - frametime
      if r.chat_toast.t <= 0 then
	 r.chat_toast = nil
	 r.dirty = 1
      end
   end
   if r.mode ~= "chat" then return end
   ch.tick = ch.tick + frametime
   if ch.tick >= 0.5 then
      ch.tick = 0
      rchat_state(r)
      rchat_auto(r)
      local t = chat_irc_typers and chat_irc_typers()
      if t ~= ch.typers then
	 ch.typers = t
	 r.dirty = 1
      end
      if ch.state == 1 or ch.state == 2 then
	 ch.dots = mod((ch.dots or 0) + 1, 4)
	 r.dirty = 1
      end
      if ch.view == 2 and ch.kos and ch.kos.busy then
	 if chat_kos_list then
	    local l = chat_kos_list()
	    if not l.busy then ch.kos.busy = nil r.dirty = 1 end
	 end
      end
   end
   if ch.view == 2 and r.shown and chat_kos_refresh then
      ch.kos_t = ch.kos_t - frametime
      if ch.kos_t <= 0 then
	 -- quietly, every few seconds ; what we had stays on screen
	 if chat_kos_refresh() then ch.kos_t = rchat_kos_every
	 else ch.kos_t = 1 end
      end
   end
end

-- ----------------------------------------------------------------------
-- open, close, switch
-- ----------------------------------------------------------------------

function rchat_open(r, view, conv)
   local ch = r.chat
   if r.mode ~= "chat" then r.chat_prev = r.mode end
   if r.chat_prev == "chat" or r.chat_prev == "help" then
      r.chat_prev = "main"
   end
   r.mode = "chat"
   r.menu = nil
   r.chat_toast = nil
   if view then ch.view = view end
   if conv and ch.convs[conv] then ch.cur = conv end
   rchat_read_dc99(ch)
   rchat_seen(ch)
   rchat_state(r)
   -- a saved name and password : connect by itself (once). Never while
   -- the player is typing them.
   if ch.state == 0 and not ch.tried and ch.cfg.nick ~= ""
      and ch.cfg.pass ~= "" then
      ch.auto = 1
   end
   rchat_auto(r)
   if ch.state ~= 3 and ch.focus == 0 then ch.focus = 1 end
   if ch.view == 2 then ch.kos_t = 0 end
   r.dirty = 1
end

-- known name and password : straight in, as the DC99 app does (once the
-- network is up)
function rchat_auto(r)
   local ch = r.chat
   if ch.auto and ch.view == 1 and ch.state == 0 and not ch.tried
      and chat_irc_start and net_connected then
      ch.auto = nil
      ch.tried = 1
      chat_irc_start(rchat_ccfg(ch))
      rchat_state(r)
   end
end

function rchat_close(r)
   ch_osk_off(r)
   r.mode = r.chat_prev or "main"
   r.menu = nil
   r.dirty = 1
end

function rchat_seen(ch)
   local c = ch.convs[ch.cur]
   if c then c.unread, c.mention = 0, nil end
end

function rchat_switch(r)
   local ch = r.chat
   ch_osk_off(r)
   ch.view = 3 - ch.view
   ch.input = ""
   if ch.view == 2 then
      ch.kos_t = 0
      if not ch.kos then ch.knote, ch.kbad = "Loading...", nil end
   else
      rchat_open(r, 1)
   end
   r.dirty = 1
end

-- L : IRC, R : KosNet
function rchat_view(r, v)
   if r.chat and r.chat.view ~= v then rchat_switch(r) end
end

function rchat_next_conv(r, d)
   local ch = r.chat
   local n = ch.convs.n
   if n < 2 then return end
   ch.cur = ch.cur + (d or 1)
   if ch.cur > n then ch.cur = 1 end
   if ch.cur < 1 then ch.cur = n end
   ch.scroll = 0
   rchat_seen(ch)
   r.dirty = 1
end

-- unread lines everywhere (for the menu)
function rchat_unread(r)
   local ch = r.chat
   if not ch then return 0 end
   local i, n = 0, 0
   for i = 1, ch.convs.n do n = n + ch.convs[i].unread end
   return n
end

-- ----------------------------------------------------------------------
-- typing
-- ----------------------------------------------------------------------

-- the text the keys go to : field name in the table, the table, max length
function rchat_target(r)
   local ch = r.chat
   if ch.view == 1 then
      if ch.state == 3 then
	 if ch.focus == 0 then return "input", ch, 280 end
	 return
      end
      if ch.state == 1 or ch.state == 2 then return end
      if ch.focus == 1 then return "nick", ch.cfg, 20 end
      if ch.focus == 2 then return "pass", ch.cfg, 39 end
      if ch.focus == 3 then return "host", ch.cfg, 40 end
      return
   end
   if ch.kform then
      if ch.kfocus == 1 then return "user", ch.kform, 32 end
      if ch.kfocus == 2 then return "pw", ch.kform, 40 end
      return
   end
   if ch.cfg.token == "" then return end -- the SIGN IN button first
   return "input", ch, 200
end

function rchat_irc_connect(r)
   local ch = r.chat
   local cf = ch.cfg
   if cf.nick == "" then
      ch.focus = 1
      ch.err = "Type a nickname first."
   elseif cf.pass == "" then
      ch.focus = 2
      ch.err = "Type a password (it protects your nickname)."
   elseif not net_connected then
      ch.err = "Not connected to the internet : Start > Network settings."
   elseif chat_irc_start then
      if rchat_debug and chat_dbg then chat_dbg("connect: save") end
      ch.err = nil
      if cf.host == "" then cf.host = "irc.dc99.net" end
      rchat_save(ch)
      if rchat_debug and chat_dbg then chat_dbg("connect: saved, start") end
      ch.tried = 1
      if not chat_irc_start(rchat_ccfg(ch)) then
	 rchat_state(r)
	 if ch.state ~= 4 then
	    ch.err = "Still closing the last connection : try again."
	 end
      else
	 rchat_state(r)
      end
   end
   r.dirty = 1
end

function rchat_kos_signin(r)
   local ch = r.chat
   local f = ch.kform
   if not f then return end
   if f.user == "" then ch.kfocus = 1 return end
   if f.pw == "" then ch.kfocus = 2 return end
   if not net_connected then
      ch.knote, ch.kbad = "Not connected to the internet.", 1
      return
   end
   if chat_kos_login and chat_kos_login(f.user, f.pw) then
      f.pw = ""
      ch.knote, ch.kbad = "Signing in to KosNet...", nil
   else
      ch.knote, ch.kbad = "Busy : try again in a moment.", 1
   end
end

-- Enter, or A on a button
function rchat_enter(r)
   local ch = r.chat
   if ch.view == 1 then
      if ch.state == 3 then
	 local conv = ch.convs[ch.cur]
	 if ch.input ~= "" and chat_irc_say then
	    if chat_irc_say(conv.name, ch.input) then rchat_take_cfg(ch) end
	    ch.input = ""
	    ch.scroll = 0
	 end
      elseif ch.state ~= 1 and ch.state ~= 2 then
	 -- Enter on the name goes on to the password, unless it is
	 -- already there : then it connects
	 if ch.focus == 1 and ch.cfg.pass == "" then
	    ch.focus = 2
	 else
	    ch_osk_off(r)
	    rchat_irc_connect(r)
	 end
      end
   else
      if ch.kform then
	 if ch.kfocus == 4 then
	    ch_osk_off(r)
	    ch.kform = nil -- CANCEL
	 elseif ch.kfocus == 1 and ch.kform.pw == "" then ch.kfocus = 2
	 else
	    ch_osk_off(r)
	    rchat_kos_signin(r)
	 end
      elseif ch.cfg.token == "" then
	 ch.kform = { user = ch.cfg.kname or "", pw = "" }
	 ch.kfocus = 1
	 if ch.kform.user ~= "" then ch.kfocus = 2 end
      elseif ch.input ~= "" then
	 if not net_connected then
	    ch.knote, ch.kbad = "Not connected to the internet.", 1
	 elseif chat_kos_say and chat_kos_say(ch.cfg.token, ch.input) then
	    ch.input = ""
	    ch.knote, ch.kbad = "Sending...", nil
	 else
	    ch.knote, ch.kbad = "Busy : try again in a moment.", 1
	 end
      end
   end
   r.dirty = 1
end

-- A on the controller : the on-screen keyboard for a text, or a button
function rchat_confirm(r)
   local ch = r.chat
   local f = rchat_target(r)
   if f then
      ch.osk_on = 1
      r.dirty = 1
   else
      rchat_enter(r)
   end
end

-- ----------------------------------------------------------------------
-- DCPlaya's own on-screen keyboard
-- D-pad moves, A presses the key (letters, SPACE, DEL, the action key
-- like SEND or SIGN IN, CLOSE), B deletes, X shift, Y space.
-- ----------------------------------------------------------------------

rchat_osk_rows = {
   "1234567890-",
   "qwertyuiop/",
   "asdfghjkl'@",
   "zxcvbnm,.?!",
}
rchat_osk_kw, rchat_osk_kh = 50, 28

function ch_osk_off(r)
   if r.chat then r.chat.osk_on = nil end
end

-- the name of the action key for what is being typed
function rchat_osk_action(r)
   local ch = r.chat
   if r.mode == "weather" then return "SEARCH" end
   if ch.view == 1 then
      if ch.state == 3 then return "SEND" end
      if ch.focus == 1 and ch.cfg.pass == "" then return "NEXT" end
      return "CONNECT"
   end
   if ch.kform then
      if ch.kfocus == 1 and ch.kform.pw == "" then return "NEXT" end
      return "SIGN IN"
   end
   return "POST"
end

-- the bottom row : { label, id, width in keys }
function rchat_osk_bottom(r)
   local ch = r.chat
   return {
      { (ch.osk_shift and "ABC") or "abc", "shift", 2 },
      { "SPACE", "space", 3 },
      { "DEL", "del", 2 },
      { rchat_osk_action(r), "act", 2 },
      { "CLOSE", "close", 2 },
   }
end

-- what the keyboard types into : the chat, or the weather's city search
function osk_target(r)
   if r.mode == "weather" and wx_target then return wx_target(r) end
   return rchat_target(r)
end

function osk_enter(r)
   if r.mode == "weather" and wx_enter then wx_enter(r) else rchat_enter(r) end
end

function rchat_osk_press(r, row, col)
   local ch = r.chat
   local f, t, max = osk_target(r)
   if row <= 4 then
      if not f then return end
      local k = strsub(rchat_osk_rows[row], col, col)
      if ch.osk_shift then k = strupper(k) end
      if strlen(t[f]) < max then
	 t[f] = t[f] .. k
	 if f == "input" and ch.view == 1 and chat_irc_typing then
	    chat_irc_typing(ch.convs[ch.cur].name)
	 end
      end
      return
   end
   local b = rchat_osk_bottom(r)[col]
   if not b then return end
   if b[2] == "shift" then ch.osk_shift = (not ch.osk_shift) or nil
   elseif b[2] == "space" then
      if f and strlen(t[f]) < max then t[f] = t[f] .. " " end
   elseif b[2] == "del" then
      if f and strlen(t[f]) > 0 then t[f] = strsub(t[f], 1, strlen(t[f]) - 1) end
   elseif b[2] == "act" then osk_enter(r) r.dirty = 1
   elseif b[2] == "close" then ch_osk_off(r) r.dirty = 1
   end
end

-- controller keys while the keyboard is up ; 1 when used
function rchat_osk_key(r, key)
   local ch = r.chat
   if not ch.osk_on then return end
   if not osk_target(r) then ch_osk_off(r) return end
   local row, col = ch.osk_row or 2, ch.osk_col or 1
   local ncol = (row == 5 and 5) or 11
   local f0, t0 = osk_target(r)
   local before = f0 and t0[f0]
   if gui_keyup[key] then
      row = row - 1
      if row < 1 then row = 5 end
   elseif gui_keydown[key] then
      row = row + 1
      if row > 5 then row = 1 end
   elseif gui_keyleft[key] then
      col = col - 1
      if col < 1 then col = ncol end
   elseif gui_keyright[key] then
      col = col + 1
      if col > ncol then col = 1 end
   elseif gui_keyconfirm[key] then
      rchat_osk_press(r, row, col)
   elseif gui_keycancel[key] then
      -- B : delete a letter ; nothing left : close the keyboard
      local f, t = osk_target(r)
      if f and strlen(t[f]) > 0 then
	 t[f] = strsub(t[f], 1, strlen(t[f]) - 1)
      else
	 ch_osk_off(r)
	 r.dirty = 1
      end
   elseif gui_keyselect[key] then
      ch.osk_shift = (not ch.osk_shift) or nil
   elseif gui_keymenu[key] then
      local f, t, max = osk_target(r)
      if f and strlen(t[f]) < max then t[f] = t[f] .. " " end
   else
      return
   end
   -- moving between the letter rows and the bottom row : keep the place
   if row == 5 and (ch.osk_row or 2) ~= 5 then
      local b, x = rchat_osk_bottom(r), 0
      local i, k = 1, 1
      for i = 1, getn(b) do
	 if col > x then k = i end
	 x = x + b[i][3]
      end
      col = k
   end
   if row ~= 5 and (ch.osk_row or 2) == 5 then
      local b, x = rchat_osk_bottom(r), 0
      local i
      for i = 1, col - 1 do x = x + b[i][3] end
      col = min(11, x + 1)
   end
   ch.osk_row, ch.osk_col = row, col
   if not ch.osk_on then r.dirty = 1 end
   if not r.dirty then
      -- only the keyboard changes now ; the screen follows after a pause
      r.odirty = 1
      local f1, t1 = osk_target(r)
      if f1 ~= f0 or (f1 and t1[f1] ~= before) then
	 r.lazy = 0.6
      end
   end
   return 1
end

-- the keyboard is drawn later, in its own list (radio_draw_overlay)
function rchat_show_osk(r, y)
   r.osk_y = y
end

function rchat_draw_osk(r, y, dl)
   local ch = r.chat
   dl = dl or r.back
   local c = radio_col
   local kw, kh = rchat_osk_kw, rchat_osk_kh
   local x0 = 320 - floor(kw * 11 / 2)
   radio_box(dl, 0, y - 6, 640, 486 - y, 5, dash_shade or c.shade)
   radio_box(dl, 0, y - 6, 640, 1, 6, c.frame)
   local row, col = ch.osk_row or 2, ch.osk_col or 1
   local i, j
   for i = 1, 4 do
      local s = rchat_osk_rows[i]
      for j = 1, 11 do
	 local k = strsub(s, j, j)
	 if ch.osk_shift then k = strupper(k) end
	 local x, yy = x0 + (j - 1) * kw, y + (i - 1) * (kh + 3)
	 local on = (row == i and col == j)
	 radio_frame(dl, x + 2, yy, kw - 4, kh, (on and c.sel) or c.fill,
		     (on and c.frame) or c.dark, (on and c.sel2) or c.fill2)
	 radio_text(dl, x + floor((kw - radio_width(k, 18)) / 2), yy + 4, 18,
		    (on and c.white) or c.text, k)
	 radio_hit(r, x + 2, yy, kw - 4, kh, "cosk", i * 100 + j)
      end
   end
   local b = rchat_osk_bottom(r)
   local x = x0
   local yy = y + 4 * (kh + 3)
   for j = 1, getn(b) do
      local w = b[j][3] * kw
      local on = (row == 5 and col == j)
      local act = (b[j][2] == "act")
      radio_frame(dl, x + 2, yy, w - 4, kh,
		  (on and c.sel) or (act and c.sel2) or c.fill,
		  (on and c.frame) or (act and c.frame) or c.dark,
		  (on and c.sel2) or c.fill2)
      radio_text(dl, x + floor((w - radio_width(b[j][1], 14)) / 2), yy + 7, 14,
		 (on and c.white) or (act and c.white) or c.text, b[j][1])
      radio_hit(r, x + 2, yy, w - 4, kh, "cosk", 500 + j)
      x = x + w
   end
   -- what is being typed, right here (the field above catches up when
   -- the typing pauses)
   local f, t = osk_target(r)
   local help = "A PRESS  B DEL  X SHIFT  Y SPACE"
   local hw = radio_width(help, 12)
   radio_text(dl, x0 + 11 * kw - hw, yy + kh + 5, 12, c.dim, help)
   if f then
      local v = t[f] or ""
      if f == "pass" or f == "pw" then v = strrep("*", strlen(v)) end
      radio_text(dl, x0, yy + kh + 3, 14, c.white,
		 rchat_tail(v .. "_", 14, 11 * kw - hw - 16))
   end
end

function rchat_scroll(r, d)
   local ch = r.chat
   if ch.view == 1 then
      ch.scroll = (ch.scroll or 0) + d
      if ch.scroll < 0 then ch.scroll = 0 end
   else
      ch.kscroll = (ch.kscroll or 0) + d
      if ch.kscroll < 0 then ch.kscroll = 0 end
   end
   r.dirty = 1
end

function rchat_move(r, d)
   local ch = r.chat
   if ch.view == 1 and ch.state ~= 3 then
      if ch.state == 1 or ch.state == 2 then return end
      ch.focus = ch.focus + d
      if ch.focus < 1 then ch.focus = 1 end
      if ch.focus > 4 then ch.focus = 4 end
   elseif ch.view == 2 and ch.kform then
      -- Username, Password, then the SIGN IN / CANCEL row
      local k = ch.kfocus
      if k == 4 then k = 3 end
      k = k + d
      if k < 1 then k = 1 end
      if k > 3 then k = 3 end
      ch.kfocus = k
   else
      rchat_scroll(r, -2 * d)
      return
   end
   r.dirty = 1
end

-- buttons named by the hints and the mouse
function rchat_action(r, name)
   local ch = r.chat
   if name == "a" then rchat_confirm(r)
   elseif name == "b" then
      if ch.view == 2 and ch.kform then ch.kform = nil
      else rchat_close(r) end
   elseif name == "x" then rchat_switch(r)
   elseif name == "y" then
      if ch.view == 1 then rchat_next_conv(r, 1)
      else ch.kos_t = 0 ch.kscroll = 0 end
   elseif name == "send" then rchat_enter(r)
   elseif name == "up" then rchat_scroll(r, 6)
   elseif name == "down" then rchat_scroll(r, -6)
   end
   r.dirty = 1
end

function rchat_key(r, key)
   local ch = r.chat
   local f, t, max = rchat_target(r)
   if f and f ~= "input" then ch.auto = nil end
   if f and key >= 32 and key < 127 then
      if strlen(t[f]) < max then
	 t[f] = t[f] .. strchar(key)
	 if f == "input" and ch.view == 1 and chat_irc_typing
	    and strsub(t[f], 1, 1) ~= "/" then
	    chat_irc_typing(ch.convs[ch.cur].name)
	 end
      end
      r.dirty = 1
      return
   end
   if key == KBD_BACKSPACE and f then
      local n = strlen(t[f])
      if n > 0 then t[f] = strsub(t[f], 1, n - 1) end
      r.dirty = 1
      return
   end
   if key == KBD_ENTER then
      rchat_enter(r)
      return
   end
   if ch.osk_on and key ~= KBD_ESC and rchat_osk_key(r, key) then return 1 end
   if key == KBD_ESC then
      if ch.osk_on then ch_osk_off(r)
      elseif ch.view == 2 and ch.kform then ch.kform = nil
      else rchat_close(r) end
      r.dirty = 1
      return
   end
   if key == KBD_KEY_TAB or key == 9 then rchat_next_conv(r, 1) return end
   if key == KBD_KEY_F5 then rchat_switch(r) return end
   if gui_keycancel[key] then rchat_action(r, "b") return end
   if gui_keyconfirm[key] then rchat_confirm(r) return end
   if gui_keyselect[key] then rchat_switch(r) return end
   if gui_keymenu[key] then rchat_action(r, "y") return end
   if gui_keyup[key] then rchat_move(r, -1) return end
   if gui_keydown[key] then rchat_move(r, 1) return end
   if gui_keyleft[key] or gui_keyright[key] then
      if ch.view == 2 and ch.kform and ch.kfocus >= 3 then
	 ch.kfocus = 7 - ch.kfocus -- SIGN IN <-> CANCEL
      elseif ch.view == 1 and ch.state == 3 then
	 rchat_next_conv(r, (gui_keyleft[key] and -1) or 1)
      end
      r.dirty = 1
      return
   end
   if key == KBD_KEY_PGUP then rchat_scroll(r, 10) return end
   if key == KBD_KEY_PGDOWN then rchat_scroll(r, -10) return end
   if key == KBD_KEY_END then rchat_scroll(r, -100000) return end
end

-- a click on one of our parts
function rchat_click(r, h)
   local ch = r.chat
   local k = h.kind
   if k == "ctab" then
      if h.arg ~= ch.view then rchat_switch(r) end
   elseif k == "cconv" then
      ch.cur = h.arg
      ch.scroll = 0
      rchat_seen(ch)
   elseif k == "cuser" then
      -- a name : mention it
      if ch.state == 3 then
	 ch.focus = 0
	 if ch.input ~= "" and strsub(ch.input, -1) ~= " " then
	    ch.input = ch.input .. " "
	 end
	 ch.input = ch.input .. h.arg .. " "
      end
   elseif k == "cfield" then
      if ch.view == 1 then ch.focus = h.arg else ch.kfocus = h.arg end
      rchat_confirm(r)
   elseif k == "cbtn" then
      if ch.view == 1 then ch.focus = 4 else ch.kfocus = 3 end
      rchat_enter(r)
   elseif k == "ckcancel" then
      ch.kform = nil
      ch_osk_off(r)
   elseif k == "cinput" then
      ch.focus = 0
      rchat_confirm(r)
   elseif k == "cpost" then
      rchat_enter(r)
   elseif k == "cosk" then
      local row, col = floor(h.arg / 100), mod(h.arg, 100)
      ch.osk_row, ch.osk_col = row, col
      rchat_osk_press(r, row, col)
   elseif k == "ctoast" then
      local t = r.chat_toast
      rchat_open(r, 1, t and t.conv)
   end
   r.dirty = 1
end

-- ----------------------------------------------------------------------
-- drawing
-- ----------------------------------------------------------------------

rchat_bad = { 1.00, 1.00, 0.45, 0.35 }

-- cut a text in rows : first row w1 wide, the others w2
function rchat_wrap(s, size, w1, w2)
   local rows = { n = 0 }
   local w = w1
   while s ~= "" do
      if radio_width(s, size) <= w then
	 tinsert(rows, s)
	 break
      end
      -- the longest start that fits, cut at a space when there is one
      local n = strlen(s)
      local lo, hi = 1, n
      while lo < hi do
	 local mid = floor((lo + hi + 1) / 2)
	 if radio_width(strsub(s, 1, mid), size) <= w then lo = mid
	 else hi = mid - 1 end
      end
      local cut = lo
      local i
      for i = lo, 2, -1 do
	 if strsub(s, i, i) == " " then cut = i - 1 break end
	 if lo - i > 24 then break end
      end
      if cut < 1 then cut = 1 end
      tinsert(rows, strsub(s, 1, cut))
      s = strsub(s, cut + 1)
      while strsub(s, 1, 1) == " " do s = strsub(s, 2) end
      w = w2
   end
   if rows.n == 0 then tinsert(rows, "") end
   return rows
end

-- the rows of one IRC line, kept until the width changes
function rchat_rows(ch, ln, width)
   if ln.rows and ln.rw == width then return ln.rows end
   local lead = 0
   if ln.ts and ln.ts ~= "" then lead = radio_width(ln.ts, 12) + 8 end
   if ln.k == "sys" then
      ln.rows = rchat_wrap(ln.text, 12, width - lead, width - 20)
   else
      local nick = ln.nick
      if ln.k == "act" then nick = "* " .. nick end
      lead = lead + radio_width(nick, 14) + 8
      ln.rows = rchat_wrap(ln.text, 14, width - lead, width - 20)
   end
   ln.lead = lead
   ln.rw = width
   return ln.rows
end

function rchat_draw_tabs(r)
   local dl = r.back
   local c = radio_col
   local ch = r.chat
   local names = { "IRC  #DC99", "KOSNET GLOBAL" }
   local x, i = 24, 1
   for i = 1, 2 do
      local w = radio_width(names[i], 14) + 24
      local act = (i == ch.view)
      radio_frame(dl, x, 22, w, 26, (act and c.sel) or c.fill,
		  (act and c.frame) or c.dark, (act and c.sel2) or c.fill2)
      radio_text(dl, x + 12, 28, 14, (act and c.white) or c.dim, names[i])
      -- something new on the other side : a dot
      if not act and i == 1 and rchat_unread(r) > 0 then
	 radio_box(dl, x + w - 9, 26, 5, 5, 25, c.star)
      end
      radio_hit(r, x, 22, w, 26, "ctab", i)
      x = x + w + 6
   end
   -- what is playing, small, so the chat never hides the radio
   local name = radio_now(r)
   local t
   if r.playing and name then t = "> " .. name
   elseif name then t = "STOPPED" end
   if t then
      t = radio_fit(t, 12, 590 - x)
      radio_text(dl, 616 - radio_width(t, 12), 30, 12,
		 (r.playing and c.green) or c.dark, t)
   end
end

-- one text box ; focused : bright edge and a cursor
function rchat_field(r, x, y, w, label, val, foc, secret, fi)
   local dl = r.back
   local c = radio_col
   radio_text(dl, x, y + 6, 14, (foc and c.white) or c.dim, label)
   local fx = x + 120
   radio_frame(dl, fx, y, w - 120, 28, c.black, (foc and c.frame) or c.dark)
   local s = val or ""
   if secret then s = strrep("*", strlen(s)) end
   if foc then s = s .. "_" end
   while strlen(s) > 1 and radio_width(s, 16) > w - 140 do
      s = strsub(s, 2)
   end
   radio_text(dl, fx + 10, y + 6, 16, c.white, s)
   radio_hit(r, fx, y, w - 120, 28, "cfield", fi)
end

function rchat_button(r, x, y, label, foc, kind)
   local dl = r.back
   local c = radio_col
   local w = radio_width(label, 14) + 32
   radio_frame(dl, x, y, w, 28, (foc and c.sel) or c.fill,
	       (foc and c.frame) or c.dark, (foc and c.sel2) or c.fill2)
   radio_text(dl, x + 16, y + 7, 14, (foc and c.white) or c.text, label)
   radio_hit(r, x, y, w, 28, kind or "cbtn", 1)
   return w
end

function rchat_draw_irc_login(r, y0, h)
   local dl = r.back
   local c = radio_col
   local ch = r.chat
   local cf = ch.cfg
   radio_frame(dl, 24, y0, 592, h, c.fill, c.frame, c.fill2)
   radio_text(dl, 44, y0 + 14, 20, c.white, "Join #dc99 on IRC")
   radio_text(dl, 44, y0 + 42, 14, c.dim,
	      "Chat live with everyone on the dc99.net web client.")
   if ch.state == 1 or ch.state == 2 then
      local d = strsub("...", 1, ch.dots or 0)
      radio_text(dl, 44, y0 + 90, 20, c.text,
		 ((ch.state == 1 and "Connecting") or "Logging in") .. d)
      radio_text(dl, 44, y0 + 122, 14, c.dim,
		 radio_fit(ch.msg or "", 14, 540))
      return
   end
   local y = y0 + 74
   local compact = h < 260
   local gap = (compact and 34) or 40
   rchat_field(r, 44, y, 420, "Nickname", cf.nick, ch.focus == 1, nil, 1)
   rchat_field(r, 44, y + gap, 420, "Password", cf.pass, ch.focus == 2, 1, 2)
   rchat_field(r, 44, y + gap * 2, 420, "Server", cf.host, ch.focus == 3,
	       nil, 3)
   rchat_button(r, 476, y + gap * 2, "CONNECT", ch.focus == 4)
   local ny = y + gap * 3 + 6
   local err = ch.err
   if not err and ch.state == 4 and ch.msg ~= "" then err = ch.msg end
   if err then
      local rows = rchat_wrap(err, 14, 540, 540)
      local i
      for i = 1, min(rows.n, 2) do
	 radio_text(dl, 44, ny + (i - 1) * 18, 14, rchat_bad, rows[i])
      end
   elseif not compact then
      if ch.from_dc99 then
	 radio_text(dl, 44, ny, 12, c.green,
		    "NAME AND PASSWORD FOUND ON THE MEMORY CARD (DC99 APP).")
	 ny = ny + 18
      end
      radio_text(dl, 44, ny, 12, c.dim,
		 "A NEW NICK + PASSWORD MAKES YOUR ACCOUNT, LIKE THE WEB.")
      radio_text(dl, 44, ny + 18, 12, c.dark,
		 "SENT WITHOUT ENCRYPTION : USE A PASSWORD JUST FOR IRC.")
   end
end

function rchat_draw_irc(r, y0, h)
   local dl = r.back
   local c = radio_col
   local ch = r.chat
   local conv = ch.convs[ch.cur]
   if not conv then ch.cur = 1 conv = ch.convs[1] end

   -- messages on the left, people on the right
   local mw = 448
   radio_frame(dl, 24, y0, mw, h, c.fill, c.frame, c.fill2)
   radio_frame(dl, 24 + mw + 6, y0, 592 - mw - 6, h, c.fill, c.dark,
	       c.fill2)

   -- conversations
   local x, i = 34, 1
   for i = 1, ch.convs.n do
      local cv = ch.convs[i]
      local lab = cv.name
      if cv.unread > 0 and i ~= ch.cur then
	 lab = format("%s (%d)", lab, cv.unread)
      end
      local w = radio_width(lab, 12) + 14
      if x + w > 24 + mw - 10 then break end
      local act = (i == ch.cur)
      if act then
	 radio_box(dl, x, y0 + 7, w, 18, 15, c.sel)
      elseif cv.mention then
	 radio_box(dl, x, y0 + 7, w, 18, 15, c.dark)
      end
      radio_text(dl, x + 7, y0 + 10, 12,
		 (act and c.white) or (cv.mention and c.star) or c.label, lab)
      radio_hit(r, x, y0 + 7, w, 18, "cconv", i)
      x = x + w + 4
   end
   radio_box(dl, 34, y0 + 29, mw - 20, 1, 15, c.dark)

   -- the lines, newest at the bottom
   local top = y0 + 36
   local bottom = y0 + h - 8
   if ch.typers then bottom = bottom - 16 end
   local nrows = floor((bottom - top) / rchat_row_h)
   local width = mw - 34
   local skip = ch.scroll or 0
   local vis = {}
   local nv = 0
   local li = conv.lines.n
   local total = 0
   while li >= 1 and nv < nrows do
      local ln = conv.lines[li]
      local rows = rchat_rows(ch, ln, width)
      local ri
      for ri = rows.n, 1, -1 do
	 if skip > 0 then
	    skip = skip - 1
	 elseif nv < nrows then
	    nv = nv + 1
	    vis[nv] = { ln, ri }
	 end
      end
      li = li - 1
   end
   if li < 1 and skip > 0 then
      -- scrolled past the oldest line
      ch.scroll = ch.scroll - skip
   end
   if conv.lines.n == 0 then
      radio_text(dl, 40, top + 6, 14, c.dim, "Nothing said yet. Say hello!")
   end
   local k
   for k = nv, 1, -1 do
      local ln, ri = vis[k][1], vis[k][2]
      local y = top + (nv - k) * rchat_row_h
      local x0 = 36
      if ln.mention and ln.k ~= "sys" then
	 radio_box(dl, 30, y - 1, mw - 18, rchat_row_h, 12, c.dark)
      end
      if ri == 1 then
	 if ln.ts and ln.ts ~= "" then
	    radio_text(dl, x0, y + 3, 12, c.dark, ln.ts)
	    x0 = x0 + radio_width(ln.ts, 12) + 8
	 end
	 if ln.k == "sys" then
	    radio_text(dl, x0, y + 3, 12, c.dim, ln.rows[1])
	 else
	    local nick = ln.nick
	    if ln.k == "act" then nick = "* " .. nick end
	    local col = rchat_col(ch, ln.nick, ln.hue)
	    radio_text(dl, x0, y + 1, 14, col, nick)
	    x0 = x0 + radio_width(nick, 14) + 8
	    radio_text(dl, x0, y + 1, 14,
		       (ln.k == "act" and col) or c.white, ln.rows[1])
	 end
      else
	 if ln.k == "sys" then
	    radio_text(dl, x0 + 20, y + 3, 12, c.dim, ln.rows[ri])
	 else
	    radio_text(dl, x0 + 20, y + 1, 14,
		       (ln.k == "act" and rchat_col(ch, ln.nick, ln.hue))
			  or c.white, ln.rows[ri])
	 end
      end
   end
   if (ch.scroll or 0) > 0 then
      local t = "MORE BELOW : v"
      radio_box(dl, 24 + mw - 130, bottom - 4, 118, 16, 25, c.sel)
      radio_text(dl, 24 + mw - 124, bottom - 2, 12, c.white, t)
      radio_hit(r, 24 + mw - 130, bottom - 4, 118, 16, "key", "down")
   end
   if ch.typers then
      local t = ch.typers .. " is typing..."
      if strfind(ch.typers, ",", 1, 1) then
	 t = ch.typers .. " are typing..."
      end
      radio_text(dl, 36, y0 + h - 22, 12, c.dim, radio_fit(t, 12, mw - 30))
   end

   -- people
   local px = 24 + mw + 16
   local users = ch.users or { n = 0 }
   radio_text(dl, px, y0 + 10, 12, c.label, format("PEOPLE  %d", users.n))
   local maxn = floor((h - 44) / 18)
   for i = 1, min(users.n, maxn) do
      local u = users[i]
      local y = y0 + 32 + (i - 1) * 18
      if i == maxn and users.n > maxn then
	 radio_text(dl, px, y + 2, 12, c.dim,
		    format("+%d MORE", users.n - maxn + 1))
      else
	 radio_box(dl, px, y + 6, 5, 5, 15, c.green)
	 radio_text(dl, px + 12, y, 14, rchat_col(ch, u.nick, u.hue),
		    radio_fit(u.nick, 14, 592 - mw - 40))
	 radio_hit(r, px - 6, y - 1, 592 - mw - 18, 18, "cuser", u.nick)
      end
   end
end

function rchat_draw_kos(r, y0, h)
   local dl = r.back
   local c = radio_col
   local ch = r.chat
   local cf = ch.cfg
   radio_frame(dl, 24, y0, 592, h, c.fill, c.frame, c.fill2)
   radio_box(dl, 38, y0 + 13, 7, 7, 15, c.green)
   radio_text(dl, 52, y0 + 10, 12, c.star, "LIVE")
   radio_text(dl, 92, y0 + 8, 14, c.white, "KosNet global chat")
   local t
   if cf.token ~= "" then t = "SIGNED IN: " .. strupper(cf.kname)
   else t = "NOT SIGNED IN" end
   radio_text(dl, 604 - radio_width(t, 12), y0 + 10, 12, c.dim, t)
   radio_box(dl, 34, y0 + 29, 572, 1, 15, c.dark)

   if ch.kform then
      local f = ch.kform
      local y = y0 + 44
      radio_text(dl, 44, y, 20, c.white, "Sign in to KosNet")
      radio_text(dl, 44, y + 28, 14, c.dim,
		 "Your own KosNet account. Your password is only used")
      radio_text(dl, 44, y + 46, 14, c.dim,
		 "to sign in : it is never kept.")
      local gap = (h < 260 and 34) or 40
      y = y + 70
      rchat_field(r, 44, y, 420, "Username", f.user, ch.kfocus == 1, nil, 1)
      rchat_field(r, 44, y + gap, 420, "Password", f.pw, ch.kfocus == 2,
		  1, 2)
      local bw = rchat_button(r, 164, y + gap * 2 + 4, "SIGN IN", ch.kfocus == 3)
      rchat_button(r, 164 + bw + 10, y + gap * 2 + 4, "CANCEL", ch.kfocus == 4,
		   "ckcancel")
      return
   end

   local top = y0 + 36
   local bottom = y0 + h - 8
   local nrows = floor((bottom - top) / rchat_row_h)
   local list = ch.kos
   if not list or list.n == 0 then
      local m = (list and "No chat messages yet.") or "Loading..."
      if not net_connected then m = "Not connected to the internet." end
      radio_text(dl, 40, top + 8, 14, c.dim, m)
      return
   end
   -- each message : a header row then its text
   local vis = {}
   local nv = 0
   local skip = ch.kscroll or 0
   local i = list.n
   while i >= 1 and nv < nrows do
      local m = list[i]
      if not m.rows then m.rows = rchat_wrap(m.msg, 14, 548, 548) end
      local ri
      for ri = m.rows.n, 0, -1 do
	 if skip > 0 then skip = skip - 1
	 elseif nv < nrows then
	    nv = nv + 1
	    vis[nv] = { m, ri }
	 end
      end
      i = i - 1
   end
   if i < 1 and skip > 0 then ch.kscroll = ch.kscroll - skip end
   local k
   for k = nv, 1, -1 do
      local m, ri = vis[k][1], vis[k][2]
      local y = top + (nv - k) * rchat_row_h
      if ri == 0 then
	 radio_text(dl, 40, y + 2, 14, c.star, m.name)
	 local x = 40 + radio_width(m.name, 14) + 10
	 if m.game and m.game ~= "" then
	    local gw = radio_width(m.game, 12) + 12
	    radio_frame(dl, x, y + 1, gw, 16, c.black, c.dark)
	    radio_text(dl, x + 6, y + 3, 12, c.label, m.game)
	    x = x + gw + 8
	 end
	 radio_text(dl, x, y + 3, 12, c.dim, m.time or "")
      else
	 radio_text(dl, 52, y + 1, 14, c.white, m.rows[ri])
      end
   end
   if (ch.kscroll or 0) > 0 then
      radio_box(dl, 486, bottom - 4, 118, 16, 25, c.sel)
      radio_text(dl, 492, bottom - 2, 12, c.white, "MORE BELOW : v")
      radio_hit(r, 486, bottom - 4, 118, 16, "key", "down")
   end
end

-- the message line under the conversation
-- the end of a text that fits (what is being typed)
function rchat_tail(s, size, maxw)
   if radio_width(s, size) <= maxw then return s end
   local n = strlen(s)
   local lo, hi = 1, n
   while lo < hi do
      local mid = floor((lo + hi) / 2)
      if radio_width(strsub(s, mid), size) <= maxw then hi = mid
      else lo = mid + 1 end
   end
   return strsub(s, lo)
end

function rchat_draw_compose(r, y)
   local dl = r.back
   local c = radio_col
   local ch = r.chat
   local foc
   local s, hint
   local bw = 0
   if ch.view == 1 then
      if ch.state ~= 3 then return end
      foc = (ch.focus == 0)
      hint = "Message " .. ch.convs[ch.cur].name .. "   (A or keyboard,"
	 .. " /help)"
   else
      if ch.kform then return end
      if ch.cfg.token == "" then
	 -- not signed in : one clear button, already selected
	 local lab = "SIGN IN TO KOSNET TO POST"
	 radio_frame(dl, 24, y, 592, 30, c.sel, c.frame, c.sel2)
	 radio_text(dl, 320 - floor(radio_width(lab, 14) / 2), y + 8, 14,
		    c.white, lab)
	 radio_hit(r, 24, y, 592, 30, "cpost", 1)
	 return
      end
      foc = 1
      hint = "Say something on KosNet..."
      local lab = "POST"
      bw = radio_width(lab, 14) + 32
      radio_frame(dl, 616 - bw, y, bw, 30, c.sel, c.frame, c.sel2)
      radio_text(dl, 616 - bw + 16, y + 8, 14, c.white, lab)
      radio_hit(r, 616 - bw, y, bw, 30, "cpost", 1)
      bw = bw + 6
   end
   local w = 592 - bw
   radio_frame(dl, 24, y, w, 30, c.black,
	       (foc and ch.input ~= "" and c.frame) or c.dark)
   if ch.input == "" then
      radio_text(dl, 36, y + 7, 16, c.dark, radio_fit(hint, 16, w - 24))
   else
      s = rchat_tail(ch.input .. "_", 16, w - 24)
      radio_text(dl, 36, y + 7, 16, c.white, s)
   end
   if ch.view == 2 and ch.input ~= "" then
      local t = format("%d", 200 - strlen(ch.input))
      radio_text(dl, 24 + w - 12 - radio_width(t, 12), y - 14, 12, c.dim, t)
   end
   radio_hit(r, 24, y, w, 30, "cinput", 1)
end

function radio_draw_chat(r)
   local dl = r.back
   local c = radio_col
   local ch = r.chat
   rchat_draw_tabs(r)
   if not chat_poll then
      radio_frame(dl, 24, 60, 592, 330, c.fill, c.frame, c.fill2)
      radio_text(dl, 44, 80, 16, c.text, "The network plugin is not loaded.")
      radio_text(dl, 44, 104, 14, c.dim,
		 "Start > Network settings connects to the internet.")
      radio_draw_hints(r, { { "B", "Back", "b" }, { "Start", "Menu",
						     "menu" } })
      return
   end
   -- the on-screen keyboard covers the bottom of the screen
   if ch.osk_on and not rchat_target(r) then ch.osk_on = nil end
   local kb = ch.osk_on
   local y0, h, cy = 58, 326, 392
   if kb then h, cy = 192, 258 end
   local note
   if ch.view == 1 then
      if ch.state == 3 then
	 rchat_draw_irc(r, y0, h)
      else
	 rchat_draw_irc_login(r, y0, h)
      end
   else
      rchat_draw_kos(r, y0, h)
      note = ch.knote
   end
   rchat_draw_compose(r, cy)
   if kb then rchat_show_osk(r, 300) end
   if note and not kb then
      local col = (ch.kbad and rchat_bad) or c.dim
      radio_text(dl, 30, 428, 12, col, radio_fit(note, 12, 580))
   end
   if kb then return end
   local hints
   if ch.view == 1 then
      if ch.state == 3 then
	 hints = { { "A", "Write", "a" },
		   { "L R", "IRC / KosNet", "x" },
		   { "Y", "Next chat", "y" },
		   { "^v", "Scroll", nil },
		   { "B", "Back", "b" },
		   { "Start", "Menu", "menu" } }
      else
	 hints = { { "A", "Choose", "a" },
		   { "^v", "Move", nil },
		   { "L R", "IRC / KosNet", "x" },
		   { "B", "Back", "b" },
		   { "Start", "Menu", "menu" } }
      end
   elseif ch.kform then
      hints = { { "A", "Choose", "a" },
		{ "^v", "Move", nil },
		{ "B", "Cancel", "b" },
		{ "Start", "Menu", "menu" } }
   else
      hints = { { "A", (ch.cfg.token == "" and "Sign in") or "Write", "a" },
		{ "L R", "IRC / KosNet", "x" },
		{ "Y", "Refresh", "y" },
		{ "^v", "Scroll", nil },
		{ "B", "Back", "b" },
		{ "Start", "Menu", "menu" } }
   end
   radio_draw_hints(r, hints)
end

-- a note on the other screens when someone talks to you
function radio_draw_chat_toast(r)
   local t = r.chat_toast
   if not t or r.mode == "chat" then return end
   local dl = r.back
   local c = radio_col
   local s = radio_fit(t.text, 14, 470)
   local w = radio_width(s, 14) + 150
   if w > 600 then w = 600 end
   local x, y = 320 - w / 2, 400
   radio_frame(dl, x, y, w, 34, c.black, c.frame)
   radio_box(dl, x + 2, y + 2, 6, 30, 22, c.star)
   radio_text(dl, x + 16, y + 10, 14, c.white, s)
   radio_text(dl, x + w - 118, y + 11, 12, c.label, "F4 OR START: CHAT")
   radio_hit(r, x, y, w, 34, "ctoast", 1)
end

-- the pop-up menu while the chat is open
function rchat_menu_items(r, it)
   local ch = r.chat
   if not ch then return end
   local cf = ch.cfg
   if r.mode ~= "chat" then
      local u = rchat_unread(r)
      local v = "IRC, KosNet"
      if u > 0 then v = format("%d new", u) end
      tinsert(it, { name = "Chat", val = v, act = "chat" })
      return
   end
   local hn = "from the name"
   local i
   for i = 1, getn(rchat_hues) do
      if rchat_hues[i][2] == cf.hue then hn = rchat_hues[i][1] end
   end
   if cf.hue >= 0 and hn == "from the name" then hn = format("%d", cf.hue) end
   local tsn = { "12 hour", "24 hour", "off" }
   tinsert(it, { name = "Chat : name colour", val = hn, sub = "chathue" })
   tinsert(it, { name = "Chat : times", val = tsn[cf.ts + 1] or "?",
		 act = "chatts" })
   tinsert(it, { name = "Chat : joins and leaves",
		 val = (cf.sys == 1 and "shown") or "hidden", act = "chatsys" })
   local cv = ch.convs[ch.cur]
   if ch.view == 1 and cv and strsub(cv.name, 1, 1) ~= "#" then
      tinsert(it, { name = "Close the chat with " .. cv.name,
		    act = "chatclose" })
   end
   if ch.state == 3 or ch.state == 1 or ch.state == 2 then
      tinsert(it, { name = "Leave IRC", act = "chatquit" })
   end
   if cf.token ~= "" then
      tinsert(it, { name = "Sign out of KosNet", act = "chatkout" })
   end
end

function rchat_menu_hues(r, it)
   local cf = r.chat.cfg
   tinsert(it, { name = "from the name", act = "chathue", arg = -1,
		 on = (cf.hue < 0) })
   local i
   for i = 1, getn(rchat_hues) do
      tinsert(it, { name = rchat_hues[i][1], act = "chathue",
		    arg = rchat_hues[i][2], on = (cf.hue == rchat_hues[i][2]) })
   end
end

-- returns 1 when it was one of ours
function rchat_menu_do(r, item)
   local ch = r.chat
   local act = item.act
   if not ch or not act or strsub(act, 1, 4) ~= "chat" then return end
   if act == "chat" then
      rchat_open(r)
   elseif act == "chathue" then
      local h = item.arg
      if ch.state == 3 and chat_irc_say then
	 -- through the IRC client : everyone hears about it
	 local n = "reset"
	 if h >= 0 then n = format("%d", h) end
	 chat_irc_say(ch.convs[ch.cur].name, "/color " .. n)
	 rchat_take_cfg(ch)
      else
	 rchat_set(ch, "hue", h)
      end
      if ch.me and ch.me ~= "" then
	 if h >= 0 then ch.hues[strlower(ch.me)] = h
	 else ch.hues[strlower(ch.me)] = nil end
      end
   elseif act == "chatts" then
      rchat_set(ch, "ts", mod(ch.cfg.ts + 1, 3))
   elseif act == "chatsys" then
      rchat_set(ch, "sys", 1 - ch.cfg.sys)
   elseif act == "chatclose" then
      if ch.cur > 1 then
	 tremove(ch.convs, ch.cur)
	 ch.cur = 1
      end
   elseif act == "chatquit" then
      if chat_irc_stop then chat_irc_stop() end
      ch.tried = 1
      ch.focus = 1
      rchat_state(r)
   elseif act == "chatkout" then
      ch.cfg.token, ch.cfg.kname = "", ""
      rchat_save(ch)
      ch.knote, ch.kbad = "Signed out of KosNet.", nil
   end
   return 1
end

rchat_help_text = {
   { "CHAT" },
   { "X", "Switch between IRC #dc99 and KosNet global chat" },
   { "A", "Write a message (on-screen keyboard), or press a button" },
   { "Y", "IRC : next conversation.  KosNet : read again" },
   { "D-pad", "Scroll up and down.  Left and right : conversations" },
   { "B", "Back to the player : the chat stays connected" },
   { "START", "Name colour, times, joins, leave IRC, sign out" },
   { "KEYBOARD" },
   { "Enter", "Send.  Esc goes back.  Tab : next conversation" },
   { "F4 F5", "F4 opens or closes the chat.  F5 : IRC or KosNet" },
   { "PgUp PgDn", "Scroll a page" },
   { "IRC" },
   { "/me /msg", "/me waves   /msg nick hello   /help for all" },
   { "/color", "red orange yellow green teal cyan blue purple pink rose" },
   { "Mouse", "Click a name to mention it.  The wheel scrolls" },
}
