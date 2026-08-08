package main

import "core:slice"
import "core:math/rand"
import "core:strings"
import "core:log"
import "core:fmt"
import "core:mem"
import "core:math"
import hm "core:container/handle_map"
import k2 "karl2d"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
SCREEN_WIDTH :: WINDOW_WIDTH / 2
SCREEN_HEIGHT :: WINDOW_HEIGHT / 2
TILE_SIZE :: 32

Language :: enum {
    English,
    Russian,
}

Entity_Handle :: hm.Handle32

Entity_Data :: union {
    Player_Data,
    Door_Data,
    Key_Data,
    Plate_Data,
    Furniture_Data,
    Bars_Data,
    Trigger_Data,
    Venizi_Data,
}

Entity_Flag :: enum {
    VISIBLE,
    INTERACTABLE,
}

Entity_Flags :: bit_set[Entity_Flag]

Entity :: struct {
    handle: Entity_Handle,
    pos: [2]int, // Grid position, in terms of row / column
    size: [2]int, // Hitbox size in grid coordinates
    flags: Entity_Flags,
    data: Entity_Data,
    name: string,
}

Time_Step :: struct {
    ents: hm.Static_Handle_Map(128, Entity, Entity_Handle),
    active_player: Entity_Handle,
    inventories: [Player_Type][dynamic; 4]Entity_Handle,
}

g_previous_time_steps: [dynamic; 128]Time_Step

g_world_memory: []u8

g_music_muted: bool = false

g_world := struct{
    using time_step: Time_Step,
    arena: mem.Arena,
    wall_cols, wall_rows: int,
    walls: [dynamic]Wall_Type,
    floor_cols, floor_rows: int,
    floors: [dynamic]int,
    camera: k2.Camera,
    time_since_start: f32,
    time_since_last_input: f32,
    time_since_dialog: f32,
    time_since_dialog_character: f32,
    dialog: string,
    dialog_arena: mem.Arena,
    dialog_shown_length: int,
    dialog_shown_line: string,
    effects: hm.Static_Handle_Map(32, Effect_Data, Effect_Handle),
    music: k2.Audio_Stream,
    win: bool,
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
	k2.init(WINDOW_WIDTH, WINDOW_HEIGHT, "Down the Count")
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
    g_world.time_since_start += delta_time
    g_world.time_since_last_input += delta_time
    g_world.time_since_dialog += delta_time
    g_world.time_since_dialog_character += delta_time

    if k2.key_went_down(.M) {
        g_music_muted = !g_music_muted
        if g_music_muted {
            k2.set_audio_stream_volume(g_world.music, 0.0)
        } else {
            k2.set_audio_stream_volume(g_world.music, 1.0)
        }
    }
    k2.update_audio_stream(g_world.music)

    // Update effects
    it := hm.iterator_make(&g_world.effects)
    for effect, _ in hm.iterate(&it) {
        update_effect(effect, delta_time)
    }

    if len(g_world.dialog) != 0 {
        // Advance dialog when pressing a key
        if k2.key_went_down(.Z) || k2.key_went_down(.Enter) || k2.key_went_down(.Space) {
            g_world.time_since_last_input = 0.0
            if g_world.dialog_shown_length != len(g_world.dialog_shown_line) {
                // Skip to end of line
                g_world.dialog_shown_length = len(g_world.dialog_shown_line)
            } else if len(g_world.dialog_shown_line) >= len(g_world.dialog) - 1 {
                // End dialog
                show_dialog("")
            } else {
                // Go to next line
                g_world.dialog = g_world.dialog[len(g_world.dialog_shown_line) + 1:]
                g_world.dialog_shown_line, _, _ = strings.partition(g_world.dialog, "\n")
                g_world.dialog_shown_length = 0
            }
        }
    } else if (k2.key_went_down(.U) || k2.key_went_down(.Backspace)) && len(g_previous_time_steps) > 0 {
        g_world.time_step = pop(&g_previous_time_steps)
        hm.clear(&g_world.effects)
    } else if !g_world.win {
        previous_time_step, err := new_clone(g_world.time_step)
        if err != nil {
            log.errorf("error allocating memory for previous time step: %v", err)
            return false
        }
        defer free(previous_time_step)

        step_time := false

        next_player_type: Maybe(Player_Type)

        // Update entities
        it := hm.iterator_make(&g_world.ents)
        for ent, handle in hm.iterate(&it) {
            if handle == g_world.active_player {
                player_data, is_player := &ent.data.(Player_Data)
                assert(is_player)
                step_time ||= update_player(ent, player_data, delta_time)

                if k2.key_went_down(.E) || k2.key_went_down(.Period) {
                    next_player_type = Player_Type((int(player_data.type) + 1) % len(Player_Type))
                } else if k2.key_went_down(.Q) || k2.key_went_down(.Comma) {
                    next_player_type = Player_Type((int(player_data.type) + len(Player_Type) - 1) % len(Player_Type))
                } 

                g_world.camera.target += (cast([2]f32)(ent.pos * TILE_SIZE) + { TILE_SIZE / 2, TILE_SIZE / 2 } - g_world.camera.target) * 0.5            
                continue
            }
            #partial switch &data in ent.data {
                case Door_Data: update_door(ent, &data)
                case Plate_Data: update_plate(ent, &data)
            }
        }

        // Change player
        if next_player_type != nil {
            it = hm.iterator_make(&g_world.ents)
            for ent, handle in hm.iterate(&it) {
                player_data, is_player := ent.data.(Player_Data)
                if is_player && player_data.type == next_player_type.? {
                    g_world.active_player = handle
                    spawn_arrow(handle)
                    break
                }
            }
        }

        if step_time {
            g_world.time_since_last_input = 0.0
            if len(g_previous_time_steps) == cap(g_previous_time_steps) {
                pop_front(&g_previous_time_steps)
            }
            append(&g_previous_time_steps, previous_time_step^)
        }
    }

    k2.clear(k2.BLACK)
	k2.set_camera(g_world.camera)
    
    if !g_world.win || len(g_world.dialog) != 0 {
        active_player_type := draw_world()
    
        k2.set_camera(k2.Camera{
            zoom = 2,
        })
        draw_hud(active_player_type, delta_time)
    } else {
        k2.set_camera(k2.Camera{
            zoom = 2,
        })
        k2.draw_text("You are a wieinner", { 4, 4}, 64, k2.YELLOW)
    }


    k2.present()

    free_all(context.temp_allocator)

    return true
}

