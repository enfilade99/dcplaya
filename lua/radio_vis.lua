--- @file     radio_vis.lua
--- @date     2026/11/16
--- @brief    DC99 visualizers, written in Lua and drawn behind the player
---           screen. They read the music with fft_bands() and fft_pcm()
---           (display plugin).
---
--- To add one : write a function f(v, dl) that draws into dl using
--- v.lv[i] (level of band i, 0..1), v.pk[i] (falling peak), v.loud (0..1),
--- v.t (seconds) and add a line to radio_vis_list.

radio_vis_loaded = nil

rv_sin = sin
rv_cos = cos

-- colour stops for a level : green, yellow, red  (a, r, g, b)
function rv_heat(x, a)
   if x < 0 then x = 0 end
   if x > 1 then x = 1 end
   if x < 0.5 then
      return a, 0.15 + 1.7 * x, 1.0, 0.25 - 0.3 * x
   end
   return a, 1.0, 1.0 - 1.7 * (x - 0.5), 0.10
end

-- rainbow along the bands
function rv_hue(x, a)
   x = x - floor(x)
   local k = x * 6
   local f = k - floor(k)
   if k < 1 then return a, 1, f, 0.1
   elseif k < 2 then return a, 1 - f, 1, 0.1
   elseif k < 3 then return a, 0.1, 1, f
   elseif k < 4 then return a, 0.1, 1 - f, 1
   elseif k < 5 then return a, f, 0.1, 1
   end
   return a, 1, 0.1, 1 - f
end

function rv_box(dl, x, y, w, h, a, r, g, b)
   dl_draw_box1(dl, x, y, x+w, y+h, 0, a, r, g, b)
end

function rv_grad(dl, x, y, w, h, a1, r1, g1, b1, a2, r2, g2, b2)
   dl_draw_box(dl, x, y, x+w, y+h, 0, a1, r1, g1, b1, a2, r2, g2, b2, 2)
end

-- ----------------------------------------------------------------------
-- the visualizers
-- ----------------------------------------------------------------------

function rv_bars_draw(v, dl, peaks)
   local n = v.n
   local w = 560 / n
   local i
   for i = 1, n do
      local l = v.lv[i]
      local h = 4 + l * 300
      local x = 40 + (i-1) * w
      local a, r, g, b = rv_heat(l, 0.9)
      rv_grad(dl, x, 440 - h, w - 3, h, a, r, g, b, 0.9, 0.1, 0.8, 0.25)
      if peaks then
	 rv_box(dl, x, 436 - v.pk[i] * 300 - 4, w - 3, 3, 0.9, 1, 1, 1)
      end
   end
end

function rv_bars(v, dl) rv_bars_draw(v, dl) end
function rv_bars_peaks(v, dl) rv_bars_draw(v, dl, 1) end

function rv_mirror(v, dl)
   local n = v.n
   local w = 560 / n
   local i
   for i = 1, n do
      local l = v.lv[i]
      local h = 2 + l * 170
      local x = 40 + (i-1) * w
      local a, r, g, b = rv_hue(i / n * 0.8, 0.9)
      rv_grad(dl, x, 240 - h, w - 3, h, 0.25, r, g, b, a, r, g, b)
      rv_grad(dl, x, 240, w - 3, h, a, r, g, b, 0.25, r, g, b)
   end
end

function rv_led(v, dl)
   local n = v.n
   local w = 560 / n
   local seg = 12
   local i, s
   for i = 1, n do
      local lit = floor(v.lv[i] * seg + 0.5)
      local x = 40 + (i-1) * w
      for s = 1, lit do
	 local y = 440 - s * 26
	 if s > 10 then
	    rv_box(dl, x, y, w - 4, 22, 0.95, 1, 0.15, 0.1)
	 elseif s > 7 then
	    rv_box(dl, x, y, w - 4, 22, 0.95, 1, 0.9, 0.1)
	 else
	    rv_box(dl, x, y, w - 4, 22, 0.95, 0.2, 0.95, 0.3)
	 end
      end
      local p = floor(v.pk[i] * seg + 0.5)
      if p > lit and p > 0 then
	 rv_box(dl, x, 440 - p * 26, w - 4, 22, 0.5, 1, 1, 1)
      end
   end
end

