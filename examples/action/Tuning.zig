//! Hand-tuned gameplay numbers, gathered so the loop and components read one
//! value each rather than closing over two dozen loose consts. Values are the
//! same as before -- this only relocates them.

walk_speed: f32 = 1.6,
run_speed: f32 = 3.0,
run_clip_speed: f32 = 3.0,
clip_speed: f32 = 1.6,
turn_rate: f32 = 10.0,
blend_rate: f32 = 8.0,
gravity: f32 = -25.0,
step_smooth_rate: f32 = 12.0,
respawn_below: f32 = -20.0,
follow_distance: f32 = 3.0,
focus_height: f32 = 0.6,
fly_speed: f32 = 4.0,
mouse_sensitivity: f32 = 0.0025,
hitstop_duration: f32 = 0.08,
knockback_speed: f32 = 6.0,
knockback_damping: f32 = 8.0,
hurt_radius: f32 = 0.5,
hurt_height: f32 = 1.2,
// model_scale and jump_speed are derived (path / jump_height); keep them
// computed in start() and store the results here.
model_scale: f32 = 0.5,
jump_speed: f32 = 0,
