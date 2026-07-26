package main

import "core:fmt"
import "core:slice"
import "core:strings"
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
	message: string,
	plates: string,
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
	k2.stop_audio_stream(g_world.music)
	
	g_world = {
		camera = k2.Camera{
			zoom = 2.0,
			offset = { WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2 },
		},
		time_since_dialog = 10.0,
		music = g_music[.CREEPIN_SPOOKIN],
	}
	mem.arena_init(&g_world.arena, g_world_memory)
	context.allocator = mem.arena_allocator(&g_world.arena)
	mem.arena_init(&g_world.dialog_arena, make([]byte, 2 * mem.Kilobyte))
	
	level: Ogmo_Map
	json.unmarshal(level_bytes, &level) or_return
	// Spawn walls and floors first
	for layer in level.layers {
		switch layer.name {
			case "Walls": {
				assert(len(layer.grid) == layer.num_cols * layer.num_rows)
				g_world.wall_cols = layer.num_cols
				g_world.wall_rows = layer.num_rows
				g_world.walls = make([dynamic]Wall_Type, len(layer.grid))
				for i in 0..<len(layer.grid) {
					wall_number, ok := strconv.parse_int(layer.grid[i])
					if !ok {
						log.warnf("grid tile at index %v did not parse correctly", i)
					}
					g_world.walls[i] = Wall_Type(wall_number)
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
		}
	}

	// Spawn entities after walls have been established
	for layer in level.layers {
		if layer.name == "Entities" {
			highest_turn := 0
			for ogmo_ent in layer.entities {
				ent := Entity{
					pos = { int(ogmo_ent.x / TILE_SIZE), int(ogmo_ent.y / TILE_SIZE) },
					flags = { .VISIBLE, .INTERACTABLE },
					size = [2]int{1, 1},
				}
				if len(ogmo_ent.values.name) != 0 {
					ent.name = ogmo_ent.values.name
				} else {
					ent.name = fmt.aprintf("%v", ogmo_ent.id)
				}
				sprite_pos := cast([2]f32)(ent.pos * TILE_SIZE)
				switch ogmo_ent.name {
					case "Muji": {
						ent.data = Player_Data{
							type = .MUJI,
							active_type = .MUJI,
						}
					}
					case "Panettone": {
						ent.data = Player_Data{
							type = .PANETTONE,
							active_type = .PANETTONE,
						}
					}
					case "Polenta": {
						ent.data = Player_Data{
							type = .POLENTA,
							active_type = .POLENTA,
						}
					}
					case "Boromi": {
						ent.data = Player_Data{
							type = .BOROMI,
							active_type = .BOROMI,
						}
					}
					case "Door": {
						data := Door_Data{
							message = ogmo_ent.values.message,
							key_needed = ogmo_ent.values.key,
						}
						plates := ogmo_ent.values.plates
						for name in strings.split_iterator(&plates, ",") {
							if len(data.plates_needed) == cap(data.plates_needed) {
								log.warnf("Too many plate names given for door: %v", ogmo_ent.values.plates)
								break
							}
							append(&data.plates_needed, name)
						}
						if wall_at(ent.pos + { -1, 0 }) != .EMPTY && 
							wall_at(ent.pos + { 1, 0 }) == .EMPTY && 
							wall_at(ent.pos + { 2, 0 }) == .EMPTY 
						{
							// Turn into a big door if there's enough space.
							ent.size = [2]int{3, 1}
						}
						ent.data = data
					}
					case "Key": {
						ent.data = Key_Data{
							title = ogmo_ent.values.title,
						}
					}
					case "Plate": {
						ent.data = Plate_Data{
							pressed = false,
						}
					}
					case "Furniture": {
						ent.data = Furniture_Data{}
					}
					case "Bars": {
						ent.data = Bars_Data{}
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
			break
		}
	}

	k2.set_audio_stream_loop(g_world.music, true)
	k2.play_audio_stream(g_world.music)
	k2.update_audio_stream(g_world.music)

	return nil
}

Wall_Type :: enum {
	EMPTY,
	SOLID,
	PIT,
}

Wall_Neighbor :: enum {
    TOP_LEFT,
    TOP_RIGHT,
    BOTTOM_RIGHT,
    BOTTOM_LEFT,
}

Wall_Neighbors :: bit_set[Wall_Neighbor]

@(rodata)
Wall_Rects := [Wall_Type][16]k2.Rect{
	.EMPTY = {},
	.SOLID = {
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
	},
	.PIT = {
		0 = { x = 160, y = 160, w = TILE_SIZE, h = TILE_SIZE },
		1 = { x = 64, y = 224, w = TILE_SIZE, h = TILE_SIZE },
		2 = { x = 0, y = 224, w = TILE_SIZE, h = TILE_SIZE },
		3 = { x = 32, y = 224, w = TILE_SIZE, h = TILE_SIZE },
		4 = { x = 0, y = 160, w = TILE_SIZE, h = TILE_SIZE },
		5 = { x = 96, y = 160, w = TILE_SIZE, h = TILE_SIZE },
		6 = { x = 0, y = 192, w = TILE_SIZE, h = TILE_SIZE },
		7 = { x = 128, y = 192, w = TILE_SIZE, h = TILE_SIZE },
		8 = { x = 64, y = 160, w = TILE_SIZE, h = TILE_SIZE },
		9 = { x = 64, y = 192, w = TILE_SIZE, h = TILE_SIZE },
		10 = { x = 128, y = 160, w = TILE_SIZE, h = TILE_SIZE },
		11 = { x = 96, y = 192, w = TILE_SIZE, h = TILE_SIZE },
		12 = { x = 32, y = 160, w = TILE_SIZE, h = TILE_SIZE },
		13 = { x = 96, y = 224, w = TILE_SIZE, h = TILE_SIZE },
		14 = { x = 128, y = 224, w = TILE_SIZE, h = TILE_SIZE },
		15 = { x = 32, y = 192, w = TILE_SIZE, h = TILE_SIZE },
	},
}

Door_Data :: struct {
	key_needed: string,
	plates_needed: [dynamic; 4]string,
	plates_pressed: int,
	message: string,
}

update_door :: proc(door: ^Entity, door_data: ^Door_Data) {
	door_data.plates_pressed = 0
	it := hm.iterator_make(&g_world.ents)
	for ent, handle in hm.iterate(&it) {
		plate_data, is_plate := ent.data.(Plate_Data)
		if is_plate && plate_data.pressed && slice.any_of(door_data.plates_needed[:], ent.name) {
			door_data.plates_pressed += 1
		}
	}
	if len(door_data.plates_needed) > 0 && door_data.plates_pressed >= len(door_data.plates_needed) {
		door.flags -= {.INTERACTABLE}
	} else {
		door.flags += {.INTERACTABLE}
	}
}

Key_Data :: struct {
	title: string,
}

Plate_Data :: struct {
	pressed: bool,
}

update_plate :: proc(plate: ^Entity, plate_data: ^Plate_Data) {
	it := hm.iterator_make(&g_world.ents)
	previously_pressed := plate_data.pressed
	plate_data.pressed = false
	for ent, handle in hm.iterate(&it) {
		if handle != plate.handle && ent.pos == plate.pos {
			plate_data.pressed = true
			break
		}
	}
	if plate_data.pressed && !previously_pressed {
		k2.play_sound(g_sounds[.SWITCH])
	} else if !plate_data.pressed && previously_pressed {
		k2.play_sound(g_sounds[.UNSWITCH])
	}
}

Furniture_Data :: struct {}

Bars_Data :: struct {}