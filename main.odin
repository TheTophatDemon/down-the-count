package main

import "core:log"
import "core:fmt"
import "core:mem"
import "core:math"
import "core:math/ease"
import hm "core:container/handle_map"
import k2 "karl2d"

SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
TILE_SIZE :: 32

Entity_Handle :: hm.Handle32

Entity_Data :: union {
    Player_Data,
    Door_Data,
    Key_Data,
}

Entity_Flag :: enum {
    VISIBLE,
    INTERACTABLE,
}

Entity_Flags :: bit_set[Entity_Flag]

Entity :: struct {
    handle: Entity_Handle,
    pos: [2]int, // Grid position, in terms of row / column
    flags: Entity_Flags,
    data: Entity_Data,
}

Time_Step :: struct {
    ents: hm.Static_Handle_Map(128, Entity, Entity_Handle),
    active_player: Entity_Handle,
    inventories: [Player_Type][4]Entity_Handle,
}

g_previous_time_steps: [dynamic; 32]Time_Step

g_world_memory: []u8

g_world := struct{
    using time_step: Time_Step,
    arena: mem.Arena,
    wall_cols, wall_rows: int,
    walls: [dynamic]int,
    floor_cols, floor_rows: int,
    floors: [dynamic]int,
    camera: k2.Camera,
    time_since_player_switch: f32,
    time_since_last_step: f32,
}{}

main :: proc() {
    when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

    init()
    for step() {}
    shutdown()
}

