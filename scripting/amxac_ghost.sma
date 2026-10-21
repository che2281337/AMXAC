// AMXAC: ghost admin honeypot (idea from GOD SEEKER by Karaulov).
//
// An admin turns into a ghost: invisible to everyone, can't be hurt, can't
// shoot, makes no weapon or voice sounds, and bullets and players pass through
// him. An honest player has no way to know he's there. ESP still draws him (the
// entity is still sent, only rendered fully transparent) and aimbots still lock
// on him. So, from enemies of the ghost:
//
//   - fresh shots aimed right at him while no real enemy is near the line of
//     fire (so shooting someone standing behind him doesn't count), or
//   - holding the crosshair on him while he moves
//
// is a strong cheat signal, reported to the core as module "honeypot".
// Don't park the ghost on a common angle: people prefire those.
//
// Footsteps are played by the movement code and can't be filtered without
// ReAPI: walk (+speed / Shift) while a ghost, CS plays no steps when walking.
//
//   amx_ac_ghost      toggle ghost mode for yourself (must be alive)

#include <amxmodx>
#include <amxmisc>
#include <amxac_util>

#define PLUGIN  "AMXAC Ghost"
#define AUTHOR  "AMXAC"

new g_mod;
new bool:g_ghost[MAX_PLAYERS + 1];
new g_ghostCount;
new g_msgShadow, g_shadowSprite;
new g_msgStatusValue;

// per watcher: tracking the ghost
new g_trkGhost[MAX_PLAYERS + 1];
new g_trkStart[MAX_PLAYERS + 1];            // watcher client time, ms
new Float:g_trkGhostFrom[MAX_PLAYERS + 1][3];
new Float:g_trkGhostMoved[MAX_PLAYERS + 1];
new g_clientTime[MAX_PLAYERS + 1];

// per shooter: shots aimed at a ghost
new g_shots[MAX_PLAYERS + 1];
new Float:g_shotsSince[MAX_PLAYERS + 1];

new g_tr;

new Float:c_trackFov, c_trackMs, Float:c_trackMove, Float:c_ptsTrack;
new Float:c_shotFov, c_shotsNeed, Float:c_shotsWindow, Float:c_ptsShot;

public plugin_precache()
{
	g_shadowSprite = precache_model("sprites/shadow_circle.spr");
}

public plugin_init()
{
	register_plugin(PLUGIN, AMXAC_VERSION, AUTHOR);
	g_mod = amxac_register_module("honeypot", AMXAC_VERSION, AUTHOR);

	bind_pcvar_float(create_cvar("amxac_ghost_track_fov", "2.5", _, "Crosshair this close to the ghost counts as aiming at him, degrees"), c_trackFov);
	bind_pcvar_num(create_cvar("amxac_ghost_track_ms", "700", _, "Aiming at the ghost this long while he moves to report, ms"), c_trackMs);
	bind_pcvar_float(create_cvar("amxac_ghost_track_move", "64", _, "The ghost must move at least this far during it, units"), c_trackMove);
	bind_pcvar_float(create_cvar("amxac_ghost_track_pts", "20"), c_ptsTrack);
	bind_pcvar_float(create_cvar("amxac_ghost_shot_fov", "1.5", _, "A shot this close to the ghost counts as aimed at him, degrees"), c_shotFov);
	bind_pcvar_num(create_cvar("amxac_ghost_shots_need", "3", _, "Aimed shots at a ghost to report"), c_shotsNeed);
	bind_pcvar_float(create_cvar("amxac_ghost_shots_window", "30", _, "Within this many seconds"), c_shotsWindow);
	bind_pcvar_float(create_cvar("amxac_ghost_shot_pts", "25"), c_ptsShot);

	g_tr = create_tr2();

	register_concmd("amx_ac_ghost", "cmd_ghost", ADMIN_BAN, "- toggle invisible honeypot mode");

	g_msgShadow = get_user_msgid("ShadowIdx");
	g_msgStatusValue = get_user_msgid("StatusValue");
	register_message(g_msgStatusValue, "msg_StatusValue");

	register_forward(FM_AddToFullPack, "fw_AddToFullPack_Post", 1);
	register_forward(FM_EmitSound, "fw_EmitSound");
	register_forward(FM_Voice_SetClientListening, "fw_Voice");
	register_forward(FM_CmdStart, "fw_CmdStart");

	RegisterHam(Ham_Spawn, "player", "fw_Spawn_Post", 1);
	RegisterHam(Ham_Killed, "player", "fw_Killed_Post", 1);
	amxac_hook_weapons(Ham_Weapon_PrimaryAttack, "fw_Primary");
	amxac_hook_weapons(Ham_Weapon_SecondaryAttack, "fw_Attack");
}

