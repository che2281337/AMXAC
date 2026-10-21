// AMXAC: sound ESP protection (requires ReAPI 5.26.3+).
//
// Anti-wallhack stops sending hidden enemies, but their sounds still arrive
// with the player's entity index and exact origin, so sound ESP and sound
// radars keep drawing them. Here every sound a player makes is re-sent per
// listener:
//
//   - the player himself, teammates, the dead/spectators, HLTV, and enemies
//     the player was sent to last frame (antiwh/WHBlocker decided they see
//     him): the original sound, unchanged;
//   - enemies who don't see him: the same sample from the world entity (no
//     player index), moved along the same direction to a fixed distance with
//     the volume recomputed so it sounds the same. The direction and loudness
//     a human uses are kept; the exact position a cheat draws is gone.
//
// Gunshots travel as events (PlaybackEvent) carrying the shooter's index and
// origin. Enemies who see neither the shooter nor the impact point don't get
// the event; they get the gunshot sound the same way as above.
//
// Ideas from UNREAL ANTI-ESP by Karaulov.
//
// Works on top of amxac_antiwh (or WHBlocker): "sees him" is whatever the
// anti-wallhack sent to that player.

#include <amxmodx>
#include <fakemeta>
#include <reapi>
#include <amxac>

#define PLUGIN  "AMXAC Anti-ESP"
#define AUTHOR  "AMXAC"

#define NOMINAL_CLIP_DIST   1000.0
#define MIN_VOLUME          0.001
#define GROUP_OP_AND        0

new bool:g_listener[MAX_PLAYERS + 1];   // a real client that receives sounds (HLTV included)
new bool:g_hltv[MAX_PLAYERS + 1];
new bool:g_inHook;                      // our own re-sends must not be processed again

new c_enabled, Float:c_fakeDist, c_teammates, c_events;

// Gun events: precache name -> event index, sound and attenuation as the CS
// client plays them. [1] is the silenced variant (m4a1, usp).
enum _:GunEvent { GE_NAME[24], GE_SOUND[32], GE_SOUND_ALT[32], Float:GE_ATTN, Float:GE_ATTN_ALT };
new const g_guns[][GunEvent] =
{
	{ "events/ak47.sc",        "weapons/ak47-1.wav",       "weapons/ak47-1.wav",      0.4,  0.4  },
	{ "events/aug.sc",         "weapons/aug-1.wav",        "weapons/aug-1.wav",       0.48, 0.48 },
	{ "events/awp.sc",         "weapons/awp1.wav",         "weapons/awp1.wav",        0.28, 0.28 },
	{ "events/deagle.sc",      "weapons/deagle-1.wav",     "weapons/deagle-1.wav",    0.6,  0.6  },
	{ "events/elite_left.sc",  "weapons/elite_fire.wav",   "weapons/elite_fire.wav",  0.8,  0.8  },
	{ "events/elite_right.sc", "weapons/elite_fire.wav",   "weapons/elite_fire.wav",  0.8,  0.8  },
	{ "events/famas.sc",       "weapons/famas-1.wav",      "weapons/famas-1.wav",     0.48, 0.48 },
	{ "events/fiveseven.sc",   "weapons/fiveseven-1.wav",  "weapons/fiveseven-1.wav", 0.8,  0.8  },
	{ "events/g3sg1.sc",       "weapons/g3sg1-1.wav",      "weapons/g3sg1-1.wav",     0.4,  0.4  },
	{ "events/galil.sc",       "weapons/galil-1.wav",      "weapons/galil-1.wav",     0.4,  0.4  },
	{ "events/glock18.sc",     "weapons/glock18-2.wav",    "weapons/glock18-2.wav",   0.8,  0.8  },
	{ "events/mac10.sc",       "weapons/mac10-1.wav",      "weapons/mac10-1.wav",     0.72, 0.72 },
	{ "events/m249.sc",        "weapons/m249-1.wav",       "weapons/m249-1.wav",      0.52, 0.52 },
	{ "events/m3.sc",          "weapons/m3-1.wav",         "weapons/m3-1.wav",        0.48, 0.48 },
	{ "events/m4a1.sc",        "weapons/m4a1_unsil-1.wav", "weapons/m4a1-1.wav",      0.52, 1.4  },
	{ "events/mp5n.sc",        "weapons/mp5-1.wav",        "weapons/mp5-1.wav",       0.64, 0.64 },
	{ "events/p228.sc",        "weapons/p228-1.wav",       "weapons/p228-1.wav",      0.8,  0.8  },
	{ "events/p90.sc",         "weapons/p90-1.wav",        "weapons/p90-1.wav",       0.64, 0.64 },
	{ "events/scout.sc",       "weapons/scout_fire-1.wav", "weapons/scout_fire-1.wav",1.6,  1.6  },
	{ "events/sg550.sc",       "weapons/sg550-1.wav",      "weapons/sg550-1.wav",     0.4,  0.4  },
	{ "events/sg552.sc",       "weapons/sg552-1.wav",      "weapons/sg552-1.wav",     0.4,  0.4  },
	{ "events/tmp.sc",         "weapons/tmp-1.wav",        "weapons/tmp-1.wav",       1.6,  1.6  },
	{ "events/ump45.sc",       "weapons/ump45-1.wav",      "weapons/ump45-1.wav",     0.64, 0.64 },
	{ "events/usp.sc",         "weapons/usp_unsil-1.wav",  "weapons/usp1.wav",        0.52, 1.4  },
	{ "events/xm1014.sc",      "weapons/xm1014-1.wav",     "weapons/xm1014-1.wav",    0.52, 0.52 }
};
new g_gunEventId[sizeof g_guns];
new g_fwPrecacheEvent;

