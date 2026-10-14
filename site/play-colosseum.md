# Colosseum

A first-person walk through the Colosseum in Rome. Start in the street to the
west, pass under the numbered arches, and take the west passage under the
seats into the arena. Go down the ramp into the hypogeum, climb the stairs to
the upper ambulatory and the top terrace, and find the eight tesserae, the
bone tokens that marked a seat. Then take the emperor's box on the south side
of the podium. The faster you finish, the higher your score.

Controls:

- Up / Down or W / S: move; Left / Right: turn
- A / D: strafe
- Space: jump
- `Q` / `E` or Page Up / Page Down: look up and down
- Mouse: click the game to capture the pointer, then move the mouse to turn
  and look up and down; Escape releases it
- `M`: show the map of the level you stand on
- `G`: turn into a gull and back. A gull glides forward all the time and
  sinks slowly; hold Up / W or Space to flap and climb, and Down / S to dive.
  Left / Right and A / D turn. A gull can't pick up tesserae, and turning
  back into yourself in mid-air drops you to the ground.
- `B`: swap between the sector renderer and the 3D BSP renderer
- `P` / Escape: pause; `R`: restart

What to watch for:

- Gulls wheel high over the bowl, then come down to the seats, the parapet of
  the top terrace, the arena, the hypogeum's wall tops, and the street. They
  take off when you come close.
- The hypogeum is a grid of corridors under the arena. West of the deck it is
  open to the sky, and you can walk along the tops of its walls or drop into
  it. East of the deck's edge the corridors run on in the dark to a corridor
  that joins them all, and a low passage through the middle cross wall runs
  north to south. Either way leads back to the ramp.
- The outer wall is 2.5 m thick, so each arch is a short vaulted passage. You
  can jump onto the parapet at the top and walk along the wall's crown.
- From the top terrace you can see across the whole bowl to the far parapet.
- The sun follows its path over Rome on 21 April from 10:00 to 14:00, so the
  shadows in the hypogeum's corridors creep across their floors.
- Press `B` to change renderer. The picture should not change, only the
  counter at the top left: room visits for the sectors, or polygons drawn for
  the BSP.

<qip-play id="colosseum-play" data-pointer-lock canvas-width="min(100%, 960px)" canvas-height="auto">
  <source src="/gui/colosseum.wasm" type="application/wasm" />
</qip-play>

## How it renders

[Rotunda](/play-rotunda) draws the Pantheon from a 2D BSP, as Doom does. A 2D
BSP gives every point on the plan one floor and one ceiling, so it cannot put
one room above another. The Colosseum needs rooms above other rooms: the
hypogeum under the arena, the upper ambulatory on the lower one, and passages
and stairs under the seats.

The level is 1,114 sectors, as in the Build engine behind Duke Nukem 3D. A
sector is a convex room with its own floor and ceiling planes, or open sky. At
startup each side of a sector is cut wherever a neighbour's side begins or
ends. Each piece is then stacked into spans from floor to ceiling: solid wall,
an opening into another sector, or open sky. Openings can lead into several
sectors stacked above one another. The outer wall, seen from the street, opens
into the passages through the lower and upper arches, and onto the top of the
parapet. Each arch is six sectors between points on its curve, each with a
sloped ceiling plane, so its vault follows the arch through the wall's
thickness. The two sides of every wall must agree, and a test checks every
opening from both sides.

Each screen column follows its ray from the camera's sector. In a sector, the
column draws the floor rows below the far side's foot and the ceiling rows
above its head. Between them it draws the spans of the side the ray leaves
through. An opening becomes a narrower window of rows into the sector behind
it, so each pixel is drawn once and no depth sorting is needed. Floors, slopes
and ceilings are cast per pixel onto their planes. The seating cells lie
between two rings of the same ellipse, so each one is an exact plane and meets
its neighbours without a step.

The same sectors also become 7,027 polygons for a true 3D BSP, built the first
time you press `B`. That renderer walks the tree front to back. It skips
subtrees whose bounding boxes cover only pixels already drawn, and
scan-converts each polygon that faces you. Both renderers call the same
shading for each pixel, and their frames match.

On an Apple M5 in Node.js, before the outer wall was thickened, the sector
renderer took 8.8 to 11.0 ms per frame in six fixed views, and the 3D BSP took
10.2 to 12.1 ms. Run back to back, the thicker wall made no measurable
difference. Without textures,
finding what each pixel shows costs 2.7 to 3.1 ms with sectors and 3.4 to 4.7
ms with the BSP. Sectors win here because every wall is vertical and every
floor is one plane per room. The BSP could also draw sloped walls and real
overhangs, but it pays for that on every pixel. To reproduce the measurements,
run `node tools/bench-colosseum-renderers.mjs`.

Collision uses the same sectors. You can pass through an opening if it starts
no more than a step above your feet and leaves head room. Otherwise its side
blocks you, which is how the podium's parapet, the balustrades beside the
stairwells, and the piers between the arches stop you. Stairs are runs of
small sectors, each half a metre higher than the last.

As a gull you collide the same way, with a smaller body that can rise over
a ledge but not climb steps. A test lets a gull wander for 40 seconds and
checks that it never leaves the air of its sector. Another test follows every
way a walker can step, jump, or fall from room to room, and checks that every
room leads back to the street.

Each gull's flight is a series of straight legs and circles. A gull soars
above the highest wall top and drops to a perch only from the open side, and a
test follows every gull for three minutes to check that none enters a wall.
The component simulates fixed 16 ms steps before the events in each update. A
late update runs at most eight steps. The title, pause, and end screens
request no wakes, and only `render` writes the 640 by 480 KTX2 frame.
