--- @ingroup dcplaya_lua_net
--- @file    net.lua
--- @brief   network set-up
---
--- DCPlaya connects by itself when it starts. It uses, in this order :
---  -# manual settings saved from DCPlaya's own network dialog (VMU),
---  -# settings handed over by the DC99 DreamHub menu (/rd/dc99net.lua),
---  -# the network settings saved in the console (the ones a browser or a
---     BBA set-up disc stores) when they are static,
---  -# an address from the router (DHCP).
---

net_cfg_filename = "/ram/dcplaya/configs/net.cfg"
plug_dhcp = plug_dhcp or (home.."plugins/exe/dhcp/dhcp.lez")

-- Manual settings saved on the VMU, if any.
net_cfg = nil
if test("-f", net_cfg_filename) then
   dofile(net_cfg_filename)
end
net_manual = nil
if type(net_cfg) == "table" and net_cfg.ip and not net_cfg.dhcp then
   net_manual = net_cfg
end
net_cfg = nil

-- Settings handed over by the DC99 DreamHub menu, if any.
dc99net = nil
if test("-f", "/rd/dc99net.lua") then
   dofile("/rd/dc99net.lua")
end

net_connected = nil	-- set once the network is up
net_how = nil		-- where the settings in use came from
net_error = nil		-- why the last attempt failed

function net_save_settings()
   if gui_yesno("Do you want to save your settings on the VMU ?",
		nil, "Network settings", "Save", "Cancel") == 1 then
      if net_manual then
	 local file = openfile(net_cfg_filename, "w")
	 if file then
	    write(file, "net_cfg = \n"..type_dump(net_manual))
	    closefile(file)
	 end
      else
	 rm(net_cfg_filename)
      end
      if vmu_save then
	 vmu_save(nil, 1)
      end
   end
end

-- Wait for the next screen refresh.
function net_wait_frame()
   local f = evt_origframecounter or framecounter
   f(1)
end

function net_isip(s)
   return type(s) == "string" and s ~= "" and s ~= "0.0.0.0"
end

-- Fill the gaps of a settings table. Returns nil if there is no address.
function net_complete(cfg)
   if not cfg or not net_isip(cfg.ip) then
      return nil
   end
   if not net_isip(cfg.mask) then cfg.mask = "255.255.255.0" end
   if not net_isip(cfg.gw) then cfg.gw = cfg.ip end
   if not net_isip(cfg.dns) then cfg.dns = cfg.gw end
   return cfg
end

-- The network settings saved in the console : method, settings.
-- method is 0 dial-up, 1 DHCP, 2 PPPoE, 3 static, or nil if nothing is saved.
function net_console_settings()
   if not net_flashcfg then
      return nil
   end
   local method, ip, mask, gw, dns1, dns2 = net_flashcfg()
   if not method then
      return nil
   end
   if not net_isip(dns1) then dns1 = dns2 end
   return method, net_complete({ ip = ip, mask = mask, gw = gw, dns = dns1 })
end

-- Ask the router for an address. Returns a settings table or nil.
-- patience : how many times to ask before giving up (2 seconds each).
function net_dhcp(patience)
   if not dhcp_discover then
      driver_load(plug_dhcp)
   end
   if not dhcp_discover then
      net_error = "The DHCP plugin could not be loaded."
      return nil
   end
   if dhcp_driver_init then
      dhcp_driver_init()
   end
   if net_connect("0.0.0.0") then
      net_error = "No network adapter answered."
      return nil
   end

   local valid, ip, lease, mask, gw, domain, dns
   local offered = nil
   local tries = 1
   local frames = 0
   dhcp_discover()
   while 1 do
      valid, ip, lease, mask, gw, domain, dns = dhcp_conf()
      if valid == 5 then
	 break
      end
      if valid == 2 and not offered then
	 offered = 1
	 frames = 0
	 dhcp_request()
      end
      net_wait_frame()
      frames = frames + 1
      if frames >= 120 then
	 if tries >= patience then
	    break
	 end
	 tries = tries + 1
	 frames = 0
	 if offered then
	    dhcp_request()
	 else
	    dhcp_discover()
	 end
      end
   end
   if dhcp_driver_shutdown then
      dhcp_driver_shutdown()
   end
   if valid ~= 5 then
      net_error = "The router did not give an address (DHCP)."
      return nil
   end
   return net_complete({ ip = ip, mask = mask, gw = gw, dns = dns })
end

-- Work out which settings to use. Returns settings, where they came from.
function net_find_settings(quiet)
   if net_manual then
      return net_complete(net_manual), "manual settings"
   end
   if dc99net and dc99net.ip then
      return net_complete({ ip = dc99net.ip, mask = dc99net.mask,
			     gw = dc99net.gw, dns = dc99net.dns }),
	 "DC99 DreamHub"
   end
   local method, saved = net_console_settings()
   if method == 3 and saved then
      return saved, "console settings"
   end
   local cfg = net_dhcp((quiet and 4) or 6)
   if cfg then
      return cfg, "DHCP"
   end
   if saved then
      -- no answer from a router : the saved address is better than nothing
      return saved, "console settings"
   end
   return nil
