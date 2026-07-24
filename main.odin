package main

import "core:log"
import "core:fmt"
import "core:mem"
import "core:math"
import hm "core:container/handle_map"
import k2 "karl2d"

SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
TILE_SIZE :: 32

Entity_Handle :: hm.Handle32

Entity :: struct {
    handle: Entity_Handle,
    pos: [2]int,
    sprite_pos: [2]f32,
    data: union {
        Player_Data,
    }
}

Wall_Neighbor :: enum {
    TOP_LEFT,
    TOP_RIGHT,
    BOTTOM_RIGHT,
    BOTTOM_LEFT,
}

Wall_Neighbors :: bit_set[Wall_Neighbor]

@(rodata)
Wall_Rects := [16]k2.Rect{
    0 = { x = 160, y = 0, w = TILE_SIZE, h = TILE_SIZE },
    1 = { x = 64, y = 64, w = TILE_SIZE, h = TILE_SIZE },
    2 = { x = 0, y = 64, w = TILE_SIZE, h = TILE_SIZE },
    3 = { x = 32, y = 64, w = TILE_SIZE, h = TILE_SIZE },
    4 = { x = 0, y = 0, w = TILE_SIZE, h = TILE_SIZE },
    5 = { x = 96, y = 0, w = TILE_SIZE, h = TILE_SIZE },
    6 = { x = 0, y = 32, w = TILE_SIZE, h = TILE_SIZE },
    7 = { x = 128, y = 32, w = TILE_SIZE, h = TILE_SIZE },
    8 = { x = 64, y = 0, w = TILE_SIZE, h = TILE_SIZE },
    9 = { x = 64, y = 32, w = TILE_SIZE, h = TILE_SIZE },
    10 = { x = 128, y = 0, w = TILE_SIZE, h = TILE_SIZE },
    11 = { x = 96, y = 32, w = TILE_SIZE, h = TILE_SIZE },
    12 = { x = 32, y = 0, w = TILE_SIZE, h = TILE_SIZE },
    13 = { x = 96, y = 64, w = TILE_SIZE, h = TILE_SIZE },
    14 = { x = 128, y = 64, w = TILE_SIZE, h = TILE_SIZE },
    15 = { x = 32, y = 32, w = TILE_SIZE, h = TILE_SIZE },
}

g_world_memory: []u8

g_world := struct{
    arena: mem.Arena,
    wall_cols, wall_rows: int,
    walls: [dynamic]int,
    floor_cols, floor_rows: int,
    floors: [dynamic]int,
    camera: k2.Camera,
    time_since_player_switch: f32,
    ents: hm.Static_Handle_Map(512, Entity, Entity_Handle),
    active_player: Entity_Handle,
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
    next_player_type: Maybe(Player_Type)

    // Update entities
    it := hm.iterator_make(&g_world.ents)
    for ent, handle in hm.iterate(&it) {
        if handle == g_world.active_player {
            player_data, is_player := ent.data.(Player_Data)
            assert(is_player)
            update_player(ent, delta_time)

            if k2.key_went_down(.E) || k2.key_went_down(.Period) {
                next_player_type = Player_Type((int(player_data.type) + 1) % len(Player_Type))
            } else if k2.key_went_down(.Q) || k2.key_went_down(.Comma) {
                next_player_type = Player_Type((int(player_data.type) + len(Player_Type) - 1) % len(Player_Type))
            } 

            g_world.camera.target += (ent.sprite_pos - g_world.camera.target) * 0.5            
        }
        // Smoothly move sprite to new position.
        new_sprite_pos := cast([2]f32)(ent.pos * TILE_SIZE)
        ent.sprite_pos += (new_sprite_pos - ent.sprite_pos) * 0.5
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

    k2.clear(k2.BLACK)
	k2.set_camera(g_world.camera)
    draw_world()
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

draw_world :: proc() {
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
    it := hm.iterator_make(&g_world.ents)
    for ent, handle in hm.iterate(&it) {
        switch data in ent.data {
            case Player_Data:
                if g_world.time_since_player_switch < 1.0 && handle == g_world.active_player {
                    //TODO: Draw above the walls
                    k2.draw_texture_rect(
                        g_textures[.CHARACTERS], 
                        {x = 160, y = 0, w = 16, h = 16},
                        ent.sprite_pos + {16, math.sin(g_world.time_since_player_switch * 4.0) * 2},
                        { 8, 16 },
                    )
                }
                k2.draw_texture_rect(
                    g_textures[.CHARACTERS], 
                    Player_Rects[data.type],
                    ent.sprite_pos, 
                )
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
}

shutdown :: proc() {
    unload_assets()
    k2.shutdown()
    delete(g_world_memory)
}