# Highway Chase

Drive a vertically scrolling highway in the style of Spy Hunter. Shoot or ram
enemy cars off the road, leave the civilians alone, and keep going for as long
as your cars last.

Controls:

- Up / W: accelerate; Down / S: brake
- Left / Right or A / D: steer
- Space / `Z`: fire forward guns
- `X` / `C`: drop an oil slick behind you
- `P` / Escape: pause; `R`: restart

What to watch for:

- Black cars with yellow spikes come from behind and shove you sideways.
- Green cars with turrets weave in front of you to block the lane.
- Hitting a civilian stops your score for five seconds.
- The shoulder slows you down. Trees, the median, and water wreck your car.
- Crashes cost nothing while the "free cars" bar lasts. After that, you get an
  extra car every 10,000 points.

The road is generated as you drive, with curves, forks around a median, and
narrow bridges. Each game seeds a new road from the time you press Space.

<qip-play>
  <source src="/gui/highway-chase.wasm" type="application/wasm" />
</qip-play>

The component simulates fixed 16 ms steps before the events in each update. A
late update runs at most eight steps and then drops the rest of the backlog.
The title, pause, and game-over screens request no wakes. Only `render` writes
the 320 by 480 KTX2 frame.
