// AMXAC self-test: makes a player's own usercmds look like a cheat's, so the
// whole pipeline (hook -> detector -> core -> levels -> notify -> action) can be
// checked without touching real cheats.
//
// The usercmd is changed before the game runs it, so the effect is real: shots
// really go where the "cheat" aims, speed really changes. Test server only.
//
// Must be listed in plugins.ini BEFORE amxac_aim / amxac_move: fakemeta calls
// CmdStart hooks in plugin order, and the detectors must see the modified cmd.
//
//   amx_ac_test list [target]     modes and their state
//   amx_ac_test <mode> [target]   toggle a mode (target defaults to yourself)
//   amx_ac_test off [target]      all modes off

#include <amxmodx>
#include <amxmisc>
#include <amxac_util>

#define PLUGIN  "AMXAC Self-Test"
#define AUTHOR  "AMXAC"

const SEMI_PISTOLS = (1 << CSW_USP) | (1 << CSW_GLOCK18) | (1 << CSW_P228) | (1 << CSW_DEAGLE) | (1 << CSW_FIVESEVEN) | (1 << CSW_ELITE);
const AUTO_GUNS = (1 << CSW_MAC10) | (1 << CSW_AUG) | (1 << CSW_UMP45) | (1 << CSW_GALIL) | (1 << CSW_FAMAS) | (1 << CSW_MP5NAVY)
	| (1 << CSW_M249) | (1 << CSW_M4A1) | (1 << CSW_TMP) | (1 << CSW_SG552) | (1 << CSW_AK47) | (1 << CSW_P90);
const SNIPERS = (1 << CSW_AWP) | (1 << CSW_SCOUT) | (1 << CSW_SG550) | (1 << CSW_G3SG1);

enum Mode { M_SILENT, M_AIM, M_TRIGGER, M_WALL, M_NORECOIL, M_KNIFE, M_ZOOM, M_RAPID, M_BHOP, M_SGS, M_MACRO, M_STRAFE, M_SPEED, M_ZERO, M_MOVEHACK, M_PITCH, M_SPIN };

new const g_modeName[Mode][] = {
	"silent", "aim", "trigger", "wall", "norecoil", "knife", "zoom", "rapid", "bhop", "sgs", "macro", "strafe", "speed", "zero", "movehack", "pitch", "spin"
};
new const g_modeHelp[Mode][] = {
	"tap fire: the shot cmd flicks to an enemy 16-70 deg away     -> silentaim",
	"hold fire: snap to the nearest enemy and stay locked          -> aimsnap, tracking (lock)",
	"fires the moment an enemy is under the crosshair              -> trigger",
	"while not firing, follows the nearest enemy, walls or not     -> tracking (wall)",
	"spray: view held at spray start minus punch                   -> norecoil",
	"knife: swings the moment an enemy is in range                 -> knifebot",
	"sniper tap fire: zoom on this cmd, fire on the next          -> fastzoom",
	"hold fire with a pistol: click exactly every 2nd cmd          -> rapidfire",
	"hold jump: jump only on the first cmd on the ground           -> bhop",
	"hold duck: ducktap only on the first cmd on the ground        -> sgs",
	"no keys needed: taps duck every 17 ms like an AHK timer       -> sgs (macro)",
	"in the air without A/D: sidemove follows the mouse            -> strafe",
	"msec x1.5                                                     -> speedhack",
	"3 cmds with msec 0 out of every 10                            -> speedhack (fake cmds)",
	"forward/side move x1.6, past the maxspeed clamp               -> movecheck",
	"pitch 120                                                     -> angles",
	"yaw +60 deg every cmd                                         -> angles (spin)"
};

new g_modes[MAX_PLAYERS + 1];
new g_tr;

