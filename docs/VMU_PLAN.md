# VMU plan

Everything DCPlaya will draw on the VMU (48 x 32 pixels, on or off).
Animated mock-ups: [round 1](vmu/DCPlaya_VMU_mockups.gif),
[round 2](vmu/DCPlaya_VMU_mockups2.gif), [round 3](vmu/DCPlaya_VMU_mockups3.gif),
[round 4](vmu/DCPlaya_VMU_mockups4.gif).

Built after the move to mainline KallistiOS: the VMU drawing lives in the
main program, and mainline KOS has the VMU beep and the rumble pack.

## Visualizers (react to the music)

Spectrum + title, wave, VU meters, starfield, dancing buddy, 360 burst,
360 dot rings, beat tunnel, plasma, 3D cube, digital rain, fire,
mirror spectrum, waterfall, vector scope, pong, life, ripples, 3D maze run,
demo sine scroller, metaballs, rotozoom, surf the bars, night city,
synthwave road, beat fireworks, dot globe, voxel flyover, fractal zoom,
ridge lines, hypno spiral, mascot (Playa-Bot, placeholder for a real mascot).

## Screens

- Info: weather icon, temperature, time, date
- Standby clock after a few idle minutes (big digits, drifting pixel)
- Live weather scene (snow, rain, sun... from the weather app)
- Karaoke line for songs that have lyrics
- Chat on the VMU (IRC / KosNet) while the TV shows the visualizer
- Start-up splash

## Play

- Auto runner mini-game (jumps by itself to the beat, or play it)
- Block stacker (plays itself)

## Alerts (each can be turned off)

- Friend comes online: VMU beep + flash + name, same moment as the pop-up
- Chat mention: double beep + quick rumble + the message

## Behaviour

- Choose what scrolls: title, artist, station, time, weather, who's online
- Song-change flip animation
- Auto-switch visualizers on a big drop or every few songs (pixel dissolve)
- Two VMUs, one picture: controllers 1 and 2 together make a 96 x 32 screen
