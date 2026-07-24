package main

import "core:math/rand"
import k2 "karl2d"

Player_Type :: enum {
    MUJI,
    PANETTONE,
    POLENTA,
    BOROMI,
}

@(rodata)
Player_Rects := [Player_Type]k2.Rect{
    .MUJI = { x = 0, y = 0, w = TILE_SIZE, h = TILE_SIZE },
    .PANETTONE = { x = 32, y = 0, w = TILE_SIZE, h = TILE_SIZE },
    .POLENTA = { x = 64, y = 0, w = TILE_SIZE, h = TILE_SIZE },
    .BOROMI = { x = 96, y = 0, w = TILE_SIZE, h = TILE_SIZE },
}

Player_Data :: struct {
    type: Player_Type,
}

update_player :: proc(ent: ^Entity, delta_time: f32) {
	assert(ent != nil)

	MOVE_INTERVAL :: 0.25
	@(static) move_timer: f32

	want_left := k2.key_is_held(.Left) || k2.key_is_held(.A)
	want_right := k2.key_is_held(.Right) || k2.key_is_held(.D)
	want_up := k2.key_is_held(.Up) || k2.key_is_held(.W)
	want_down := k2.key_is_held(.Down) || k2.key_is_held(.S)

	movement: [2]int
	
	if want_left || want_right || want_up || want_down {
		move_timer += delta_time
		if move_timer > MOVE_INTERVAL {
			move_timer = 0
			if want_left {
				movement[0] = -1
			} else if want_right {
				movement[0] = 1
			} else if want_up {
				movement[1] = -1
			} else if want_down {
				movement[1] = 1
			}
			footstep := g_sounds[.FOOTSTEP]
			k2.set_sound_pitch(footstep, rand.float32_range(0.75, 1.25))
			k2.set_sound_volume(footstep, rand.float32_range(0.5, 1.5))
			k2.play_sound(footstep)
		}
	} else {
		move_timer = MOVE_INTERVAL
	}

	dest := ent.pos + movement
	if wall_at(dest) == 0 {
		ent.pos = dest
	}
}