new g_prevIn[MAX_PLAYERS + 1];      // buttons the client sent last cmd
new g_prevOut[MAX_PLAYERS + 1];     // buttons we let through last cmd
new Float:g_prevYaw[MAX_PLAYERS + 1];
new g_rapidTick[MAX_PLAYERS + 1];
new bool:g_zoomNext[MAX_PLAYERS + 1];
new bool:g_nrActive[MAX_PLAYERS + 1];
new Float:g_nrBase[MAX_PLAYERS + 1][3];
new Float:g_spinYaw[MAX_PLAYERS + 1];
new g_macroMs[MAX_PLAYERS + 1];
new g_zeroTick[MAX_PLAYERS + 1];

public plugin_init()
{
	register_plugin(PLUGIN, AMXAC_VERSION, AUTHOR);
	register_concmd("amx_ac_test", "cmd_test", ADMIN_RCON, "<mode|list|off> [target] - fake cheat behaviour for testing AMXAC");

	g_tr = create_tr2();
	register_forward(FM_CmdStart, "fw_CmdStart");
}

public plugin_end()
{
	free_tr2(g_tr);
}

public client_putinserver(id)
{
	g_modes[id] = 0;
}

#define HAS(%1,%2) (g_modes[%1] & (1 << _:%2))

// ---------------------------------------------------------------------------
// Command
// ---------------------------------------------------------------------------

public cmd_test(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new arg[16];
	read_argv(1, arg, charsmax(arg));

	new target = id;
	if (read_argc() >= 3)
	{
		new who[32];
		read_argv(2, who, charsmax(who));
		target = cmd_target(id, who, CMDTARGET_ALLOW_SELF);
		if (!target)
			return PLUGIN_HANDLED;
	}
	else if (!id)
	{
		console_print(id, "[AC] From the server console a target is required.");
		return PLUGIN_HANDLED;
	}

	new name[32];
	get_user_name(target, name, charsmax(name));

	if (equal(arg, "list"))
	{
		console_print(id, "[AC] Self-test modes for %s:", name);
		for (new Mode:m = M_SILENT; m < Mode; m++)
			console_print(id, "  %-9s %-3s %s", g_modeName[m], HAS(target, m) ? "ON " : "   ", g_modeHelp[m]);
		return PLUGIN_HANDLED;
	}

	if (equal(arg, "off"))
	{
		g_modes[target] = 0;
		console_print(id, "[AC] All self-test modes off for %s", name);
		return PLUGIN_HANDLED;
	}

	for (new Mode:m = M_SILENT; m < Mode; m++)
	{
		if (!equal(arg, g_modeName[m]))
			continue;

		g_modes[target] ^= 1 << _:m;
		new bool:on = HAS(target, m) != 0;
		console_print(id, "[AC] %s %s for %s", g_modeName[m], on ? "ON " : "off", name);
		if (on)
			log_amx("Self-test mode %s enabled for %s", g_modeName[m], name);
		return PLUGIN_HANDLED;
	}

	console_print(id, "[AC] Unknown mode ^"%s^", see amx_ac_test list", arg);
	return PLUGIN_HANDLED;
}

// ---------------------------------------------------------------------------
// Cmd rewriting
// ---------------------------------------------------------------------------

