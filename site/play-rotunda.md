# Rotunda

A first-person walk through the Pantheon in Rome. Start in the Piazza della
Rotonda among the pigeons, climb the cordonata ramp to the portico's raised
terrace, pass between its granite columns, and take the seven planetary sigils
from the rotunda's niches. One sigil waits on the raised floor of the apse, at
the top of a ramp. With all seven, stand in the sunbeam that falls through the
oculus. The faster you finish, the higher your score.

Controls:

- Up / Down or W / S: move; Left / Right: turn
- A / D: strafe
- Space: jump
- `Q` / `E` or Page Up / Page Down: look up and down
- Mouse: click the game to capture the pointer, then move the mouse to turn
  and look up and down; Escape releases it
- `M`: cycle the map and the BSP draw-order view
- `T`: start or stop the rain
- `P` / Escape: pause; `R`: restart

What to watch for:

- Pigeons peck about the piazza and the rotunda floor, and take off when you
  come close. Most of those inside spiral up and leave through the oculus.
  Some from the piazza fly back in the same way.
- Swifts circle under the dome, dart out through the oculus, wheel over the
  building, and come back in.
- Look up from across the rotunda to see the oculus and the sky, and watch for
  bird shadows crossing the patch of sunlight on the floor.
- The terrace's edge and the apse ledge are too high to step up, but you can
  jump onto them or drop off them.
- The sun follows its real path over Rome on 21 April, the city's birthday,
  from 10:00 to 14:00, one hour every two and a half minutes. It climbs from
  about 50 degrees to 60 at noon, due south, and sinks again, so the sunbeam
  sweeps across the north side of the floor, from the north-west niches, in
  toward the middle at noon, and out to the north-east. Look up from inside the beam to see the sun through the oculus,
  or find it over the piazza. After ten minutes the next morning begins.
- Showers come and go. Inside, the rain falls only in a misty column under
  the oculus and wets the floor beneath it. The Pantheon's floor has 22 small
  drain holes there, and after a shower they take the water away, so the wet
  patch shrinks back to them. Stand in the puddle and look down to see the
  oculus reflected in it. The sun still shows through the cloud, more faintly.

<qip-play id="rotunda-play" data-pointer-lock canvas-width="min(100%, 960px)" canvas-height="auto">
  <source src="/gui/rotunda.wasm" type="application/wasm" />
</qip-play>

## How it renders

The level is a flat plan of wall segments: the rotunda drum with its seven
niches, the entrance, the portico, the piazza facades, and 28 columns and the
obelisk as small polygons. At startup the component compiles them into a binary
space partition (BSP). Each node splits the plan along one wall's line and
stores the walls on that line, and walls crossing a splitter are cut in two.

Each frame walks the tree front to back from the eye. At a node, the subtree on
the eye's side is drawn first, then the walls on the splitter, then the far
subtree. Each screen column keeps the first wall to reach it, so no depth sort
is needed, and the walk stops once all 640 columns are filled. Press `M` twice
to see that order on the map: bright walls were reached first, and dim walls
faced away or were never needed.

The floors are sectors, as in Doom, each with its own plane, so a floor can be
raised, lowered, or sloped. The piazza sits 1.5 m below the terrace, the
cordonata slopes between them, and the apse floor is 0.9 m up its own ramp.
Two-sided step lines (orange on the map) mark where sectors meet. They go into
the same BSP as the walls but never claim a column. Instead, each column
records the step lines it crosses on the way to its wall. Drawing the column
from the bottom up, each crossing ends the floor in front of it and, where the
far floor is higher, adds a step face. Anything hidden below what is already
drawn is skipped.

Floors, ramps, the coffered dome, the oculus, and the sky are cast per pixel
from each column's ray, intersecting it with the plane of the sector it is
crossing. Looking up or down shears the view, as in Heretic and Duke Nukem
3D: the horizon row moves and walls stay upright. One sun direction, worked
out each frame from the hour angle, the date's declination, and Rome's
latitude, lights everything: the disc and its glare in the sky, the sunlit
faces on the piazza, and the beam. A point is in the beam when its line to the
sun passes through the oculus. The glowing dust is how far each view ray
travels through that slanted column before it hits something, so the shaft
shows from the side and still looks right from inside it. Points in the beam
check whether a bird sits on their line to the sun, which gives the birds
their shadows.

Each pixel also records its depth, so the birds and sigils are drawn behind
nearer walls, floors, step faces, ceilings and the dome. A bird above the
building shows through the oculus or above the piazza's rooftops and nowhere
else. The same tree answers the game's other geometry questions: line of sight
and collision. Step lines are ignored there, and the floor height decides
instead whether a move is a step up, a ramp, or a drop. A jump
raises the player's feet, and with them the height they can step onto. Pigeons walk with the
same collision as the player. Every flight is a series of straight legs and
arcs planned to stay above the walls or inside the rotunda, and a test follows
every bird for three minutes to check that none crosses a wall or roof except
through the oculus.

Rain is a few hundred drops falling at about 9 m/s: one set in the column
under the oculus, and one over the open piazza within 15 m of the player.
The view is sheared rather than tilted, so verticals stay upright and each
drop is a short run of rows in one screen column. Like the birds, each drop
is checked against the depth of every pixel it covers, so it shows in front
of the dome and walls but not through them. Drops landing near the player
splash. The column's mist is worked out like the sunbeam's glow, from how
much of the column each view ray crosses before it hits something. A single
water level stands for the puddle: rain raises it, and the drains take away
a share of it every step.

The component simulates fixed 16 ms steps before the events in each update. A
late update runs at most eight steps and then drops the rest of the backlog.
The title, pause, and end screens request no wakes. Only `render` writes the
640 by 480 KTX2 frame.