end

-- quiet : connect at start-up, without any pop-up.
function net_autoconnect(quiet)
   net_error = nil
   if not net_connect then
      dl(plug_net)
   end
   if not net_connect then
      net_error = "Could not load the network driver."
      if not quiet then gui_ask(net_error, {"OK"}) end
      return
   end

   if quiet and not net_manual and not (dc99net and dc99net.ip) then
      -- at start-up only look for a network when a Broadband Adapter is
      -- really there (other adapters : use the network dialog).
      if not net_has_bba or not net_has_bba() then
	 return
      end
   end

   if not quiet then sc() end
   local scroll = gui_scrolltext and
      gui_scrolltext(nil, "Connecting to the network ...")

   local ok = nil
   local cfg, how = net_find_settings(quiet)
   if cfg then
      if net_connect(cfg.ip) then
	 net_error = "No network adapter answered."
      elseif net_lwip_init(cfg.ip, cfg.mask, cfg.gw) then
	 net_error = "The network adapter started, but the network set-up failed."
      else
	 net_resolv(cfg.dns)
	 net_cfg = cfg
	 net_how = how
	 net_connected = 1
	 net_error = nil
	 ok = 1
      end
   elseif not net_error then
      net_error = "No network settings were found."
   end

   if not quiet then hc() end
   if scroll then dl_set_active(scroll, nil) end

   if not quiet then
      local text
      if ok then
	 text = '<left>Connected ! ('..how..')<br><vspace h="8">IP address : '..cfg.ip..'<br>Netmask : '..cfg.mask..'<br>Gateway : '..cfg.gw..'<br>DNS : '..cfg.dns..'<br><vspace h="8">Internet radio is ready to play.<br><center>'
      else
	 text = '<left>Not connected.<br><vspace h="8">'..net_error..'<br><vspace h="8">Check the network cable, or choose Manual settings.<br><center>'
      end
      gui_ask(text, {"OK"}, 560, "Network")
   end
   return ok
end

-- A dialog with one input per network setting. Returns a settings table.
function net_manual_dialog(def)
   local text = '<dialog guiref="dialog" label="Network settings" name="Network settings">'
   local fields = { { "ip", "IP address :" }, { "mask", "Netmask :" },
		    { "gw", "Gateway :" }, { "dns", "DNS :" } }
   local i
   for i = 1, 4 do
      text = text..'<vspace h="24">'
      text = text..'<button x="left" y="upout" create="gui_new_input" label="'..fields[i][2]..'" name="'..(def[fields[i][1]] or "")..'" total_w="300" guiref="'..fields[i][1]..'"> <hspace w="1"> </button> <br>'
   end
   text = text..[[
<vspace h="16">
<center>
<button guiref="ok">Connect</button>
<hspace w="16">
<button guiref="cancel">Cancel</button>
]]
   text = text.."</dialog>"
   local tt = tt_build(text, {x="center", y="center"})
   tt_draw(tt)
   local dialog = tt.guis.dialog
   dialog.guis.ok.event_table[gui_press_event] =
      function() evt_shutdown_app(%dialog) %dialog.answer = 1 end
   dialog.guis.cancel.event_table[gui_press_event] =
      function() evt_shutdown_app(%dialog) %dialog.answer = 2 end
   dialog.event_table[evt_shutdown_event] =
      function(app) app.answer = 2 end
   while not dialog.answer do
      evt_peek()
   end
   if dialog.answer == 1 then
      return { ip = dialog.guis.ip.input, mask = dialog.guis.mask.input,
	       gw = dialog.guis.gw.input, dns = dialog.guis.dns.input }
   end
   return nil
end

function net_connect_dialog()
   local status = "Not connected."
   if net_connected and net_cfg then
      status = "Connected as "..net_cfg.ip.." ("..(net_how or "?")..")."
   elseif net_error then
      status = "Not connected. "..net_error
   end
   local answer = gui_ask(status..[[

<vspace h="8">
Automatic uses the network settings saved in your console, or asks your router for an address.]],
			  { "Automatic", "Manual settings", "Cancel" },
			  560, "Network settings")
   if answer == 1 then
      local had_manual = net_manual
      net_manual = nil
      net_autoconnect()
      if had_manual then
	 net_save_settings()
      end
   elseif answer == 2 then
      local def = net_manual or net_cfg
      if not def then
	 local method
	 if not net_connect then dl(plug_net) end
	 method, def = net_console_settings()
      end
      def = def or { ip = "192.168.1.99", mask = "255.255.255.0",
		     gw = "192.168.1.1", dns = "192.168.1.1" }
      local cfg = net_manual_dialog(def)
      if cfg then
	 net_manual = cfg
	 net_autoconnect()
	 net_save_settings()
      end
   end
end

net_autoconnect(1)

return 1
