// Pure, DOM-free movement/joystick/smoothing math (P1-07A) — Client Input Layer only.
// Server remains the sole authoritative source of world position (see server.mjs's moveWorld());
// these functions only decide (a) what target to *ask* the server for, from the joystick's
// direction+magnitude, and (b) how to smoothly *display* the last confirmed server position —
// they never move the character themselves, and display easing only ever chases the latest
// known server truth, never a client-predicted/extrapolated position.

// Prototype Parameters — tunable, not a final UX spec; expected to be re-tuned after real-device
// (iPhone) testing per P1-07A's acceptance gate.
export const JOYSTICK_RADIUS=52;
export const JOYSTICK_DEADZONE=10;
export const JOYSTICK_STEP_DISTANCE=18;
// 140ms, not 120ms: must stay above server.mjs's MOVEMENT_MIN_INTERVAL_MS=120 with a margin
// (20ms buffer), otherwise a client cadence at or below the server's own throttle window
// produces accepted-move / throttled-zero-move / accepted-move oscillation — authoritative
// position would then only advance roughly every 2 client sends (~every 200ms+), directly
// re-introducing the double-throttle stutter P1-07A exists to fix.
export const JOYSTICK_SEND_INTERVAL_MS=140;
export const CHARACTER_SMOOTHING_MS=80;
export const CAMERA_SMOOTHING_MS=120;

// Raw pointer offset (dx,dy) from the joystick's fixed center, in px, mapped to a normalized
// direction + magnitude. Anything within the deadzone is treated as no input at all. Magnitude
// ramps 0→1 between the deadzone edge and the outer radius; distances beyond the radius clamp to
// magnitude 1 (direction keeps following the finger, speed does not increase further).
export function computeJoystickInput(dx,dy,radius=JOYSTICK_RADIUS,deadzone=JOYSTICK_DEADZONE){
  const distance=Math.hypot(dx,dy);
  if(distance<=deadzone)return{active:false,dirX:0,dirY:0,magnitude:0};
  const clamped=Math.min(distance,radius);
  const magnitude=Math.max(0,Math.min(1,(clamped-deadzone)/(radius-deadzone)));
  return{active:true,dirX:dx/distance,dirY:dy/distance,magnitude};
}

// Clamps a raw pointer offset to within the joystick's radius, purely for rendering the knob —
// the knob must never visually leave its base circle even when the finger drags further.
export function clampJoystickKnob(dx,dy,radius=JOYSTICK_RADIUS){
  const distance=Math.hypot(dx,dy);
  if(distance<=radius)return{x:dx,y:dy};
  const ratio=radius/distance;
  return{x:dx*ratio,y:dy*ratio};
}

// The next world/move target: a small step from the *last known server position* in the
// joystick's direction, scaled by magnitude — never from a client-predicted/extrapolated
// position. Returns null when there is no active input (nothing to send this tick).
export function computeJoystickTarget(serverPosition,input,stepDistance=JOYSTICK_STEP_DISTANCE){
  if(!input?.active)return null;
  return{x:serverPosition.x+input.dirX*input.magnitude*stepDistance,y:serverPosition.y+input.dirY*input.magnitude*stepDistance};
}

// Delta-time based exponential smoothing (frame-rate independent): eases `current` toward
// `target` by an amount that depends on elapsed real time `dt` (ms), not on how many frames have
// passed. Composable: applying this twice with dt1 then dt2 produces (up to floating-point
// precision) the same result as one application with dt1+dt2 — verified in tests.
export function easeTowards(current,target,dt,smoothingMs){
  if(smoothingMs<=0)return target;
  const factor=1-Math.exp(-dt/smoothingMs);
  return current+(target-current)*factor;
}

// Full Map is inspection-only: while active, movement intent must not drive the character.
export function isMovementAllowed(mapView){
  return mapView!=='full';
}

// Pure gating decision for whether a joystick tick should actually send a world/move command.
export function shouldSendJoystickMove(mapView,joystickInputActive){
  return isMovementAllowed(mapView)&&!!joystickInputActive;
}
