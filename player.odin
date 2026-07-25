package main

import "core:log"
import "core:math/rand"
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

Player_Data :: struct {
    type: Player_Type,
}

player_add_inventory :: proc(player: Entity, item_handle: Entity_Handle) -> bool {
	data, is_player := player.data.(Player_Data)
	if !is_player {
		log.errorf("tried to add inventory to non-player entity of type %v", player.data)
		return false
	}
	for handle, i in g_world.inventories[data.type] {
		if !hm.is_valid(g_world.ents, handle) {
			g_world.inventories[data.type][i] = item_handle
			return true
		}
	}
	return false
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
	if index < inventory_size - 1 {
		// Shift items left by 1
		copy(g_world.inventories[data.type][index:], g_world.inventories[data.type][index+1:])
	}
	// Clear the last item
	g_world.inventories[data.type][inventory_size - 1] = {}
}

update_player :: proc(player: ^Entity, delta_time: f32) -> (step_time: bool) {
	assert(player != nil)
	player_data := &player.data.(Player_Data)
	player_type := player_data.type

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

	// Interact with entities being hit
	it := hm.iterator_make(&g_world.ents)
	for other_ent, other_handle in hm.iterate(&it) {
		if other_handle == player.handle || other_ent.pos != dest do continue
		if .INTERACTABLE not_in other_ent.flags do continue
		data_switch: #partial switch &data in other_ent.data {
			case Door_Data: {
				step_time = true
				// Check for key possession
				for item_handle, item_index in g_world.inventories[player_type] {
					item_ent, exists := hm.static_get(&g_world.ents, item_handle)
					if !exists do continue
					key, is_key := item_ent.data.(Key_Data)
					if !is_key do continue
					if key.name == data.key_needed {
						player_remove_inventory(player^, item_index)
						hm.static_remove(&g_world.ents, other_handle)
						k2.play_sound(g_sounds[.UNLOCK])
						movement_blocked = true
						break data_switch
					}
				}
				movement_blocked = true
				k2.play_sound(g_sounds[.LOCKED])
			}
			case Player_Data: {
				movement_blocked = true
			}
			case Key_Data: {
				if player_add_inventory(player^, other_handle) {
					step_time = true
					other_ent.flags -= { .VISIBLE, .INTERACTABLE }
					k2.play_sound(g_sounds[.KEY])
				}
			}
		}
	}

	if player.pos != dest && !movement_blocked && wall_at(dest) == 0 {
		step_time = true
		player.pos = dest
		footstep := g_sounds[.FOOTSTEP]
		k2.set_sound_pitch(footstep, rand.float32_range(0.75, 1.25))
		k2.set_sound_volume(footstep, rand.float32_range(0.5, 1.5))
		k2.play_sound(footstep)
	}
	return
}