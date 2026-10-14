# HoverCraftsman

It is 1998, and your startup's office is a large orange hovercraft on San
Francisco Bay. The investors at Sand Hill Capital want a live demo at their
pier by five o'clock. Write the demo at the 17 inch CRT in your cubicle,
upload it over the satellite link, then take the helm and stop the office in
the berth beside their pier. A rival startup is pitching to the same
investors, and races you there in a speedboat: if it reaches their pier
first, you lose. The faster you finish, and the less you dent the hull, the
higher your score.

Controls:

- At your desk: type to write code; Enter uploads; Tab stands up
- Walking: Up / Down or W / S move; Left / Right turn; A / D strafe; `E` sits
  at your desk or takes the helm; `M` shows the chart
- At the helm: W / S throttle (down past zero is reverse pitch); A / D or
  Left / Right rudder; `L` lift fans on or off; `T` autopilot; `X` cuts the
  throttle; `R` radar range; `C` chase camera; `M` chart; `E` stands up
- Mouse: click the game to capture the pointer. Walking, it turns you;
  seated, it turns your head. Escape releases it
- Escape or `P`: pause; `R` on the pause screen restarts

<qip-play id="hovercraftsman-play" data-pointer-lock canvas-width="min(100%, 640px)" canvas-height="auto">
  <source src="/gui/hovercraftsman.wasm" type="application/wasm" />
</qip-play>

## Driving a hovercraft

A hovercraft has no tyres. A car's tyres push sideways hard, so it goes
roughly where it points. A hovercraft's skirt barely grips, so the craft keeps
going where its momentum takes it:

- The rudders sit in the propellers' wash. With the throttle closed there is
  little air across them and little steering, so slowing down for a corner
  can leave you sliding toward the obstacle with no way to turn.
- The rudders change the heading first. The craft keeps travelling the old
  way, and only once it has turned does its thrust, now partly sideways,
  bend the course.
- To stop, turn the thrust against the momentum: spin the craft round, or
  pull the throttle into reverse pitch, which blows the wash away from the
  rudders.
- Turn off the lift fans and the skirt settles onto the water, which stops
  the craft, but not at once.
- The islands have sand beaches, and the craft can ride up them, but the
  slope pulls it back and the sand drags on the skirt. With the throttle
  closed it slides back into the water. The rock above the beach is a cliff,
  and running into it dents the hull like any other collision.
- Sandbanks barely break the surface. The skirt rides straight over them,
  slowed only a little by the sand. Reefs are rock just awash, marked by the
  surf breaking over them, and they stop a hovercraft as surely as a boat.

The dial on the dashboard shows the craft from above, nose up, with its
velocity as a blue arrow. When the arrow and the nose disagree, the craft is
sliding, and the number below it is the angle between them. The chase camera
(`C`) swings round after the heading, so you can see the slide from outside
too.

## Wind

The summer sea breeze comes in through the Golden Gate from the
west-north-west. It is light in the morning, fills in from eleven o'clock,
and blows a steady 20 knots from three, gusting a fifth either way and
swinging a few degrees. The sea follows it: calm at nine, with whitecaps
over the open bay by the afternoon.

The skirt barely grips the water, so most of what slows a hovercraft is the
air. The game works out the air's drag from the craft's speed through the
air, not over the water, and the hull's side shows the wind more than twice
the area its bow does:

- Into a 20 knot wind the office tops out at about 12 m/s instead of 20.
  With the wind behind it, it does about 28.
- Hovering with the throttle closed, the fins swing the bow into the wind,
  and the craft drifts backwards at several metres a second. If you leave
  the helm to type, settle the skirt (`L`) or engage the autopilot, or the
  office will blow onto whatever lies downwind.
- In a crosswind the craft crabs, its bow angled upwind of its course. The
  drift number on the dashboard shows by how much. Part of the thrust goes
  into holding the craft against the wind, so it brakes less well, and it
  needs room for its swinging bow and stern.
- The autopilot leans into the wind on every leg. In the last 30 metres it
  turns head to wind, as hovercraft pilots dock, and holds the berth with
  the propellers' pitch, angling a little off the wind to edge across. It
  aims for the upwind side of the berth so the stern clears the pier as it
  turns.

The speedboat planes on the water and shows the air far less of itself for
its weight. In still air the air is about a seventh of the drag its engine
works against at 17 m/s. Into 20 knots of wind it makes about 15 m/s,
and with it behind it makes about 18. It also slides a little sideways,
about a twenty-fifth of the crosswind, which it steers out as it makes for
each buoy. Its channel runs both with and against the wind, so the wind
costs it little, and the office's shortcut costs the office some time. Leave
early, before the breeze fills in.

At speed the skirt throws spray off its sides and bow, and the wake spreads
behind in two arms. The wake stays where it was laid: the game keeps the
stern's last 128 positions, one every 4 metres, and draws foam splats on the
water along that track, so it curves through your turns and fades over 20
seconds. The bay is choppiest out over deep water, where
whitecaps break, and calmer over the shallows off the beaches, sandbanks and
mud flats, where the bottom shows through. Over a reef the water darkens to
weedy rock, and surf breaks along its edges. The speedboat leaves a wake of
its own. Ashore, sheds and warehouses with roller
doors face the water, and oaks, cypresses and scrub grow on the dry grass
behind the seawall.

