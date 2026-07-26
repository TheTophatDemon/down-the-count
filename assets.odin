package main

import k2 "karl2d"

Texture_Key :: enum {
	TILES,
	CHARACTERS,
	ITEMS,
}

g_textures := [Texture_Key]k2.Texture{}

Sound_Key :: enum {
	FOOTSTEP,
	KEY,
	LOCKED,
	UNLOCK,
	TYPE,
	SWITCH,
	UNSWITCH,
	PUSH,
	POOF,
	JUMP,
}

g_sounds := [Sound_Key]k2.Sound{}

load_assets :: proc() {
	g_textures[.TILES] = k2.load_texture_from_bytes(#load("assets/tiles.png"))
	g_textures[.CHARACTERS] = k2.load_texture_from_bytes(#load("assets/characters.png"))
	g_textures[.ITEMS] = k2.load_texture_from_bytes(#load("assets/items.png"))
	g_sounds[.FOOTSTEP] = k2.load_sound_from_bytes(#load("assets/footstep.wav"))
	g_sounds[.KEY] = k2.load_sound_from_bytes(#load("assets/key.wav"))
	g_sounds[.LOCKED] = k2.load_sound_from_bytes(#load("assets/locked.wav"))
	g_sounds[.UNLOCK] = k2.load_sound_from_bytes(#load("assets/unlock.wav"))
	g_sounds[.TYPE] = k2.load_sound_from_bytes(#load("assets/type.wav"))
	g_sounds[.SWITCH] = k2.load_sound_from_bytes(#load("assets/switch.wav"))
	g_sounds[.UNSWITCH] = k2.load_sound_from_bytes(#load("assets/unswitch.wav"))
	g_sounds[.PUSH] = k2.load_sound_from_bytes(#load("assets/push.wav"))
	g_sounds[.POOF] = k2.load_sound_from_bytes(#load("assets/poof.wav"))
	g_sounds[.JUMP] = k2.load_sound_from_bytes(#load("assets/jump.wav"))
}

unload_assets :: proc() {
	for tex in g_textures {
		k2.destroy_texture(tex)
	}
	for sound in g_sounds {
		k2.destroy_sound(sound)
	}
}