wall_at :: proc(pos: [2]int) -> Wall_Type {
    if pos[0] < 0 || pos[1] < 0 || pos[0] >= g_world.wall_cols || pos[1] >= g_world.wall_rows {
        return .EMPTY
    }
    flat_idx := pos[0] + (pos[1] * g_world.wall_cols)
    return g_world.walls[flat_idx]
}

floor_at :: proc(pos: [2]int) -> int {
    if pos[0] < 0 || pos[1] < 0 || pos[0] >= g_world.floor_cols || pos[1] >= g_world.floor_rows {
        return -1
    }
    flat_idx := pos[0] + (pos[1] * g_world.floor_cols)
    return g_world.floors[flat_idx]
}

set_floor_at :: proc(pos: [2]int, floor_index: int) {
    if pos[0] < 0 || pos[1] < 0 || pos[0] >= g_world.floor_cols || pos[1] >= g_world.floor_rows {
        return
    }
    flat_idx := pos[0] + (pos[1] * g_world.floor_cols)
    g_world.floors[flat_idx] = floor_index
}

iterate_ents_at :: proc(it: ^hm.Static_Handle_Map_Iterator(type_of(g_world.ents)), pos: [2]int, blocking := false) -> (^Entity, Entity_Handle, bool) {
    for ent, handle in hm.iterate(it) {
        if pos.x >= ent.pos.x && pos.y >= ent.pos.y && 
            pos.x < ent.pos.x + ent.size.x && pos.y < ent.pos.y + ent.size.y && 
            .INTERACTABLE in ent.flags 
        {
            #partial switch _ in ent.data {
                case Furniture_Data, Player_Data, Door_Data, Bars_Data:
                    return ent, handle, true
                case:
                    if !blocking {
                        return ent, handle, true
                    }
            }
        }
    }
    return nil, {}, false
}