public fw_CmdStart(id, uc, seed)
{
	if (!g_modes[id] || !is_user_alive(id))
		return FMRES_IGNORED;

	new in = get_uc(uc, UC_Buttons);
	new out = in;
	new msec = get_uc(uc, UC_Msec);

	new Float:view[3];
	get_uc(uc, UC_ViewAngles, view);
	new Float:realYaw = view[1];
	new bool:viewChanged = false;

	new weapon = get_user_weapon(id);
	new wbit = 1 << weapon;
	new bool:onGround = (pev(id, pev_flags) & FL_ONGROUND) != 0;
	new bool:attackEdge = (in & IN_ATTACK) && !(g_prevIn[id] & IN_ATTACK);

	if (HAS(id, M_SPEED))
		set_uc(uc, UC_Msec, min(msec * 3 / 2, 255));

	if (HAS(id, M_ZERO) && (g_zeroTick[id]++ % 10) < 3)
		set_uc(uc, UC_Msec, 0);

	if (HAS(id, M_MOVEHACK))
	{
		new Float:fwd, Float:side;
		get_uc(uc, UC_ForwardMove, fwd);
		get_uc(uc, UC_SideMove, side);
		set_uc(uc, UC_ForwardMove, fwd * 1.6);
		set_uc(uc, UC_SideMove, side * 1.6);
	}

	if (HAS(id, M_BHOP) && (in & IN_JUMP))
	{
		// Let the press through only on the landing cmd, so it's a fresh press every time.
		if (!onGround || (g_prevOut[id] & IN_JUMP))
			out &= ~IN_JUMP;
	}

	if (HAS(id, M_SGS) && (in & IN_DUCK))
	{
		// Same for +duck: a one-cmd tap exactly on landing, like an SGS script.
		if (!onGround || (g_prevOut[id] & IN_DUCK))
			out &= ~IN_DUCK;
	}

	if (HAS(id, M_MACRO))
	{
		// LCtrl down for 1 ms every 17 ms, blind to landing: the client turns
		// each tap into a one-cmd +duck.
		g_macroMs[id] += msec;
		if (g_macroMs[id] >= 17)
		{
			g_macroMs[id] %= 17;
			out |= IN_DUCK;
		}
		else
			out &= ~IN_DUCK;
	}

	if (HAS(id, M_STRAFE) && !onGround && !(in & (IN_MOVELEFT | IN_MOVERIGHT)))
	{
		new Float:dyaw = amxac_wrap180(realYaw - g_prevYaw[id]);
		set_uc(uc, UC_SideMove, dyaw > 0.0 ? -400.0 : 400.0);
	}

	if (HAS(id, M_RAPID) && (in & IN_ATTACK) && (wbit & SEMI_PISTOLS))
	{
		if (g_rapidTick[id]++ & 1)
			out &= ~IN_ATTACK;
		else
			out |= IN_ATTACK;
	}
	else
		g_rapidTick[id] = 0;

	if (HAS(id, M_TRIGGER) && amxac_is_gun(weapon) && !(g_prevOut[id] & IN_ATTACK) && crosshair_enemy(id, view))
		out |= IN_ATTACK;

	if (HAS(id, M_KNIFE) && weapon == CSW_KNIFE && !(g_prevOut[id] & IN_ATTACK) && enemy_in_knife_range(id))
		out |= IN_ATTACK;

	if (HAS(id, M_ZOOM) && (wbit & SNIPERS))
	{
		if (g_zoomNext[id])
		{
			g_zoomNext[id] = false;
			out = (out | IN_ATTACK) & ~IN_ATTACK2;
		}
		else if (attackEdge && !scoped(id))
		{
			g_zoomNext[id] = true;
			out = (out | IN_ATTACK2) & ~IN_ATTACK;
		}
	}

	if (HAS(id, M_AIM) && amxac_is_gun(weapon) && (in & IN_ATTACK))
		viewChanged = aim_at_best(id, view, 0.0, 40.0, true);
	else if (HAS(id, M_SILENT) && attackEdge && (amxac_is_gun(weapon) || weapon == CSW_KNIFE))
		viewChanged = aim_at_best(id, view, 16.0, 70.0, true);
	else if (HAS(id, M_WALL) && !(in & IN_ATTACK))
		viewChanged = aim_at_best(id, view, 0.0, 40.0, false);

	if (HAS(id, M_NORECOIL) && (wbit & AUTO_GUNS) && (in & IN_ATTACK))
	{
		if (!g_nrActive[id])
		{
			g_nrActive[id] = true;
			g_nrBase[id] = view;
		}
		new Float:punch[3];
		pev(id, pev_punchangle, punch);
		predict_punch_decay(punch, float(msec) / 1000.0);
		view[0] = amxac_wrap180(g_nrBase[id][0] - punch[0]);
		view[1] = amxac_wrap180(g_nrBase[id][1] - punch[1]);
		viewChanged = true;
	}
	else
		g_nrActive[id] = false;

	if (HAS(id, M_PITCH))
	{
		view[0] = 120.0;
		viewChanged = true;
	}

	if (HAS(id, M_SPIN))
	{
		g_spinYaw[id] = amxac_wrap180(g_spinYaw[id] + 60.0);
		view[1] = g_spinYaw[id];
		viewChanged = true;
	}

	if (viewChanged)
		set_uc(uc, UC_ViewAngles, view);
	if (out != in)
		set_uc(uc, UC_Buttons, out);

	g_prevIn[id] = in;
	g_prevOut[id] = out;
	g_prevYaw[id] = realYaw;
	return FMRES_IGNORED;
}