public plugin_precache()
{
	for (new i = 0; i < sizeof g_guns; i++)
	{
		precache_sound(g_guns[i][GE_SOUND]);
		precache_sound(g_guns[i][GE_SOUND_ALT]);
	}
	g_fwPrecacheEvent = register_forward(FM_PrecacheEvent, "fw_PrecacheEvent_Post", 1);
}

public fw_PrecacheEvent_Post(type, const name[])
{
	for (new i = 0; i < sizeof g_guns; i++)
		if (equal(name, g_guns[i][GE_NAME]))
			g_gunEventId[i] = get_orig_retval();
	return FMRES_IGNORED;
}

public plugin_init()
{
	register_plugin(PLUGIN, AMXAC_VERSION, AUTHOR);
	amxac_register_module("antiesp", AMXAC_VERSION, AUTHOR);
	unregister_forward(FM_PrecacheEvent, g_fwPrecacheEvent, 1);

	bind_pcvar_num(create_cvar("amxac_esp_enabled", "1", _, "Fake the position of sounds of enemies the listener can't see"), c_enabled);
	bind_pcvar_float(create_cvar("amxac_esp_fake_dist", "250", _, "Hidden enemies' sounds are moved to this distance from the listener, units"), c_fakeDist);
	bind_pcvar_num(create_cvar("amxac_esp_teammates", "0", _, "Also fake teammates' sounds"), c_teammates);
	bind_pcvar_num(create_cvar("amxac_esp_events", "1", _, "Hide gunshot events from enemies who can't see the shooter"), c_events);

	RegisterHookChain(RH_SV_StartSound, "RH_SV_StartSound_Pre", false);
	register_forward(FM_PlaybackEvent, "fw_PlaybackEvent");
}

public client_putinserver(id)
{
	g_hltv[id] = bool:is_user_hltv(id);
	g_listener[id] = !is_user_bot(id) || g_hltv[id];
}

public client_disconnected(id)
{
	g_listener[id] = false;
	g_hltv[id] = false;
}

// Does `listener` get the original data about `source`?
bool:gets_original(listener, source)
{
	if (listener == source || !is_user_alive(listener) || !is_user_alive(source))
		return true;
	if (!c_teammates && get_user_team(listener) == get_user_team(source))
		return true;
	// Sent by the anti-wallhack last frame = he can see him.
	return rh_is_entity_fullpacked(listener, source);
}

// ---------------------------------------------------------------------------
// Sounds made by players
// ---------------------------------------------------------------------------

public RH_SV_StartSound_Pre(const recipients, const entity, const channel, const sample[], const volume, Float:attenuation, const fFlags, const pitch)
{
	if (g_inHook || !c_enabled || !(1 <= entity <= MaxClients) || !is_user_connected(entity))
		return HC_CONTINUE;
	// Stop / change requests refer to a sound already playing on the player's
	// entity; leave them alone.
	if (fFlags & (SND_STOP | SND_CHANGE_VOL | SND_CHANGE_PITCH))
		return HC_CONTINUE;

	new Float:origin[3];
	get_entvar(entity, var_origin, origin);
	new Float:vol = float(volume) / 255.0;

	g_inHook = true;
	for (new l = 1; l <= MaxClients; l++)
	{
		if (!g_listener[l])
			continue;
		// recipients != 0: the source predicts this sound himself (footsteps).
		if (l == entity && recipients != 0)
			continue;
		// HLTV records everything, as before.
		if (g_hltv[l])
		{
			rh_emit_sound2(entity, l, channel, sample, vol, attenuation, fFlags, pitch, SND_EMIT2_NOPAS);
			continue;
		}
		// The engine only sends sounds into the listener's audible set.
		if (!CheckVisibilityInOrigin(l, origin, VisibilityInPAS))
			continue;

		if (gets_original(l, entity))
			rh_emit_sound2(entity, l, channel, sample, vol, attenuation, fFlags, pitch, SND_EMIT2_NOPAS);
		else
			emit_faked(l, sample, vol, attenuation, fFlags, pitch, origin);
	}
	g_inHook = false;
	return HC_SUPERCEDE;
}

