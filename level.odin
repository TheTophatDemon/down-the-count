package main

import "core:log"
import "core:encoding/json"
import "core:strconv"
import "core:mem"
import hm "core:container/handle_map"
import k2 "karl2d"

Ogmo_Entity_Values :: struct {
	key: string,
	name: string,
	turn: int,
	title: string,
}

Ogmo_Entity :: struct {
	name: string,
	id: int,
	x: f32,
	y: f32,
	origin_x: f32 `json:"originX"`,
	origin_y: f32 `json:"originY"`,
	values: Ogmo_Entity_Values,
}

Ogmo_Layer :: struct {
	name: string,
	offset_x: int `json:"offsetX"`,
	offset_y: int `json:"offsetY"`,
	grid_cell_width: int `json:"gridCellWidth"`,	
	grid_cell_height: int `json:"gridCellHeight`,
	num_rows: int `json:"gridCellsY"`,
	num_cols: int `json:"gridCellsX"`,
	grid: [dynamic]string,
	tile_data: [dynamic]int `json:"data"`,
	entities: [dynamic]Ogmo_Entity,
}

Ogmo_Map :: struct {
	width_pixels: int `json:"width"`,
	height_pixels: int `json:"height"`,
	layers: [dynamic]Ogmo_Layer
}

load_level :: proc(level_bytes: []byte) -> json.Unmarshal_Error {
	g_world = {
		camera = k2.Camera{
			zoom = 2.0,
			offset = { SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2 },
		},
		time_since_player_switch = 0,
	}
	mem.arena_init(&g_world.arena, g_world_memory)
	context.allocator = mem.arena_allocator(&g_world.arena)
	
	level: Ogmo_Map
	json.unmarshal(level_bytes, &level) or_return
	for layer in level.layers {
		switch layer.name {
			case "Walls": {
				assert(len(layer.grid) == layer.num_cols * layer.num_rows)
				g_world.wall_cols = layer.num_cols
				g_world.wall_rows = layer.num_rows
				g_world.walls = make([dynamic]int, len(layer.grid))
				for i in 0..<len(layer.grid) {
					ok: bool
					g_world.walls[i], ok = strconv.parse_int(layer.grid[i])
					if !ok {
						log.warnf("grid tile at index %v did not parse correctly", i)
					}
				}
			}
			case "Floors": {
				assert(len(layer.tile_data) == layer.num_cols * layer.num_rows)
				g_world.floor_cols = layer.num_cols
				g_world.floor_rows = layer.num_rows
				g_world.floors = make([dynamic]int, len(layer.tile_data))
				for i in 0..<len(layer.tile_data) {
					g_world.floors[i] = layer.tile_data[i]
				}
			}
			case "Entities": {
				highest_turn := 0
				for ogmo_ent in layer.entities {
					ent := Entity{
						pos = { int(ogmo_ent.x / TILE_SIZE), int(ogmo_ent.y / TILE_SIZE) },
						flags = { .VISIBLE, .INTERACTABLE },
					}
					sprite_pos := cast([2]f32)(ent.pos * TILE_SIZE)
					switch ogmo_ent.name {
						case "Muji":
							ent.data = Player_Data{
								type = .MUJI,
							}
						case "Panettone":
							ent.data = Player_Data{
								type = .PANETTONE,
							}
						case "Polenta":
							ent.data = Player_Data{
								type = .POLENTA,
							}
						case "Boromi":
							ent.data = Player_Data{
								type = .BOROMI,
							}
						case "Door":
							ent.data = Door_Data{
								key_needed = ogmo_ent.values.key,
							}
						case "Key":
							ent.data = Key_Data{
								name = ogmo_ent.values.name,
								title = ogmo_ent.values.title,
							}
					}
					new_handle, ok := hm.static_add(&g_world.ents, ent)
					if !ok {
						log.error("ran out of entities!")
						break
					}
					if turn := ogmo_ent.values.turn; turn > highest_turn {
						highest_turn = turn
						g_world.active_player = new_handle
						g_world.camera.target = sprite_pos
					}
				}
			}
		}
	}

	return nil
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

Door_Data :: struct {
	key_needed: string,
}

Key_Data :: struct {
	name: string,
	title: string,
}