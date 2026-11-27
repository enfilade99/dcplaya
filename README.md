# DCPlaya, revived

DCPlaya is the free Dreamcast music player by Benjamin Gerard (ben) and
Vincent Penne (vincentp), first released in 2002. This fork brings it back
to life on real hardware and adds new features. The original readme is in
[`README`](README).

## What's new

- **Builds with a current compiler** (sh-elf GCC 13).
- **Internet radio** with a station list, favourites and recently played.
- **Home dashboard**: what's playing over the visualizer, an app bar,
  slide-out panels on L (your music) and R (who's online), notifications.
- **Chat**: IRC and KosNet global chat, with an on-screen keyboard.
- **Weather**: current conditions and five days for any city (Open-Meteo).
- **Seven new 3D visualizers.**
- **Network**: connects by itself at start-up (the console's saved
  settings or DHCP) and shows up on Dreamcast Now.
- **Video fixes** for the built-in MPEG player.

## Status

Tested on a real Dreamcast with a Broadband Adapter.

It still builds against DCPlaya's own KallistiOS 1.3 fork,
[zig/kos-dcplaya](https://github.com/zig/kos-dcplaya), with the
patches in [`kos-patches/`](kos-patches). **Porting to mainline KallistiOS
is the next big step, and help is very welcome.** The chat, dashboard
and weather code in `plugins/exe/net/chat.c` uses the fork's old lwIP
sockets, so that part will need attention in the port.

## Building (current, KOS 1.3 fork)

1. Get the sh-elf GCC 13 toolchain (for example from the
   `ghcr.io/kos-builds/kos-dc:latest` image), plus `autoconf`,
   `gcc-arm-none-eabi`, `binutils-arm-none-eabi` and `netpbm`.
2. Check out side by side:
   - this repository
   - [enfilade99/kos-dcplaya](https://github.com/enfilade99/kos-dcplaya)
     (DCPlaya's KOS fork with our fixes already in; the same fixes are in
     `kos-patches/` for use on top of
     [zig/kos-dcplaya](https://github.com/zig/kos-dcplaya) `1008d9f`)
3. Build the KOS fork: `make` in `kos-dcplaya` with its environment set.
4. Build DCPlaya:

   ```
   autoconf
   ./configure --with-kos=../kos-dcplaya --with-sh-prefix=sh-elf- \
     --with-sh-path=/opt/toolchains/dc/sh-elf/bin \
     --with-arm-prefix=arm-none-eabi- --enable-release
   make
   sh-elf-objcopy -R .stack -S -O binary dcplaya.elf dcplaya.bin
   ```

The new screens are Lua 4 scripts in `lua/` (`radio.lua`, `radio_chat.lua`,
`radio_dash.lua`, `radio_wx.lua`, `radio_vis.lua`). On the disc they go in
`DCPLAYA/LUA/` with upper-case names. `dist/userconf.lua` is the
start-up file that loads them (`DCPLAYA/USERCONF.LUA` on the disc).

## Notes for developers

- The plugin loader (`lef.c`) writes two zero words past the end of the
  symbol table it copies. The net plugin carries a pad symbol to absorb
  this. Keep it, or fix the loader.
- Lua is version 4.0: no `(expr)[i]`, use `tinsert`/`getn`, `strfind`, etc.

## Credits

DCPlaya: Benjamin Gerard and Vincent Penne. Revival: enfilade.