The autopilot flies the route on the chart, south of the rocks and the
first reef, over the Middle Ground, through the bridge's navigation span,
across the flats and through the gap between the reefs, and along a straight
final approach to the berth. It works out the acceleration it needs and
points the thrust that way, slows early for corners and for the berth, and
keeps some throttle on while it turns so the rudders have air. It leaves you
free to write code, but it is too careful to win the race on its own.
Touching the throttle or rudder at the helm takes the controls back.

The satellite dish on the roof cannot track the satellite while the craft
yaws quickly, or under the bridge, and takes a few seconds to lock on again.
The upload only runs while the link is locked, so a twisting course holds it
up.

## The race

The rival's speedboat waits beside your pier until you leave it, or until
ten o'clock if you haven't. It has to keep to deep water, so it follows the
buoyed channel: north of the rocks, through the bridge's navigation span,
and up the east side of the bay, the long way round the shallows. It cruises
at 17 m/s, a little under your top speed, but it turns and stops far more
sharply, so following it down the channel loses.

Your way is across the shallows. The Middle Ground, between the rocks and
the freighter, cuts the corner before the bridge. North of the bridge, broad
flats lie across the direct line to the berth, with more sandbanks and reefs
the nearer you get, and two reefs leave a gap about 60 metres wide to steer
through. The chart (`M`) shows the flats, the sandbanks in sand colour, the
reefs in red, and the speedboat as a red mark. The status line shows how far
it still has to go.

## The bridge electronics

The office has the best navigation kit money could buy in 1998, and some of
it was only just reaching yachts and small craft that year:

- **Radar:** a colour raster radar, head up, turning at 24 rpm. Echoes are
  green when weak, yellow, and red when strong. The shores, piers and
  freighter are solid and shadow whatever lies behind them. The bridge's
  deck shows as a line, but the beam passes under it. Buoys show through
  their radar reflectors. Reefs break up into speckle, and the low sandbanks
  barely show. Close in there is sea clutter, less over the shallows. `R`
  steps the range through 0.25, 0.5, 0.75 and 1.5 nautical miles. The berth
  shows as a green waypoint from the DGPS.
- **ARPA:** automatic radar plotting. After three sweeps that paint the
  speedboat, it rings it and draws its true course and speed one minute
  ahead. Below the display it gives the closest point of approach and the
  time to it. If a sweep misses the boat, it loses the track.
- **Fluxgate compass:** the dashboard dial's card turns so the bow stays up,
  with north marked. The heading (`HDG`) and course over ground (`COG`) sit
  beside it.
- **DGPS:** in 1998 Selective Availability still blurred civilian GPS to
  about 100 metres. The Coast Guard's beacon corrections bring it down to a
  few metres, so the dashboard gives the position to a thousandth of a
  minute.
- **Chart alarm:** the vector chart watches 30 seconds along the course over
  ground and flashes `REEF` with the distance when it crosses one.
- **Wind instrument:** a masthead vane and anemometer. Corrected for the
  craft's own speed and heading, they give the true wind. Its speed shows in
  knots beside `WIND`, and a vane on the compass card points to where it
  comes from.

The same radar picture and amber readouts also show on the helm console's
screens in the cabin.

## How it renders

[Rotunda](/play-rotunda) uses a 2D BSP, as Doom does, and
[Colosseum](/play-colosseum) uses Build-style sectors alongside a polygon BSP.
HoverCraftsman uses only true 3D BSPs of convex polygons, like the structure
BSP in Halo. It needs two of them, because the office moves.

The craft is 999 polygons, built in its own frame: hull, skirt, cabin walls
with window openings, a windscreen that leans back like the Mercedes C111's,
cubicles, CRTs, and the propeller ducts. The four rudders swing with the helm,
so they stay out of the tree and are drawn just after it, depth tested. The
rival's speedboat moves too, so it is drawn the same way, after the bay. The
bay is 10,292 polygons: water, mud flats, sandbanks, reefs, hills, rocky
islands with beaches, a freighter, the bridge, piers and buoys, and shores
lined with sheds, trees and scrub along a quayside road. Each set gets its own tree when the game starts. Picking each split
from the polygons' own planes alone would cut hundreds of trees along the
shores, so for long lists the builder also tries upright planes across the
bay, which can pass between them. Each frame draws the craft's
tree front to back from the eye moved into the craft's frame. It then draws
the bay's tree front to back into whatever pixels are still empty. From
inside the cabin those are the windows, so the bay never draws over the
office. From outside, the bay's pixels are depth tested against the craft's
instead. Both walks skip subtrees whose screen bounds fall only on pixels
already drawn.

Your monitor's picture is drawn into a 192 by 144 buffer each frame and
mapped onto the screen polygon, with curved glass, darker corners and scan
lines. Everyone else's monitor runs a starfield screen saver.

A test draws fixed views both ways, through the trees and by putting every
polygon through a plain depth buffer, and checks that at least 99.5% of
pixels match. On an Apple M5 in Node.js, five fixed views take 6 to 13 ms a
frame through the trees and 12 to 16 ms through the depth buffer.

The craft's motion is simulated in fixed 16 ms steps, per unit mass. Thrust
and drag act along and across the craft separately, and full throttle tops
out at 20 m/s (39 knots). Steering grows with the
air across the rudders, the stern's fins swing the bow toward the direction
of travel, and the hull bounces off obstacles and spins about its centre when
hit off-centre. Walking happens in the craft's frame, so you move with the
office, and its accelerations throw you about. The title, pause and end
screens request no wakes, and only `render` writes the 640 by 480 KTX2 frame.