function rv_center(v, dl)
   local n = v.n
   local w = 300 / n
   local i
   for i = 1, n do
      local l = v.lv[i]
      local h = 4 + l * 300
      local a, r, g, b = rv_hue(0.55 + i / n * 0.45, 0.9)
      local d = (i-1) * w
      rv_grad(dl, 320 + d, 440 - h, w - 2, h, a, r, g, b, 0.3, r, g, b)
      rv_grad(dl, 320 - d - w, 440 - h, w - 2, h, a, r, g, b, 0.3, r, g, b)
   end
end

function rv_scope(v, dl)
   local s = v.pcm
   if not s then return end
   local n = getn(s)
   local w = 640 / n
   local i
   rv_box(dl, 0, 239, 640, 2, 0.35, 0.2, 1, 0.4)
   for i = 1, n do
      local y = 240 + s[i] * 190
      rv_box(dl, (i-1) * w, y - 6, w, 12, 0.25, 0.2, 1, 0.4)
      rv_box(dl, (i-1) * w, y - 2, w, 4, 1, 0.6, 1, 0.7)
   end
end

function rv_wave(v, dl)
   local s = v.pcm
   if not s then return end
   local n = getn(s)
   local w = 640 / n
   local i
   for i = 1, n do
      local h = s[i] * 200
      local a, r, g, b = rv_hue(0.5 + abs(s[i]) * 0.5, 0.85)
      if h >= 0 then
	 rv_box(dl, (i-1) * w, 240, w - 1, h + 2, a, r, g, b)
      else
	 rv_box(dl, (i-1) * w, 240 + h, w - 1, 2 - h, a, r, g, b)
      end
   end
end

function rv_meter(dl, y, label_r, l, p)
   local seg = 30
   local lit = floor(l * seg + 0.5)
   local s
   rv_box(dl, 60, y - 6, 520, 62, 0.45, 0, 0, 0)
   for s = 1, seg do
      local x = 66 + (s-1) * 17
      if s <= lit then
	 local a, r, g, b = rv_heat((s-1) / (seg-1), 0.95)
	 rv_box(dl, x, y, 13, 50, a, r, g, b)
      else
	 rv_box(dl, x, y, 13, 50, 0.35, 0.2, 0.2, 0.2)
      end
   end
   local px = 66 + floor(p * (seg-1)) * 17
   rv_box(dl, px, y - 3, 13, 56, 0.9, 1, 1, 1)
end

function rv_vu(v, dl)
   local n = v.n
   local lo, hi = 0, 0
   local i
   local half = floor(n / 2)
   for i = 1, half do lo = lo + v.lv[i] end
   for i = half + 1, n do hi = hi + v.lv[i] end
   lo = lo / half
   hi = hi / (n - half)
   v.vu1 = max(lo, (v.vu1 or 0) - 0.01)
   v.vu2 = max(hi, (v.vu2 or 0) - 0.01)
   rv_meter(dl, 190, 1, lo, v.vu1)
   rv_meter(dl, 270, 1, hi, v.vu2)
end

function rv_orbit(v, dl)
   local n = v.n
   local i
   local spin = v.t * 20
   for i = 1, n do
      local l = v.lv[i]
      local ang = spin + (i-1) * 360 / n
      local rad = 90 + l * 150
      local x = 320 + rv_cos(ang) * rad * 1.2
      local y = 240 + rv_sin(ang) * rad
      local sz = 6 + l * 26
      local a, r, g, b = rv_hue(i / n, 0.9)
      rv_box(dl, x - sz/2, y - sz/2, sz, sz, a, r, g, b)
      -- a dimmer one half way, like a tail
      x = 320 + rv_cos(ang) * rad * 0.6
      y = 240 + rv_sin(ang) * rad * 0.5
      rv_box(dl, x - sz/4, y - sz/4, sz/2, sz/2, 0.45, r, g, b)
   end
end

function rv_ring(dl, hw, hh, t, a, r, g, b)
   rv_box(dl, 320 - hw, 240 - hh, hw * 2, t, a, r, g, b)
   rv_box(dl, 320 - hw, 240 + hh - t, hw * 2, t, a, r, g, b)
   rv_box(dl, 320 - hw, 240 - hh, t, hh * 2, a, r, g, b)
   rv_box(dl, 320 + hw - t, 240 - hh, t, hh * 2, a, r, g, b)
end