// The punch the bullet will use is the current one minus this cmd's decay
// (PM_DropPunchAngle runs during the move, before the weapon fires).
predict_punch_decay(Float:punch[3], Float:frametime)
{
	new Float:len = floatsqroot(punch[0] * punch[0] + punch[1] * punch[1] + punch[2] * punch[2]);
	if (len <= 0.0)
		return;

	new Float:newLen = floatmax(len - (10.0 + len * 0.5) * frametime, 0.0);
	new Float:k = newLen / len;
	punch[0] *= k;
	punch[1] *= k;
	punch[2] *= k;
}

// Points `view` at the head of the best enemy whose angle from the crosshair
// is within [minFov, maxFov]. Returns true if it did.
bool:aim_at_best(id, Float:view[3], Float:minFov, Float:maxFov, bool:needVisible)
{
	new Float:eye[3], Float:head[3], Float:want[3], Float:best[3];
	amxac_eye_pos(id, eye);

	new found = 0;
	new Float:bestFov = 999.0;
	for (new e = 1; e <= MaxClients; e++)
	{
		if (e == id || !is_user_alive(e) || !amxac_is_enemy(id, e))
			continue;

		amxac_eye_pos(e, head);
		head[2] += 2.0;
		amxac_view_to(eye, head, want);

		new Float:fov = amxac_angle_dist(view, want);
		if (fov < minFov || fov > maxFov || fov >= bestFov)
			continue;
		if (needVisible && !clear_line(id, eye, head))
			continue;

		found = e;
		bestFov = fov;
		best = want;
	}

	if (!found)
		return false;
	view[0] = best[0];
	view[1] = best[1];
	return true;
}

bool:crosshair_enemy(id, const Float:view[3])
{
	new Float:eye[3], Float:dir[3], Float:end[3];
	amxac_eye_pos(id, eye);
	angle_vector(view, ANGLEVECTOR_FORWARD, dir);
	for (new i = 0; i < 3; i++)
		end[i] = eye[i] + dir[i] * 8192.0;

	engfunc(EngFunc_TraceLine, eye, end, DONT_IGNORE_MONSTERS, id, g_tr);
	new hit = get_tr2(g_tr, TR_pHit);
	return 1 <= hit <= MaxClients && is_user_alive(hit) && amxac_is_enemy(id, hit);
}

bool:enemy_in_knife_range(id)
{
	new Float:eye[3], Float:org[3];
	amxac_eye_pos(id, eye);
	for (new e = 1; e <= MaxClients; e++)
	{
		if (e == id || !is_user_alive(e) || !amxac_is_enemy(id, e))
			continue;
		pev(e, pev_origin, org);
		if (get_distance_f(eye, org) <= 64.0 && clear_line(id, eye, org))
			return true;
	}
	return false;
}

bool:clear_line(id, const Float:from[3], const Float:to[3])
{
	engfunc(EngFunc_TraceLine, from, to, IGNORE_MONSTERS, id, g_tr);
	new Float:fraction;
	get_tr2(g_tr, TR_flFraction, fraction);
	return fraction >= 1.0;
}

bool:scoped(id)
{
	new Float:fov;
	pev(id, pev_fov, fov);
	return fov > 0.0 && fov < 90.0;
}