// Shows dialog on the screen. The memory for the passed string is copied and managed by the dialog arena.
show_dialog :: proc(dialog: string) {
    context.allocator = mem.arena_allocator(&g_world.dialog_arena)
    if dialog == "" {
        mem.arena_free_all(&g_world.dialog_arena)
        g_world.dialog = ""
        g_world.time_since_dialog = 10.0 // Prevent animation from playing
    } else {
        my_dialog, err := strings.clone(dialog)
        if err != nil {
            log.errorf("could not allocate memory for dialog: %v", err)
            return
        }
        g_world.dialog = my_dialog
        g_world.time_since_dialog = 0.0
    }
        
    g_world.dialog_shown_length = 0
    g_world.dialog_shown_line, _, _ = strings.partition(g_world.dialog, "\n")
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

    // Draw walls (using double grid tiling system)
    for y in 0..=g_world.wall_rows {
        for x in 0..=g_world.wall_cols {
            for wall_type in ([?]Wall_Type{.PIT, .SOLID}) {
                neighbors: Wall_Neighbors
                if wall_at({ x - 1, y - 1}) == wall_type {
                    neighbors |= { .TOP_LEFT }
                }
                if wall_at({ x, y - 1}) == wall_type {
                    neighbors |= { .TOP_RIGHT }
                }
                if wall_at({ x, y }) == wall_type {
                    neighbors |= { .BOTTOM_RIGHT }
                }
                if wall_at({ x - 1, y }) == wall_type {
                    neighbors |= { .BOTTOM_LEFT }
                }
                src := Wall_Rects[wall_type][transmute(u8)neighbors]
                // Water animation
                if wall_type == .PIT && math.mod(g_world.time_since_start, 2.0) > 1.0 {
                    src.y += 96
                }
                if neighbors != {} {
                    k2.draw_texture_rect(
                        g_textures[.TILES], 
                        src,
                        { 
                            f32(x * TILE_SIZE) - (TILE_SIZE / 2),
                            f32(y * TILE_SIZE) - (TILE_SIZE / 2)
                        }
                    )
                }
            }
        }
    }

    // Draw entities
    draw_arrow_at: Maybe([2]f32)

    sorted_entities, err := make([dynamic]^Entity, 0, hm.static_len(g_world.ents), context.temp_allocator)
    if err != nil {
        log.errorf("Could not allocate sorted entities for rendering, %v", err)
        return
    }

    {
        it := hm.iterator_make(&g_world.ents)
        for ent, handle in hm.iterate(&it) {
            if .VISIBLE not_in ent.flags do continue
            append(&sorted_entities, ent)
        }
    }

    // Returns the drawing order of the entity based on its type.
    entity_priority :: proc(ent: Entity) -> int {
        switch _ in ent.data {
            case Bars_Data: return 6
            case Venizi_Data: return 5
            case Player_Data: return 5
            case Door_Data: return 4
            case Key_Data: return 3
            case Furniture_Data: return 2
            case Plate_Data: return 1
            case Trigger_Data: return 0
        }
        return 0
    }

    slice.sort_by(sorted_entities[:], proc(a, b: ^Entity) -> bool {
        if a == nil || b == nil do return false
        diff := entity_priority(a^) - entity_priority(b^)
        if diff == 0 {
            return a.handle.idx < b.handle.idx
        }
        return diff < 0
    })

    for ent in sorted_entities {
        // Smoothly animate the position from one step to the next
        // target_sprite_pos := cast([2]f32)(ent.pos * TILE_SIZE)
        // previous_sprite_pos := target_sprite_pos
        // if prev_ent, ok := hm.static_get(&previous_time_step.ents, handle); ok {
        //     previous_sprite_pos = cast([2]f32)(prev_ent.pos * TILE_SIZE)
        // }
        // sprite_pos := target_sprite_pos
        // if target_sprite_pos != previous_sprite_pos {
        //     t := min(1.0, g_world.time_since_last_input * 4.0)
        //     sprite_pos = previous_sprite_pos + (target_sprite_pos - previous_sprite_pos) * ease.cubic_out(t)
        // }
        sprite_pos := cast([2]f32)(ent.pos * TILE_SIZE)

        switch data in ent.data {
            case Player_Data: {
                if ent.handle == g_world.active_player {
                    active_player_type = data.type
                }
                if data.type == .MUJI && data.active_type != .MUJI {
                    k2.draw_texture_rect(
                        g_textures[.CHARACTERS], 
                        Muji_Disguise_Rects[data.active_type],
                        sprite_pos, 
                    )
                } else {
                    k2.draw_texture_rect(
                        g_textures[.CHARACTERS], 
                        Player_Rects[data.type],
                        sprite_pos, 
                    )
                }
            }
            case Door_Data: {
                src := k2.Rect{
                    x = 192, y = 0,
                    w = TILE_SIZE, h = TILE_SIZE,
                }
                if ent.size.x > 1 {
                    // Big door
                    src.x = 160
                    src.y = 64 + f32(TILE_SIZE * data.plates_pressed)
                    src.w = TILE_SIZE * 3
                } else if wall_at(ent.pos + { -1, 0 }) != .EMPTY && wall_at(ent.pos + { 1, 0 }) != .EMPTY {
                    src.x += TILE_SIZE
                }
                if ent.size.x == 1 && ent.size.y == 1 {
                    if len(data.plates_needed) > 0 {
                        if data.plates_pressed < 4 && data.plates_pressed != len(data.plates_needed) {
                            src.y += 224 + (src.h * f32(data.plates_pressed + (4 - len(data.plates_needed))))
                        } else {
                            break
                        }
                    }
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
                    sprite_pos + { 0, math.sin(g_world.time_since_start * 4.0) * 2 },
                    { -8, -8 },
                )
            }
            case Plate_Data: {
                k2.draw_texture_rect(
                    g_textures[.TILES],
                    {
                        x = 64 if !data.pressed else 96,
                        y = 96,
                        w = TILE_SIZE,
                        h = TILE_SIZE,
                    },
                    sprite_pos
                )
            }
            case Furniture_Data: {
                k2.draw_texture_rect(
                    g_textures[.ITEMS],
                    { x = 64, y = 16, w = TILE_SIZE, h = TILE_SIZE },
                    sprite_pos
                )
            }
            case Bars_Data: {
                src := k2.Rect{
                    x = 160, y = 32, w = TILE_SIZE, h = TILE_SIZE,
                }
                left_pos := ent.pos + { -1, 0 }
                it := hm.iterator_make(&g_world.ents)
                
                is_bar_to_left := false
                for ent_to_left, _ in iterate_ents_at(&it, left_pos, true) {
                    _, is_bar := ent_to_left.data.(Bars_Data)
                    is_bar_to_left ||= is_bar
                }
                if is_bar_to_left || wall_at(left_pos) != .EMPTY {
                    src.x += 32
                }
                k2.draw_texture_rect(
                    g_textures[.TILES],
                    src,
                    sprite_pos,
                )
            }
            case Trigger_Data: {
                //Nothing
            }
            case Venizi_Data: {
                k2.draw_texture_rect(
                    g_textures[.CHARACTERS], 
                    { x = 128, y = 0, w = 32, h = 32 },
                    sprite_pos, 
                )
            }
        }
    }

    // Draw effects
    {
        it := hm.iterator_make(&g_world.effects)
        for effect, _ in hm.iterate(&it) {
            draw_effect(effect^)
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

draw_hud :: proc(active_player_type: Player_Type, delta_time: f32) {

    k2.draw_texture_rect(g_textures[.CHARACTERS], Player_Name_Rects[.English][active_player_type], { 4, 4 })

    // Draw inventory
    for handle, i in g_world.inventories[active_player_type] {
        // Draw slot background
        slot_pos := [2]f32{ 4, 40 + f32(i * 32) }
        k2.draw_texture_rect(g_textures[.ITEMS], { 32, 16, 32, 32 }, slot_pos)

        if item_ent, present := hm.static_get(&g_world.ents, handle); present {
            #partial switch data in item_ent.data {
                case Key_Data: {
                    rect: k2.Rect = { x = 0, w = 32, h = 32 }
                    switch item_ent.name {
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

    // Draw text boxes
    TRANSITION_TIME :: 0.25
    CHARACTER_SPEED :: 0.025
    DIALOG_HEIGHT :: 64
    if len(g_world.dialog) != 0 {
        bg_y := SCREEN_HEIGHT - min(g_world.time_since_dialog, TRANSITION_TIME) * (1 / TRANSITION_TIME) * DIALOG_HEIGHT
        k2.draw_rect(k2.Rect{ x = 0, y = bg_y, w = SCREEN_WIDTH, h = DIALOG_HEIGHT }, k2.BLACK)
        k2.draw_rect(k2.Rect{ x= 0, y = bg_y + 1, w = SCREEN_WIDTH, h = 1}, k2.WHITE)
        if g_world.time_since_dialog > TRANSITION_TIME {
            portrait_rect: k2.Rect
            for tag, player_type in Player_Dialog_Tags {
                if strings.starts_with(g_world.dialog_shown_line, tag) {
                    portrait_rect = Player_Portrait_Rects[player_type]
                    break
                }
            }
            if strings.starts_with(g_world.dialog_shown_line, "Count Venizi:") {
                portrait_rect = k2.Rect{ x = 96, y = 32, w = 64, h = 64 }
            }

            if g_world.time_since_dialog_character > CHARACTER_SPEED {
                g_world.time_since_dialog_character = 0.0
                g_world.dialog_shown_length = min(g_world.dialog_shown_length + 1, len(g_world.dialog_shown_line))
            }
            if g_world.dialog_shown_length == len(g_world.dialog_shown_line) {
                if math.mod(g_world.time_since_dialog, 0.5) > 0.25 {
                    k2.draw_texture_rect(
                        g_textures[.CHARACTERS], 
                        {x = 160, y = 0, w = 16, h = 16}, 
                        { SCREEN_WIDTH - 16 - 4, SCREEN_HEIGHT - 16 - 4 },
                    )
                }
            } else if !k2.sound_is_playing(g_sounds[.TYPE]) {
                k2.set_sound_pitch(g_sounds[.TYPE], rand.float32_range(0.9, 1.1))
                k2.set_sound_volume(g_sounds[.TYPE], rand.float32_range(0.5, 1.5))
                k2.play_sound(g_sounds[.TYPE])
            }

            if portrait_rect.w > 0 {
                k2.draw_texture_rect(g_textures[.CHARACTERS], portrait_rect, { 0, bg_y })
            }

            k2.draw_text(
                g_world.dialog_shown_line[:g_world.dialog_shown_length], 
                { 4 + (portrait_rect.w * 1.2), bg_y + 4 }, 
                16, 
                k2.WHITE,
            )
        }
    } else if g_world.time_since_dialog < TRANSITION_TIME {
        bg_y := SCREEN_HEIGHT - DIALOG_HEIGHT + min(g_world.time_since_dialog, TRANSITION_TIME) * (1 / TRANSITION_TIME) * DIALOG_HEIGHT
        k2.draw_rect(k2.Rect{ x = 0, y = bg_y, w = SCREEN_WIDTH, h = DIALOG_HEIGHT }, k2.BLACK)
        k2.draw_rect(k2.Rect{ x= 0, y = bg_y + 1, w = SCREEN_WIDTH, h = 1}, k2.WHITE)
    }

    // Draw instructions
    @(static) instructions_a := f32(0.0)
    instructions := g_textures[.INSTRUCTIONS_EN]
    if g_world.time_since_last_input > 5.0 {
        instructions_a = min(1.0, instructions_a + delta_time)
    } else {
        instructions_a = max(0, instructions_a - delta_time)
    }
    if instructions_a > 0.0 {
        k2.draw_texture(instructions, {SCREEN_WIDTH - f32(instructions.width), 0}, {}, 0, k2.color_alpha(k2.WHITE, u8(instructions_a * 255)))
    }
}

shutdown :: proc() {
    unload_assets()
    k2.shutdown()
    delete(g_world_memory)
}