public plugin_end()
{
	free_tr2(g_tr);
}

public client_putinserver(id)
{
	g_ghost[id] = false;
	g_trkGhost[id] = 0;
	g_shots[id] = 0;
	g_clientTime[id] = 0;
}

public client_disconnected(id)
{
	if (g_ghost[id])
		set_ghost(id, false);
}

// ---------------------------------------------------------------------------
// Ghost mode
// ---------------------------------------------------------------------------

public cmd_ghost(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1) || !id)
		return PLUGIN_HANDLED;

	if (!g_ghost[id] && !is_user_alive(id))
	{
		console_print(id, "[AC] You have to be alive to become a ghost.");
		return PLUGIN_HANDLED;
	}
	set_ghost(id, !g_ghost[id]);
	return PLUGIN_HANDLED;
}

set_ghost(id, bool:on)
{
	if (g_ghost[id] == on)
		return;
	g_ghost[id] = on;
	g_ghostCount += on ? 1 : -1;

	new name[32];
	get_user_name(id, name, charsmax(name));
	amxac_log("GHOST %s %s", name, on ? "on" : "off");

	if (is_user_connected(id))
	{
		new flags = pev(id, pev_flags);
		if (on)
		{
			set_pev(id, pev_takedamage, DAMAGE_NO);
			set_pev(id, pev_flags, flags | FL_NOTARGET);
			// Not solid: bullets meant for someone behind him must not stop on him.
			set_pev(id, pev_solid, SOLID_NOT);
			client_print_color(id, print_team_red, "^4%s^1 Ghost mode ^4ON^1. Walk with ^3Shift^1 (no footsteps), you can't shoot.", AMXAC_TAG);
		}
		else
		{
			set_pev(id, pev_takedamage, DAMAGE_AIM);
			set_pev(id, pev_flags, flags & ~FL_NOTARGET);
			if (is_user_alive(id))
				set_pev(id, pev_solid, SOLID_SLIDEBOX);
			client_print_color(id, print_team_red, "^4%s^1 Ghost mode ^3OFF^1.", AMXAC_TAG);
		}
	}

	// The client draws a shadow blob under every player, rendered or not.
	message_begin(MSG_ALL, g_msgShadow);
	write_long(g_ghostCount > 0 ? 0 : g_shadowSprite);
	message_end();

	for (new w = 1; w <= MaxClients; w++)
		if (g_trkGhost[w] == id)
			g_trkGhost[w] = 0;
}

public fw_Spawn_Post(id)
{
	if (g_ghost[id] && is_user_alive(id))
		set_ghost(id, false);   // a new round starts visible
}

// A living ghost must not keep a round going for his team.
public fw_Killed_Post(victim, killer, gib)
{
	if (g_ghost[victim])
	{
		set_ghost(victim, false);
		return;
	}
	if (!g_ghostCount)
		return;

	new team = get_user_team(victim);
	for (new i = 1; i <= MaxClients; i++)
		if (i != victim && !g_ghost[i] && is_user_alive(i) && get_user_team(i) == team)
			return;

	for (new g = 1; g <= MaxClients; g++)
	{
		if (g_ghost[g] && get_user_team(g) == team && is_user_alive(g))
		{
			set_ghost(g, false);
			user_silentkill(g);
		}
	}
}