// Same sample from the world, at c_fakeDist along the same direction, with the
// volume the client would have heard at the real distance.
emit_faked(listener, const sample[], Float:vol, Float:attn, flags, pitch, const Float:origin[3])
{
	new Float:ear[3], Float:dir[3];
	get_entvar(listener, var_origin, ear);
	dir[0] = origin[0] - ear[0];
	dir[1] = origin[1] - ear[1];
	dir[2] = origin[2] - ear[2];
	new Float:dist = floatsqroot(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);

	new Float:pos[3];
	new Float:newVol = vol;
	if (dist <= c_fakeDist || attn <= 0.0)
	{
		pos = origin;   // close enough that the exact spot tells nothing new
	}
	else
	{
		new Float:k = attn / NOMINAL_CLIP_DIST;
		new Float:heard = vol * (1.0 - dist * k);
		if (heard <= MIN_VOLUME)
			return;   // the client wouldn't hear it anyway
		newVol = floatmin(heard / (1.0 - c_fakeDist * k), vol);

		new Float:s = c_fakeDist / dist;
		pos[0] = ear[0] + dir[0] * s;
		pos[1] = ear[1] + dir[1] * s;
		pos[2] = ear[2] + dir[2] * s;
	}

	// Entity 0 (world) carries no player index; CHAN_STATIC so overlapping
	// sounds of different players don't cut each other off.
	rh_emit_sound2(0, listener, CHAN_STATIC, sample, newVol, attn, flags, pitch, SND_EMIT2_NOPAS, pos);
}

// ---------------------------------------------------------------------------
// Gunshot events
// ---------------------------------------------------------------------------

public fw_PlaybackEvent(flags, invoker, eventid, Float:delay, Float:origin[3], Float:angles[3], Float:fparam1, Float:fparam2, iparam1, iparam2, bparam1, bparam2)
{
	if (!c_enabled || !c_events || !(1 <= invoker <= MaxClients) || (flags & FEV_HOSTONLY) || !is_user_alive(invoker))
		return FMRES_IGNORED;

	new gun = -1;
	for (new i = 0; i < sizeof g_guns; i++)
	{
		if (g_gunEventId[i] && g_gunEventId[i] == eventid)
		{
			gun = i;
			break;
		}
	}
	if (gun < 0)
		return FMRES_IGNORED;

	new Float:impact[3];
	aim_end(invoker, impact);

	new Float:shooter[3];
	get_entvar(invoker, var_origin, shooter);

	// Who gets the event: groupinfo 1, who doesn't: 2. With GROUP_OP_AND the
	// engine skips clients whose groupinfo shares no bit with the invoker's.
	new oldGroup[MAX_PLAYERS + 1];
	new bool:anyHidden = false;
	for (new p = 1; p <= MaxClients; p++)
	{
		if (!is_user_connected(p))
			continue;
		oldGroup[p] = get_entvar(p, var_groupinfo);

		new bool:sees = p == invoker || !g_listener[p] || g_hltv[p] || gets_original(p, invoker) || CheckVisibilityInOrigin(p, impact, VisibilityInPVS);
		set_entvar(p, var_groupinfo, sees ? 1 : 2);
		if (!sees)
			anyHidden = true;
	}

	if (!anyHidden)
	{
		for (new p = 1; p <= MaxClients; p++)
			if (is_user_connected(p))
				set_entvar(p, var_groupinfo, oldGroup[p]);
		return FMRES_IGNORED;
	}

	engfunc(EngFunc_SetGroupMask, 0, GROUP_OP_AND);
	engfunc(EngFunc_PlaybackEvent, flags, invoker, eventid, delay, origin, angles, fparam1, fparam2, iparam1, iparam2, bparam1, bparam2);

	// The ones left out still hear the shot, just not where exactly it was.
	new bool:silenced = (gun == 14 && (bparam1 & 1)) || (gun == 23 && (bparam2 & 1));
	new sound[32];
	if (silenced)
		copy(sound, charsmax(sound), g_guns[gun][GE_SOUND_ALT]);
	else
		copy(sound, charsmax(sound), g_guns[gun][GE_SOUND]);
	new Float:attn = silenced ? g_guns[gun][GE_ATTN_ALT] : g_guns[gun][GE_ATTN];
	for (new p = 1; p <= MaxClients; p++)
	{
		if (!is_user_connected(p))
			continue;
		if (get_entvar(p, var_groupinfo) == 2 && CheckVisibilityInOrigin(p, shooter, VisibilityInPAS))
			emit_faked(p, sound, VOL_NORM, attn, 0, 94 + random(16), shooter);
		set_entvar(p, var_groupinfo, oldGroup[p]);
	}
	return FMRES_SUPERCEDE;
}

aim_end(id, Float:out[3])
{
	new Float:start[3], Float:ofs[3], Float:ang[3], Float:dir[3], Float:end[3];
	get_entvar(id, var_origin, start);
	get_entvar(id, var_view_ofs, ofs);
	start[0] += ofs[0]; start[1] += ofs[1]; start[2] += ofs[2];
	get_entvar(id, var_v_angle, ang);
	angle_vector(ang, ANGLEVECTOR_FORWARD, dir);
	end[0] = start[0] + dir[0] * 4096.0;
	end[1] = start[1] + dir[1] * 4096.0;
	end[2] = start[2] + dir[2] * 4096.0;
	engfunc(EngFunc_TraceLine, start, end, DONT_IGNORE_MONSTERS, id, 0);
	get_tr2(0, TR_vecEndPos, out);
}