function rv_rings(v, dl)
   local n = v.n
   local i
   for i = 1, n do
      local l = v.lv[i]
      local hw = 30 + (i-1) * 34 + l * 40
      local a, r, g, b = rv_hue(i / n * 0.7 + v.t * 0.05, 0.25 + l * 0.7)
      rv_ring(dl, hw, hw * 0.72, 3 + l * 10, a, r, g, b)
   end
end

function rv_skyline(v, dl)
   local n = v.n
   local rows = 6
   local i, k
   -- remember the last pictures of the levels
   v.hist = v.hist or { n = 0 }
   v.hacc = (v.hacc or 0) + 1
   if v.hacc >= 3 then
      v.hacc = 0
      local row = {}
      for i = 1, n do row[i] = v.lv[i] end
      tinsert(v.hist, 1, row)
      if getn(v.hist) > rows then tremove(v.hist) end
   end
   for k = getn(v.hist), 1, -1 do
      local row = v.hist[k]
      local sc = 1 - (k-1) * 0.11
      local w = 520 * sc / n
      local x0 = 320 - 260 * sc
      local base = 430 - (k-1) * 44
      for i = 1, n do
	 local h = 3 + row[i] * 150 * sc
	 local a, r, g, b = rv_hue(0.35 + (k-1) * 0.07, 1 - (k-1) * 0.14)
	 rv_grad(dl, x0 + (i-1) * w, base - h, w - 2, h,
		 a, r, g, b, a * 0.4, r * 0.4, g * 0.4, b * 0.4)
      end
   end
end

function rv_stars(v, dl)
   local count = 44
   local i
   if not v.stars then
      v.stars = {}
      for i = 1, count do
	 v.stars[i] = { ang = random() * 360, d = random() * 300,
	    sp = 0.5 + random() }
      end
   end
   local push = 1.5 + v.loud * 14
   for i = 1, count do
      local s = v.stars[i]
      s.d = s.d + s.sp * push
      if s.d > 420 then
	 s.d = 8 + random() * 30
	 s.ang = random() * 360
      end
      local x = 320 + rv_cos(s.ang) * s.d
      local y = 240 + rv_sin(s.ang) * s.d * 0.75
      local sz = 2 + s.d / 60
      local br = 0.35 + s.d / 500
      if br > 1 then br = 1 end
      rv_box(dl, x, y, sz, sz, br, 1, 1, 1)
   end
   -- the middle beats with the low notes
   local c = 14 + v.lv[1] * 60
   rv_box(dl, 320 - c/2, 240 - c/2, c, c, 0.5, 0.6, 0.8, 1)
end

function rv_tiles(v, dl)
   local n = v.n
   local rows = 6
   local w = 640 / n
   local h = 480 / rows
   local i, k
   for i = 1, n do
      local l = v.lv[i]
      for k = 1, rows do
	 local need = (k - 0.5) / rows
	 local al = (l - need) * 3 + 0.35
	 if al > 0.06 then
	    if al > 0.9 then al = 0.9 end
	    local a, r, g, b = rv_hue(0.6 - k * 0.09 + v.t * 0.03, al)
	    rv_box(dl, (i-1) * w + 2, 480 - k * h + 2, w - 4, h - 4,
		   a, r, g, b)
	 end
      end
   end
end

function rv_dots(v, dl)
   local n = v.n
   local w = 560 / n
   local i
   for i = 1, n do
      local x = 40 + (i-1) * w + w / 2
      local y = 430 - v.lv[i] * 320
      local yp = 430 - v.pk[i] * 320
      local a, r, g, b = rv_hue(i / n * 0.8, 1)
      rv_box(dl, x - 2, y, 4, 430 - y, 0.25, r, g, b)
      rv_box(dl, x - 7, y - 7, 14, 14, 1, r, g, b)
      rv_box(dl, x - 4, yp - 4, 8, 8, 0.6, 1, 1, 1)
   end
end

function rv_edges(v, dl)
   local n = v.n
   local w = 640 / n
   local i
   for i = 1, n do
      local h = 3 + v.lv[i] * 110
      local a, r, g, b = rv_hue(0.5 + i / n * 0.3, 0.85)
      rv_grad(dl, (i-1) * w, 0, w - 2, h, a, r, g, b, 0.1, r, g, b)
      rv_grad(dl, 640 - i * w, 480 - h, w - 2, h, 0.1, r, g, b, a, r, g, b)
   end
end

