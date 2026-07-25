package main

import "core:math"
import hm "core:container/handle_map"
import k2 "karl2d"

Effect_Data :: struct {
    handle: Effect_Handle,
	pos: [2]f32,
    time_alive, frame_timer: f32,
    texture: k2.Texture,
    animation: [dynamic; 8]k2.Rect,
    speed: f32,
    bob_speed, bob_amplitude: f32,
    follow_entity: Entity_Handle,
}

Effect_Handle :: hm.Handle32

spawn_smoke :: proc(grid_pos: [2]int) -> Effect_Handle {
    handle, _ := hm.add(&g_world.effects, Effect_Data{
        pos = cast([2]f32)(grid_pos * TILE_SIZE),
        texture = g_textures[.CHARACTERS],
        animation = {
            k2.Rect{ x = 32, y = 32, w = 32, h = 32 },
            k2.Rect{ x = 32, y = 64, w = 32, h = 32 },
            k2.Rect{ x = 32, y = 96, w = 32, h = 32 },
        },
        speed = 0.1,
    })
    return handle
}

spawn_arrow :: proc(follow_target: Entity_Handle) -> Effect_Handle {
    handle, _ := hm.add(&g_world.effects, Effect_Data{
        pos = {8, -16},
        texture = g_textures[.CHARACTERS],
        animation = {
            k2.Rect{x = 160, y = 0, w = 16, h = 16},
        },
        speed = 1.0,
        bob_speed = 4.0,
        bob_amplitude = 2.0,
        follow_entity = follow_target,
    })
    return handle
}

spawn_counter :: proc(follow_target: Entity_Handle, number: int) -> Effect_Handle {
    // Kill other counters attached to the same entity
    it := hm.iterator_make(&g_world.effects)
    for effect, handle in hm.iterate(&it) {
        if effect.follow_entity == follow_target {
            hm.remove(&g_world.effects, handle)
        }
    }
    if number <= 0 || number > 10 do return {}
    handle, _ := hm.add(&g_world.effects, Effect_Data{
        pos = {8, -16},
        texture = g_textures[.CHARACTERS],
        animation = {
            k2.Rect{x = 176, y = 144 - f32((number - 1) * 16), w = 16, h = 16},
        },
        speed = 1.0,
        follow_entity = follow_target,
    })
    return handle
}

update_effect :: proc(effect: ^Effect_Data, delta_time: f32) {
    if effect == nil do return
    
    effect.frame_timer += delta_time
    effect.time_alive += delta_time
    if effect.frame_timer > effect.speed {
        effect.frame_timer = 0.0
        _, ok := pop_front_safe(&effect.animation)
        if !ok {
            hm.remove(&g_world.effects, effect.handle)
            return
        }
    }
}

draw_effect :: proc(effect: Effect_Data) {
    if len(effect.animation) == 0 do return
    sprite_pos := effect.pos
    if follow_ent, ok := hm.get(&g_world.ents, effect.follow_entity); ok {
        sprite_pos += cast([2]f32)(follow_ent.pos * TILE_SIZE)
    }
    bob := [2]f32{0, math.sin(effect.time_alive * effect.bob_speed) * effect.bob_amplitude}
    k2.draw_texture_rect(effect.texture, effect.animation[0], sprite_pos + bob)
}