public fw_AddToFullPack_Post(es, e, ent, host, hostflags, player, pSet)
{
	if (!g_ghostCount || ent == host)
		return FMRES_IGNORED;

	new owner = ent;
	if (!player)
	{
		// Things attached to a ghost (shield, backpack) follow his model.
		owner = get_es(es, ES_AimEnt);
		if (!(1 <= owner <= MaxClients) || get_es(es, ES_MoveType) != MOVETYPE_FOLLOW)
			return FMRES_IGNORED;
	}
	if (!(1 <= owner <= MaxClients) || !g_ghost[owner])
		return FMRES_IGNORED;

	// Still sent, so ESP sees him; just drawn fully transparent.
	set_es(es, ES_RenderMode, kRenderTransAlpha);
	set_es(es, ES_RenderAmt, 0);
	set_es(es, ES_RenderFx, kRenderFxNone);
	if (player)
		set_es(es, ES_WeaponModel, 0);
	return FMRES_HANDLED;
}

public fw_EmitSound(ent, channel, const sample[], Float:vol, Float:attn, flags, pitch)
{
	if (g_ghostCount && 1 <= ent <= MaxClients && g_ghost[ent])
		return FMRES_SUPERCEDE;
	return FMRES_IGNORED;
}

public fw_Voice(receiver, sender, bool:listen)
{
	if (!g_ghostCount || !(1 <= sender <= MaxClients) || !g_ghost[sender] || receiver == sender)
		return FMRES_IGNORED;
	engfunc(EngFunc_SetClientListening, receiver, sender, false);
	forward_return(FMV_CELL, false);
	return FMRES_SUPERCEDE;
}

// Secondary attack (knife stab, zoom, silencer): only blocked for the ghost.
public fw_Attack(weapon)
{
	new id = amxac_weapon_owner(weapon);
	return (id && g_ghost[id]) ? HAM_SUPERCEDE : HAM_IGNORED;
}