function rv_blocks(v, dl)
   -- three big blocks : low, middle and high notes
   local n = v.n
   local third = floor(n / 3)
   local k, i
   for k = 0, 2 do
      local s = 0
      for i = 1, third do s = s + v.lv[k * third + i] end
      s = s / third
      local sz = 60 + s * 150
      local cx = 140 + k * 180
      local a, r, g, b = rv_hue(0.02 + k * 0.3, 0.3 + s * 0.6)
      rv_box(dl, cx - sz/2, 240 - sz/2, sz, sz, a, r, g, b)
      rv_box(dl, cx - sz/4, 240 - sz/4, sz/2, sz/2, 0.9, r, g, b)
   end
end

radio_vis_list = {
   { name = "Bars",            fn = rv_bars,       n = 24 },
   { name = "Bars and peaks",  fn = rv_bars_peaks, n = 24 },
   { name = "Hi-fi lights",    fn = rv_led,        n = 16 },
   { name = "Mirror",          fn = rv_mirror,     n = 28 },
   { name = "From the middle", fn = rv_center,     n = 20 },
   { name = "Scope",           fn = rv_scope,      n = 8, pcm = 64 },
   { name = "Wave",            fn = rv_wave,       n = 8, pcm = 80 },
   { name = "Meters",          fn = rv_vu,         n = 16 },
   { name = "Orbit",           fn = rv_orbit,      n = 24 },
   { name = "Rings",           fn = rv_rings,      n = 7 },
   { name = "Skyline",         fn = rv_skyline,    n = 16 },
   { name = "Stars",           fn = rv_stars,      n = 8 },
   { name = "Tiles",           fn = rv_tiles,      n = 12 },
   { name = "Dots",            fn = rv_dots,       n = 24 },
   { name = "Edges",           fn = rv_edges,      n = 32 },
   { name = "Blocks",          fn = rv_blocks,     n = 12 };
   n = 16
}

-- ----------------------------------------------------------------------
-- engine
-- ----------------------------------------------------------------------

function radio_vis_create(z)
   local v = {
      front = dl_new_list(24576, 0),
      back = dl_new_list(24576, 0),
      lv = {}, pk = {}, t = 0, loud = 0, top = 1, frame = 0,
   }
   dl_set_trans(v.front, mat_trans(0, 0, z))
   dl_set_trans(v.back, mat_trans(0, 0, z))
   return v
end

-- k : index in radio_vis_list, nil to stop
function radio_vis_set(v, k)
   local def = k and radio_vis_list[k]
   v.def = def
   v.stars, v.hist = nil, nil
   if not def then
      dl_set_active2(v.front, v.back, 0)
      return
   end
   v.n = def.n
   local i
   for i = 1, def.n do
      v.lv[i] = 0
      v.pk[i] = 0
   end
end

function radio_vis_hide(v)
   dl_set_active2(v.front, v.back, 0)
end

function radio_vis_update(v, frametime)
   local def = v.def
   if not def or not fft_bands then return end
   v.t = v.t + frametime
   -- every other frame is plenty, and leaves time for the music
   v.frame = v.frame + 1
   if mod(v.frame, 2) == 1 then return end
   local dt = frametime * 2

   local raw, loud = fft_bands(def.n)
   if type(raw) ~= "table" then return end
   local n = def.n
   local i
   local mx = 0
   for i = 1, n do
      if raw[i] > mx then mx = raw[i] end
   end
   -- the scale follows the loudest thing heard lately
   v.top = v.top * (1 - 0.15 * dt)
   if mx > v.top then v.top = mx end
   if v.top < 400 then v.top = 400 end
   local sum = 0
   for i = 1, n do
      local l = sqrt(raw[i] / v.top)
      if l > 1 then l = 1 end
      local old = v.lv[i] - 1.6 * dt
      if l < old then l = old end
      if l < 0 then l = 0 end
      v.lv[i] = l
      local p = v.pk[i] - 0.35 * dt
      if l > p then p = l end
      v.pk[i] = p
      sum = sum + l
   end
   v.loud = sum / n
   if def.pcm and fft_pcm then
      v.pcm = fft_pcm(def.pcm)
   end

   dl_clear(v.back)
   def.fn(v, v.back)
   dl_set_active2(v.back, v.front, 1)
   v.back, v.front = v.front, v.back
end

radio_vis_loaded = 1
return radio_vis_loaded
