// AMXAC module: anti-wallhack (prevention).
//
// The engine sends every player in the PVS to every client, so ESP can draw
// enemies behind walls. Here AddToFullPack drops enemies the receiving player
// cannot see. ESP, radar hacks and most "sound ESP" lose their data.
//
// Visibility = a trace from the viewer's eye reaches one of several points on
// the target, either now or with both extrapolated by the viewer's ping. Only
// world geometry blocks: hitting a brush entity (door, glass, fence) counts as
// visible, so nothing that could be seen through ever disappears.
//
// Cost control (this is the most expensive module by far):
//  - AddToFullPack runs for every entity in every client's PVS; the non-player
//    case returns on the first line.
//  - Alive/team/bot state and ping are cached, not queried per call.
//  - Each pair is rechecked every amxac_awh_interval, and a seen target stays
//    visible for amxac_awh_grace.
//  - Traces are paid from a global budget (amxac_awh_traces per second). When it
//    runs dry, overdue pairs fail open (shown), so gameplay never breaks;
//    protection just gets coarser under load.
//
// Anti no-flash: while a player's screen is fully white (hold phase of a
// flashbang), enemies aren't sent at all. No traces needed, and a no-flash
// cheat shows an empty map instead of targets. The player's own white screen
// is left alone.

#include <amxmodx>
#include <amxmisc>
#include <amxac_util>

#define PLUGIN  "AMXAC Anti-WH"
#define AUTHOR  "AMXAC"

#define TASK_REFRESH    96000

new g_tr;

new bool:g_alive[MAX_PLAYERS + 1];
new bool:g_bot[MAX_PLAYERS + 1];
new g_team[MAX_PLAYERS + 1];
new Float:g_latency[MAX_PLAYERS + 1];
new Float:g_blindUntil[MAX_PLAYERS + 1];

new Float:g_nextCheck[MAX_PLAYERS + 1][MAX_PLAYERS + 1];
new Float:g_lastSeen[MAX_PLAYERS + 1][MAX_PLAYERS + 1];

new Float:g_budget;
new Float:g_budgetTime;
new g_tracesUsed, g_failOpen;   // stats since the last amx_awh_stats

new c_enabled, Float:c_interval, Float:c_grace, Float:c_maxLatency, c_teammates, Float:c_traces, c_flash;

public plugin_init()
{
	register_plugin(PLUGIN, AMXAC_VERSION, AUTHOR);
	amxac_register_module("antiwh", AMXAC_VERSION, AUTHOR);

	bind_pcvar_num(create_cvar("amxac_awh_enabled", "1", _, "Hide enemies the player cannot see"), c_enabled);
	bind_pcvar_float(create_cvar("amxac_awh_interval", "0.1", _, "Seconds between visibility checks per pair"), c_interval);
	bind_pcvar_float(create_cvar("amxac_awh_grace", "0.3", _, "Keep a target visible this long after it was last seen"), c_grace);
	bind_pcvar_float(create_cvar("amxac_awh_max_latency", "0.25", _, "Cap for ping extrapolation, seconds"), c_maxLatency);
	bind_pcvar_num(create_cvar("amxac_awh_teammates", "0", _, "Also hide teammates"), c_teammates);
	bind_pcvar_float(create_cvar("amxac_awh_traces", "20000", _, "Trace budget per second for the whole server"), c_traces);
	bind_pcvar_num(create_cvar("amxac_awh_flash", "1", _, "Hide enemies from fully flashed players (anti no-flash)"), c_flash);
	register_event("ScreenFade", "ev_ScreenFade", "b", "7=255");

	g_tr = create_tr2();
	register_forward(FM_AddToFullPack, "fw_AddToFullPack", 0);
	RegisterHam(Ham_Spawn, "player", "fw_Spawn_Post", 1);
	RegisterHam(Ham_Killed, "player", "fw_Killed_Post", 1);
	register_concmd("amx_awh_stats", "cmd_stats", ADMIN_KICK, "- anti-wallhack trace usage");

	set_task(1.0, "task_refresh", TASK_REFRESH, _, _, "b");
}

public plugin_end()
{
	free_tr2(g_tr);
}

public task_refresh()
{
	new ping, loss;
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_connected(id))
			continue;
		g_alive[id] = bool:is_user_alive(id);
		g_team[id] = get_user_team(id);
		get_user_ping(id, ping, loss);
		g_latency[id] = floatmin(float(ping) / 1000.0, c_maxLatency);
	}
}

public client_putinserver(id)
{
	g_alive[id] = false;
	g_bot[id] = bool:is_user_bot(id);
	g_latency[id] = 0.0;
	g_blindUntil[id] = 0.0;
	for (new i = 1; i <= MaxClients; i++)
	{
		g_nextCheck[id][i] = g_nextCheck[i][id] = 0.0;
		g_lastSeen[id][i] = g_lastSeen[i][id] = 0.0;
	}
}

public client_disconnected(id)
{
	g_alive[id] = false;
}

