package main

import "core:math/linalg"
import "core:math"
import "core:slice"
import "core:log"
import "core:math/rand"
import "core:fmt"
import hm "core:container/handle_map"
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

@rodata
Muji_Disguise_Rects := [Player_Type]k2.Rect{
	.MUJI = { x = 0, y = 0, w = TILE_SIZE, h = TILE_SIZE },
	.PANETTONE = { x = 0, y = 32, w = TILE_SIZE, h = TILE_SIZE },
    .POLENTA = { x = 0, y = 64, w = TILE_SIZE, h = TILE_SIZE },
    .BOROMI = { x = 0, y = 96, w = TILE_SIZE, h = TILE_SIZE },
}

Player_Data :: struct {
    type: Player_Type,
	active_type: Player_Type, // The type that determines player abilities. This allows Muji to act like other player types.
	active_timer: int, // Number of turns before active type resets.
}

player_add_inventory :: proc(player: Entity, item_handle: Entity_Handle) -> bool {
	data, is_player := player.data.(Player_Data)
	if !is_player {
		log.errorf("tried to add inventory to non-player entity of type %v", player.data)
		return false
	}
	return append(&g_world.inventories[data.type], item_handle) != 0
}

player_remove_inventory :: proc(player: Entity, index: int) {
	data, is_player := player.data.(Player_Data)
	if !is_player {
		log.errorf("tried to remove inventory from non-player entity of type %v", player.data)
		return
	}
	inventory_size := len(g_world.inventories[data.type])
	if index < 0 || index >= inventory_size {
		log.errorf("attempted to remove inventory at index %v", index)
		return
	}
	ordered_remove(&g_world.inventories[data.type], index)
}

update_player :: proc(player: ^Entity, player_data: ^Player_Data, delta_time: f32) -> (step_time: bool) {
	assert(player != nil && player_data != nil)

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
		}
	} else {
		move_timer = MOVE_INTERVAL
	}

	dest := player.pos + movement

	movement_blocked: bool

	// Pit jumping
	if player_data.active_type == .POLENTA {
		wall_ahead := wall_at(dest)
		if wall_ahead == .PIT {
			dest += movement
			it := hm.iterator_make(&g_world.ents)
			blocking_ent, _, _ := iterate_ents_at(&it, dest, true)
			if blocking_ent != nil {
				// There is an entity blocking us on the other side of the gap.
				movement_blocked = true
				dest = player.pos
			}
		}
	}

	// Interact with entities being hit
	it := hm.iterator_make(&g_world.ents)
	for other_ent, other_handle in iterate_ents_at(&it, dest, false) {
		if other_handle == player.handle do continue
		data_switch: #partial switch &data in other_ent.data {
			case Door_Data: {
				step_time = true
				// Check for key possession
				for item_handle, item_index in g_world.inventories[player_data.type] {
					item_ent, exists := hm.static_get(&g_world.ents, item_handle)
					if !exists do continue
					if slice.any_of(data.inputs_needed[:], item_ent.name) {
						player_remove_inventory(player^, item_index)
						hm.static_remove(&g_world.ents, other_handle)
						k2.play_sound(g_sounds[.UNLOCK])
						movement_blocked = true
						break data_switch
					}
				}
				show_dialog(data.message)
				movement_blocked = true
				k2.play_sound(g_sounds[.LOCKED])
			}
			case Player_Data: {
				movement_blocked = true
				if player_data.type == .MUJI {
					player_data.active_type = data.type
					player_data.active_timer = 20
					k2.play_sound(g_sounds[.POOF])
					spawn_smoke(player.pos)
				}
			}
			case Furniture_Data: {
				movement_blocked = true
				if player_data.active_type == .PANETTONE {
					push_to := other_ent.pos + movement
					if wall_at(push_to) == .EMPTY {
						blocking_it := hm.iterator_make(&g_world.ents)
						blocking_ent, _, _ := iterate_ents_at(&blocking_it, push_to, true)
						if blocking_ent == nil {
							other_ent.pos = push_to
							step_time = true
							movement_blocked = false
							k2.set_sound_pitch(g_sounds[.PUSH], rand.float32_range(0.75, 1.25))
							k2.set_sound_volume(g_sounds[.PUSH], rand.float32_range(0.7, 1.0))
							k2.play_sound(g_sounds[.PUSH])
						}
					} 
				}
			}
			case Key_Data: {
				if player_add_inventory(player^, other_handle) {
					step_time = true
					other_ent.flags -= { .VISIBLE, .INTERACTABLE }
					k2.play_sound(g_sounds[.KEY])
					show_dialog(fmt.tprintf("You got %v.", data.title))
				}
			}
		}
	}

	if player.pos != dest && !movement_blocked && wall_at(dest) == .EMPTY {
		step_time = true
		if player_data.active_type != player_data.type {
			player_data.active_timer -= 1
			if player_data.active_timer <= 0  {
				player_data.active_timer = 0
				player_data.active_type = player_data.type
				k2.play_sound(g_sounds[.POOF])
				spawn_smoke(player.pos)
			}
			spawn_counter(player.handle, player_data.active_timer)
		}
		if abs(dest.x - player.pos.x) + abs(dest.y - player.pos.y) > 1.0 {
			jump := g_sounds[.JUMP]
			k2.set_sound_pitch(jump, rand.float32_range(0.75, 1.25))
			k2.set_sound_volume(jump, rand.float32_range(0.7, 1.0))
			k2.play_sound(jump)
			spawn_swoosh((player.pos + dest) / 2, movement)
		} else {
			footstep := g_sounds[.FOOTSTEP]
			k2.set_sound_pitch(footstep, rand.float32_range(0.75, 1.25))
			k2.set_sound_volume(footstep, rand.float32_range(0.4, 0.8))
			k2.play_sound(footstep)
		}
		player.pos = dest
	}
	return
}