init :: proc() {
    context.logger = log.create_console_logger()
    g_world_memory = make([]u8, 4 * mem.Megabyte)
	k2.init(SCREEN_WIDTH, SCREEN_HEIGHT, "Down the Count")
    load_assets()
    err := load_level(#load("assets/manor.json"))
    if err != nil {
        log.errorf("could not load level: %v", err)
        return
    }
}

step :: proc() -> bool {
    if !k2.update() {
        return false
    }

    delta_time := k2.get_frame_time()
    g_world.time_since_player_switch += delta_time
    g_world.time_since_last_step += delta_time

    previous_time_step, err := new_clone(g_world.time_step)
    if err != nil {
        log.errorf("error allocating memory for previous time step: %v", err)
        return false
    }
    defer free(previous_time_step)

    update: {
        // Undo
        if (k2.key_went_down(.Z) || k2.key_went_down(.Backspace)) && len(g_previous_time_steps) > 0 {
            g_world.time_step = pop(&g_previous_time_steps)
            break update
        }

        step_time := false

        next_player_type: Maybe(Player_Type)

        // Update entities
        it := hm.iterator_make(&g_world.ents)
        for ent, handle in hm.iterate(&it) {
            if handle == g_world.active_player {
                player_data, is_player := ent.data.(Player_Data)
                assert(is_player)
                step_time ||= update_player(ent, delta_time)

                if k2.key_went_down(.E) || k2.key_went_down(.Period) {
                    next_player_type = Player_Type((int(player_data.type) + 1) % len(Player_Type))
                } else if k2.key_went_down(.Q) || k2.key_went_down(.Comma) {
                    next_player_type = Player_Type((int(player_data.type) + len(Player_Type) - 1) % len(Player_Type))
                } 

                g_world.camera.target += (cast([2]f32)(ent.pos * TILE_SIZE) + { TILE_SIZE / 2, TILE_SIZE / 2 } - g_world.camera.target) * 0.5            
            }
        }

        // Change player
        if next_player_type != nil {
            g_world.time_since_player_switch = 0.0
            it = hm.iterator_make(&g_world.ents)
            for ent, handle in hm.iterate(&it) {
                player_data, is_player := ent.data.(Player_Data)
                if is_player && player_data.type == next_player_type.? {
                    g_world.active_player = handle
                    break
                }
            }
        }

        if step_time {
            g_world.time_since_last_step = 0.0
            if len(g_previous_time_steps) == cap(g_previous_time_steps) {
                pop_front(&g_previous_time_steps)
            }
            append(&g_previous_time_steps, previous_time_step^)
        }
    }

    k2.clear(k2.BLACK)
	k2.set_camera(g_world.camera)
    
    active_player_type := draw_world()

    k2.set_camera(k2.Camera{
        zoom = 2,
    })
    draw_hud(active_player_type)

    k2.present()

    free_all(context.temp_allocator)

    return true
}

wall_at :: proc(pos: [2]int) -> int {
    if pos[0] < 0 || pos[1] < 0 || pos[0] >= g_world.wall_cols || pos[1] >= g_world.wall_rows {
        return 0
    }
    flat_idx := pos[0] + (pos[1] * g_world.wall_cols)
    return g_world.walls[flat_idx]
}

draw_world :: proc() -> (active_player_type: Player_Type) {
    previous_time_step := g_world.time_step
    if len(g_previous_time_steps) > 0 {
        previous_time_step = g_previous_time_steps[len(g_previous_time_steps) - 1]
    }

    tile_atlas_cols := g_textures[.TILES].width / TILE_SIZE
    tile_atlas_rows := g_textures[.TILES].height / TILE_SIZE
    // Draw floors
    for tile_id, i in g_world.floors {
        if tile_id < 0 do continue
        
        k2.draw_texture_rect(
            texture = g_textures[.TILES], 
            source = { 
                x = f32(tile_id % tile_atlas_cols) * TILE_SIZE, 
                y = f32(tile_id / tile_atlas_cols) * TILE_SIZE,
                w = TILE_SIZE, h = TILE_SIZE,
            },
            position = {
                f32(i % g_world.floor_cols) * TILE_SIZE,
                f32(i / g_world.floor_cols) * TILE_SIZE,
            }
        )
    }

    // Draw entities
    draw_arrow_at: Maybe([2]f32)
    it := hm.iterator_make(&g_world.ents)
    for ent, handle in hm.iterate(&it) {
        if .VISIBLE not_in ent.flags do continue

        // Smoothly animate the position from one step to the next
        // target_sprite_pos := cast([2]f32)(ent.pos * TILE_SIZE)
        // previous_sprite_pos := target_sprite_pos
        // if prev_ent, ok := hm.static_get(&previous_time_step.ents, handle); ok {
        //     previous_sprite_pos = cast([2]f32)(prev_ent.pos * TILE_SIZE)
        // }
        // sprite_pos := target_sprite_pos
        // if target_sprite_pos != previous_sprite_pos {
        //     t := min(1.0, g_world.time_since_last_step * 4.0)
        //     sprite_pos = previous_sprite_pos + (target_sprite_pos - previous_sprite_pos) * ease.cubic_out(t)
        // }
        sprite_pos := cast([2]f32)(ent.pos * TILE_SIZE)

        switch data in ent.data {
            case Player_Data: {
                if handle == g_world.active_player {
                    active_player_type = data.type
                    if g_world.time_since_player_switch < 1.0 {
                        draw_arrow_at = sprite_pos + {16, math.sin(g_world.time_since_player_switch * 4.0) * 2}
                    }
                }
                k2.draw_texture_rect(
                    g_textures[.CHARACTERS], 
                    Player_Rects[data.type],
                    sprite_pos, 
                )
            }
            case Door_Data: {
                src := k2.Rect{
                    x = 192, y = 0,
                    w = TILE_SIZE, h = TILE_SIZE,
                }
                if wall_at(ent.pos + { -1, 0 }) > 0 || wall_at(ent.pos + { 1, 0 }) > 0 {
                    src.x += TILE_SIZE
                }
                k2.draw_texture_rect(
                    g_textures[.TILES],
                    src,
                    sprite_pos,
                )
            }
            case Key_Data: {
                k2.draw_texture_rect(
                    g_textures[.ITEMS],
                    { x = 0, y = 0, w = 16, h = 16 },
                    sprite_pos + { 0, math.sin(g_world.time_since_player_switch * 4.0) * 2 },
                    { -8, -8 },
                )
            }
        }
    }

    // Draw walls (using double grid tiling system)
    for y in 0..=g_world.wall_rows {
        for x in 0..=g_world.wall_cols {
            neighbors: Wall_Neighbors
            if wall_at({ x - 1, y - 1}) > 0 {
                neighbors |= { .TOP_LEFT }
            }
            if wall_at({ x, y - 1}) > 0 {
                neighbors |= { .TOP_RIGHT }
            }
            if wall_at({ x, y }) > 0 {
                neighbors |= { .BOTTOM_RIGHT }
            }
            if wall_at({ x - 1, y }) > 0 {
                neighbors |= { .BOTTOM_LEFT }
            }
            if neighbors != {} {
                k2.draw_texture_rect(
                    g_textures[.TILES], 
                    Wall_Rects[transmute(u8)neighbors],
                    { 
                        f32(x * TILE_SIZE) - (TILE_SIZE / 2),
                        f32(y * TILE_SIZE) - (TILE_SIZE / 2)
                    }
                )
            }
        }
    }

    // Draw selection arrow
    if pos, ok := draw_arrow_at.([2]f32); ok {
        k2.draw_texture_rect(
            g_textures[.CHARACTERS], 
            {x = 160, y = 0, w = 16, h = 16},
            pos,
            { 8, 16 },
        )
    }

    return
}

draw_hud :: proc(active_player_type: Player_Type) {
    // Draw inventory
    for handle, i in g_world.inventories[active_player_type] {
        // Draw slot background
        slot_pos := [2]f32{ 4, 4 + f32(i * 32) }
        k2.draw_texture_rect(g_textures[.ITEMS], { 32, 16, 32, 32 }, slot_pos)

        if item_ent, present := hm.static_get(&g_world.ents, handle); present {
            #partial switch data in item_ent.data {
                case Key_Data: {
                    rect: k2.Rect = { x = 0, w = 32, h = 32 }
                    switch data.name {
                        case "MUJI": rect.y = 16
                        case "PANT": rect.y = 48
                        case "POLE": rect.y = 80
                        case "BORO": rect.y = 112
                    }
                    k2.draw_texture_rect(g_textures[.ITEMS], rect, slot_pos)
                }
            }
        }
    }
}

shutdown :: proc() {
    unload_assets()
    k2.shutdown()
    delete(g_world_memory)
}