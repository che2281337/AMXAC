// AMXAC - helpers for detectors that hook weapons and do vector math.
// Kept apart from amxac.inc because it pulls in fakemeta and hamsandwich.

#if defined _amxac_util_included
	#endinput
#endif
#define _amxac_util_included

#include <fakemeta>
#include <hamsandwich>
#include <amxac>

const AMXAC_XO_WEAPON  = 4;
const AMXAC_XO_PLAYER  = 5;
const AMXAC_m_iId      = 43;
const AMXAC_m_iClip    = 51;

// Registers a Ham hook on every weapon that fires (no grenades, no C4).
stock amxac_hook_weapons(Ham:function, const callback[], post = 0, bool:with_knife = true)
{
	new name[32];
	for (new wid = CSW_P228; wid <= CSW_P90; wid++)
	{
		if (wid == CSW_HEGRENADE || wid == CSW_SMOKEGRENADE || wid == CSW_FLASHBANG || wid == CSW_C4)
			continue;
		if (!with_knife && wid == CSW_KNIFE)
			continue;
		if (get_weaponname(wid, name, charsmax(name)))
			RegisterHam(function, name, callback, post);
	}
}

// Registers a Ham hook on the listed weapon ids only.
stock amxac_hook_weapon_ids(Ham:function, const callback[], post, const ids[], count)
{
	new name[32];
	for (new i = 0; i < count; i++)
	{
		if (get_weaponname(ids[i], name, charsmax(name)))
			RegisterHam(function, name, callback, post);
	}
}

stock amxac_weapon_id(weapon)
{
	return get_pdata_int(weapon, AMXAC_m_iId, AMXAC_XO_WEAPON);
}

stock amxac_weapon_clip(weapon)
{
	return get_pdata_int(weapon, AMXAC_m_iClip, AMXAC_XO_WEAPON);
}

// Owner of a weapon entity if it is a player, else 0.
stock amxac_weapon_owner(weapon)
{
	new id = pev(weapon, pev_owner);
	return (1 <= id <= MaxClients) ? id : 0;
}

stock amxac_eye_pos(id, Float:out[3])
{
	new Float:ofs[3];
	pev(id, pev_origin, out);
	pev(id, pev_view_ofs, ofs);
	out[0] += ofs[0];
	out[1] += ofs[1];
	out[2] += ofs[2];
}

// Direction vector -> view angles in usercmd convention (positive pitch looks down).
stock amxac_dir_to_view(const Float:dir[3], Float:out[3])
{
	vector_to_angle(dir, out);
	out[0] = -out[0];
	out[1] = amxac_wrap180(out[1]);
}

// View angles a player at `from` needs to look exactly at `to`.
stock amxac_view_to(const Float:from[3], const Float:to[3], Float:out[3])
{
	new Float:dir[3];
	dir[0] = to[0] - from[0];
	dir[1] = to[1] - from[1];
	dir[2] = to[2] - from[2];
	amxac_dir_to_view(dir, out);
}

// Point halfway between two view angles, handling the wrap of both components.
stock amxac_angle_mid(const Float:a[], const Float:b[], Float:out[])
{
	out[0] = amxac_wrap180(a[0] + amxac_wrap180(b[0] - a[0]) * 0.5);
	out[1] = amxac_wrap180(a[1] + amxac_wrap180(b[1] - a[1]) * 0.5);
}

stock bool:amxac_is_enemy(a, b)
{
	return get_user_team(a) != get_user_team(b);
}

stock bool:amxac_on_ladder_or_water(id)
{
	return pev(id, pev_movetype) == MOVETYPE_FLY || pev(id, pev_waterlevel) >= 2;
}

// Rising edge of a button between two button masks.
stock bool:amxac_pressed(buttons, prev, mask)
{
	return (buttons & mask) && !(prev & mask);
}