// Don't show the ghost's name when a crosshair passes over him.
public msg_StatusValue(msgid, dest, id)
{
	if (g_ghostCount && get_msg_arg_int(1) == 2)
	{
		new target = get_msg_arg_int(2);
		if (1 <= target <= MaxClients && g_ghost[target])
			set_msg_arg_int(2, get_msg_argtype(2), 0);
	}
	return PLUGIN_CONTINUE;
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

public fw_Primary(weapon)
{
	new id = amxac_weapon_owner(weapon);
	if (!id)
		return HAM_IGNORED;
	if (g_ghost[id])
		return HAM_SUPERCEDE;
	if (g_ghostCount && amxac_is_monitored(id))
		check_aimed_shot(id, weapon);
	return HAM_IGNORED;
}

// A fresh shot (not the rest of a spray) aimed right at a visible enemy ghost,
// with no real enemy near the line of fire.
check_aimed_shot(id, weapon)
{
	if (!(pev(id, pev_button) & IN_ATTACK) || (pev(id, pev_oldbuttons) & IN_ATTACK))
		return;
	if (amxac_weapon_id(weapon) != CSW_KNIFE && amxac_weapon_clip(weapon) <= 0)
		return;

	new Float:eye[3], Float:aim[3], Float:punch[3], Float:pt[3], Float:want[3];
	amxac_eye_pos(id, eye);
	pev(id, pev_v_angle, aim);
	pev(id, pev_punchangle, punch);
	aim[0] += punch[0];
	aim[1] += punch[1];

	new ghost = 0;
	for (new g = 1; g <= MaxClients; g++)
	{
		if (!g_ghost[g] || !is_user_alive(g) || !amxac_is_enemy(id, g))
			continue;
		if (angle_to_body(eye, aim, g, pt, want) <= c_shotFov && clear_line(id, eye, pt))
		{
			ghost = g;
			break;
		}
	}
	if (!ghost)
		return;

	// Someone real in (or close to) the line of fire: he's the target, not the ghost.
	for (new e = 1; e <= MaxClients; e++)
	{
		if (e == id || g_ghost[e] || !is_user_alive(e) || !amxac_is_enemy(id, e))
			continue;
		if (angle_to_body(eye, aim, e, pt, want) <= c_shotFov * 3.0)
			return;
	}

	new Float:now = get_gametime();
	if (now - g_shotsSince[id] > c_shotsWindow)
	{
		g_shotsSince[id] = now;
		g_shots[id] = 0;
	}

	if (++g_shots[id] >= c_shotsNeed)
	{
		new name[32];
		get_user_name(ghost, name, charsmax(name));
		amxac_report(id, g_mod, c_ptsShot, "%d shots aimed at invisible admin %s in %.0f s", g_shots[id], name, now - g_shotsSince[id]);
		amxac_notify("^4%s^1 ^3honeypot^1: someone keeps shooting at invisible ^4%s^1, see amx_ac_status", AMXAC_TAG, name);
		g_shots[id] = 0;
	}
}

// Smallest angle between the aim and the target's head or body center.
Float:angle_to_body(const Float:eye[3], const Float:aim[3], target, Float:pt[3], Float:want[3])
{
	new Float:best;
	amxac_eye_pos(target, pt);
	amxac_view_to(eye, pt, want);
	best = amxac_angle_dist(aim, want);

	new Float:org[3];
	pev(target, pev_origin, org);
	amxac_view_to(eye, org, want);
	new Float:d = amxac_angle_dist(aim, want);
	if (d < best)
	{
		best = d;
		pt = org;
	}
	return best;
}

bool:clear_line(id, const Float:from[3], const Float:to[3])
{
	engfunc(EngFunc_TraceLine, from, to, IGNORE_MONSTERS, id, g_tr);
	new Float:fraction;
	get_tr2(g_tr, TR_flFraction, fraction);
	return fraction >= 1.0 || get_tr2(g_tr, TR_pHit) > 0;
}

public fw_CmdStart(id, uc, seed)
{
	if (!g_ghostCount)
		return FMRES_IGNORED;

	new now = g_clientTime[id];
	g_clientTime[id] += get_uc(uc, UC_Msec);

	if (g_ghost[id] || !is_user_alive(id) || !amxac_is_monitored(id))
		return FMRES_IGNORED;

	new Float:view[3], Float:eye[3], Float:head[3], Float:want[3];
	get_uc(uc, UC_ViewAngles, view);
	amxac_eye_pos(id, eye);

	// The ghost closest to the crosshair, if any is within the fov.
	new best = 0;
	new Float:bestFov = c_trackFov;
	for (new g = 1; g <= MaxClients; g++)
	{
		if (!g_ghost[g] || !is_user_alive(g) || !amxac_is_enemy(id, g))
			continue;   // aimbots go for enemies only
		amxac_eye_pos(g, head);
		amxac_view_to(eye, head, want);
		new Float:fov = amxac_angle_dist(view, want);
		if (fov < bestFov)
		{
			best = g;
			bestFov = fov;
		}
	}

	if (!best)
	{
		g_trkGhost[id] = 0;
		return FMRES_IGNORED;
	}

	new Float:org[3];
	pev(best, pev_origin, org);

	if (best != g_trkGhost[id])
	{
		g_trkGhost[id] = best;
		g_trkStart[id] = now;
		g_trkGhostFrom[id] = org;
		g_trkGhostMoved[id] = 0.0;
		return FMRES_IGNORED;
	}

	g_trkGhostMoved[id] = floatmax(g_trkGhostMoved[id], get_distance_f(org, g_trkGhostFrom[id]));
	new len = now - g_trkStart[id];

	// Holding a common angle where the ghost happens to stand doesn't count:
	// the crosshair has to follow him while he moves.
	if (len >= c_trackMs && g_trkGhostMoved[id] >= c_trackMove)
	{
		new name[32];
		get_user_name(best, name, charsmax(name));
		amxac_report(id, g_mod, c_ptsTrack, "kept the crosshair on invisible admin %s for %d ms while he moved %.0f units", name, len, g_trkGhostMoved[id]);
		amxac_notify("^4%s^1 ^3honeypot^1: someone is tracking invisible ^4%s^1, see amx_ac_status", AMXAC_TAG, name);
		g_trkGhost[id] = 0;
	}
	return FMRES_IGNORED;
}
