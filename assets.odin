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
}

g_sounds := [Sound_Key]k2.Sound{}

load_assets :: proc() {
	g_textures[.TILES] = k2.load_texture_from_bytes(#load("assets/tiles.png"))
	g_textures[.CHARACTERS] = k2.load_texture_from_bytes(#load("assets/characters.png"))
	g_textures[.ITEMS] = k2.load_texture_from_bytes(#load("assets/items.png"))
	g_sounds[.FOOTSTEP] = k2.load_sound_from_bytes(#load("assets/footstep.wav"))
}

unload_assets :: proc() {
	for tex in g_textures {
		k2.destroy_texture(tex)
	}
	for sound in g_sounds {
		k2.destroy_sound(sound)
	}
}