public fw_Spawn_Post(id)
{
	if (is_user_alive(id))
	{
		g_alive[id] = true;
		g_team[id] = get_user_team(id);
	}
}

public fw_Killed_Post(victim, killer, gib)
{
	g_alive[victim] = false;
	g_blindUntil[victim] = 0.0;
}

// Full-alpha fade: arg 2 is the hold time in 1/4096 s. Only the hold phase is
// solid white; the fade-out after it is see-through.
public ev_ScreenFade(id)
{
	new Float:hold = float(read_data(2)) / 4096.0;
	g_blindUntil[id] = hold > 0.0 ? get_gametime() + hold : 0.0;
}

public cmd_stats(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	console_print(id, "[AC] anti-wh: %d traces, %d fail-open checks since last call (budget %.0f/s)", g_tracesUsed, g_failOpen, c_traces);
	g_tracesUsed = g_failOpen = 0;
	return PLUGIN_HANDLED;
}

public fw_AddToFullPack(es, e, ent, host, hostflags, player, pSet)
{
	if (!player)
		return FMRES_IGNORED;
	// Bots get no packets; spectators and the dead see everything.
	if (ent == host || g_bot[host] || !g_alive[host] || !g_alive[ent])
		return FMRES_IGNORED;

	new Float:now = get_gametime();
	new bool:enemy = g_team[host] != g_team[ent];

	if (c_flash && enemy && now < g_blindUntil[host])
	{
		forward_return(FMRES_IGNORED, 0);
		return FMRES_SUPERCEDE;
	}

	if (!c_enabled || (!c_teammates && !enemy))
		return FMRES_IGNORED;

	if (now >= g_nextCheck[host][ent])
	{
		refill_budget(now);
		if (g_budget >= 1.0)
		{
			g_nextCheck[host][ent] = now + c_interval;
			if (can_see(host, ent))
				g_lastSeen[host][ent] = now;
		}
		else if (now - g_nextCheck[host][ent] > c_interval)
		{
			// Overdue and no budget left: show rather than risk hiding a visible enemy.
			g_lastSeen[host][ent] = now;
			g_failOpen++;
		}
	}

	if (now - g_lastSeen[host][ent] <= c_grace)
		return FMRES_IGNORED;

	forward_return(FMRES_IGNORED, 0);
	return FMRES_SUPERCEDE;
}

refill_budget(Float:now)
{
	if (now == g_budgetTime)
		return;
	g_budget = floatmin(g_budget + (now - g_budgetTime) * c_traces, c_traces * 0.05);
	g_budgetTime = now;
}

bool:can_see(host, target)
{
	new Float:eye[3], Float:org[3];
	amxac_eye_pos(host, eye);
	pev(target, pev_origin, org);

	if (sees_body(host, eye, org))
		return true;

	// Extrapolate both by the viewer's ping so targets don't pop in at corners.
	new Float:lat = g_latency[host];
	if (lat <= 0.0)
		return false;

	new Float:hv[3], Float:tv[3];
	pev(host, pev_velocity, hv);
	pev(target, pev_velocity, tv);

	// Barely moving: extrapolation wouldn't change anything.
	new Float:move2 = (hv[0] * hv[0] + hv[1] * hv[1] + tv[0] * tv[0] + tv[1] * tv[1]) * lat * lat;
	if (move2 < 8.0 * 8.0)
		return false;

	for (new i = 0; i < 3; i++)
	{
		eye[i] += hv[i] * lat;
		org[i] += tv[i] * lat;
	}
	return sees_body(host, eye, org);
}

// Head, center, both sides, feet: ordered by how often they're the visible part.
bool:sees_body(host, const Float:eye[3], const Float:org[3])
{
	new Float:pt[3];

	pt = org; pt[2] += 28.0;
	if (trace_clear(host, eye, pt))
		return true;

	if (trace_clear(host, eye, org))
		return true;

	// Sideways, perpendicular to the line of sight.
	new Float:dx = org[0] - eye[0], Float:dy = org[1] - eye[1];
	new Float:len = floatsqroot(dx * dx + dy * dy);
	if (len < 1.0)
		return true;
	new Float:sx = -dy / len * 16.0, Float:sy = dx / len * 16.0;

	pt = org; pt[0] += sx; pt[1] += sy;
	if (trace_clear(host, eye, pt))
		return true;

	pt = org; pt[0] -= sx; pt[1] -= sy;
	if (trace_clear(host, eye, pt))
		return true;

	pt = org; pt[2] -= 30.0;
	return trace_clear(host, eye, pt);
}

bool:trace_clear(host, const Float:from[3], const Float:to[3])
{
	g_budget -= 1.0;
	g_tracesUsed++;
	engfunc(EngFunc_TraceLine, from, to, IGNORE_MONSTERS, host, g_tr);

	new Float:fraction;
	get_tr2(g_tr, TR_flFraction, fraction);
	if (fraction >= 1.0)
		return true;

	// A brush entity is in the way: could be glass or a fence, assume visible.
	return get_tr2(g_tr, TR_pHit) > 0;
}
