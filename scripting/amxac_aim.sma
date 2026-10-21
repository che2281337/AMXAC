// AMXAC: aim detectors in one plugin.
//
// One CmdStart, one set of weapon hooks and one enemy scan per usercmd feed all
// detectors. Each detector still registers as its own core module, so scores,
// logs and weights (amxac_w_<name>) stay separate; weight 0 also skips the
// detector's work entirely.
//
//   silentaim  flick on the shot cmd with an exact return
//   aimsnap    headshot after a big snap that stops dead (weak)
//   trigger    instant / fixed-delay reaction to an enemy entering the crosshair
//   tracking   tracking through walls, aim lock, headshot ratio
//   nospread   shot cmd deviates by the spread, the bullet flies dead straight
//   norecoil   v_angle + punch frozen during a spray
//   knifebot   instant swing when an enemy enters knife range
//   fastzoom   sniper shot within a frame or two of scoping
//   rapidfire  pistol clicks at a fixed interval
//   noflash    hits while fully flashed
//
// Performance notes:
//  - Natives are the expensive part of Pawn. Per-player state that rarely
//    changes (monitored, alive, team) is cached, not queried every cmd.
//  - Enemies are prefiltered with plain arithmetic against cached eye
//    positions; traces and lag-compensated pev reads only run for candidates.
//  - The TraceLine hook needed by nospread is registered only for the duration
//    of PrimaryAttack. A permanent hook would forward every trace on the server.

#include <amxmodx>
#include <amxac_util>

#define PLUGIN  "AMXAC Aim"
#define AUTHOR  "AMXAC"

#define HIST            8
#define MAX_HOLD        3
#define SPAWN_GRACE     1.0
#define TASK_REFRESH    93000

#define TRIG_SAMPLES    10
#define KNIFE_SAMPLES   10
#define ZOOM_SAMPLES    6
#define RAPID_SAMPLES   12
#define NS_WINDOW       10
#define HS_WINDOW       20
#define MAX_SPRAY       32
#define SPRAY_GAP       0.25
#define MAX_CAND        8

const SEMI_PISTOLS = (1 << CSW_USP) | (1 << CSW_GLOCK18) | (1 << CSW_P228) | (1 << CSW_DEAGLE) | (1 << CSW_FIVESEVEN) | (1 << CSW_ELITE);
const AUTO_GUNS = (1 << CSW_MAC10) | (1 << CSW_AUG) | (1 << CSW_UMP45) | (1 << CSW_GALIL) | (1 << CSW_FAMAS) | (1 << CSW_MP5NAVY)
	| (1 << CSW_M249) | (1 << CSW_M4A1) | (1 << CSW_TMP) | (1 << CSW_SG552) | (1 << CSW_AK47) | (1 << CSW_P90);
const SNIPERS = (1 << CSW_AWP) | (1 << CSW_SCOUT) | (1 << CSW_SG550) | (1 << CSW_G3SG1);
const NO_SPREAD_CHECK = (1 << CSW_KNIFE) | (1 << CSW_M3) | (1 << CSW_XM1014);

const m_flFlashedAt = 515;
const m_flFlashHoldTime = 516;
const m_iFlashAlpha = 518;

enum Det { D_SILENT, D_SNAP, D_TRIGGER, D_TRACK, D_NOSPREAD, D_NORECOIL, D_KNIFE, D_ZOOM, D_RAPID, D_FLASH };
new const g_detName[Det][] = { "silentaim", "aimsnap", "trigger", "tracking", "nospread", "norecoil", "knifebot", "fastzoom", "rapidfire", "noflash" };
new g_mod[Det];
new Float:g_w[Det];

new g_tr;

// ---- shared per-player state ----
new bool:g_monitored[MAX_PLAYERS + 1];
new bool:g_alive[MAX_PLAYERS + 1];
new g_team[MAX_PLAYERS + 1];
new Float:g_eyeCache[MAX_PLAYERS + 1][3];   // updated on the player's own cmds
new bool:g_eyeValid[MAX_PLAYERS + 1];
new g_cmd[MAX_PLAYERS + 1];
new g_clientTime[MAX_PLAYERS + 1];          // ms, sum of usercmd msec
new g_prevButtons[MAX_PLAYERS + 1];
new Float:g_ang[MAX_PLAYERS + 1][HIST][2];
new bool:g_shot[MAX_PLAYERS + 1][HIST];
new bool:g_atk[MAX_PLAYERS + 1][HIST];    // +attack held in the cmd as the client sent it
new Float:g_spawnTime[MAX_PLAYERS + 1];

// weapon hook scratch
new g_clipPre[MAX_PLAYERS + 1];
new Float:g_punchPre[MAX_PLAYERS + 1][3];
new Float:g_vangPre[MAX_PLAYERS + 1][3];
new bool:g_scopedPre[MAX_PLAYERS + 1];

// ---- aimsnap ----
new g_snapCmd[MAX_PLAYERS + 1];
new Float:g_snapSize[MAX_PLAYERS + 1];

// ---- trigger ----
new g_trigTarget[MAX_PLAYERS + 1];
new g_trigSince[MAX_PLAYERS + 1];
new bool:g_trigUsed[MAX_PLAYERS + 1];
new g_trigRt[MAX_PLAYERS + 1][TRIG_SAMPLES];
new g_trigPos[MAX_PLAYERS + 1], g_trigLen[MAX_PLAYERS + 1];

// ---- tracking ----
new g_seg[MAX_PLAYERS + 1];
new g_segStart[MAX_PLAYERS + 1];
new Float:g_segTravel[MAX_PLAYERS + 1];
new bool:g_segHidden[MAX_PLAYERS + 1];
new bool:g_segVisible[MAX_PLAYERS + 1];
new g_segN[MAX_PLAYERS + 1];
new Float:g_segSum[MAX_PLAYERS + 1][2];
new Float:g_segSq[MAX_PLAYERS + 1][2];
new g_hs[MAX_PLAYERS + 1][HS_WINDOW];
new g_hsPos[MAX_PLAYERS + 1], g_hsLen[MAX_PLAYERS + 1];

// ---- nospread ----
new g_nsFwd;                                // FM_TraceLine hook while a shot is being fired
new g_nsShooter;
new bool:g_nsCaptured;
new Float:g_nsBullet[3];
new g_nsCmd[MAX_PLAYERS + 1];               // cmd number of a shot waiting for the next cmd
new Float:g_nsBulletAng[MAX_PLAYERS + 1][2];
new Float:g_nsPunch[MAX_PLAYERS + 1][2];
new g_nsWin[MAX_PLAYERS + 1][NS_WINDOW];
new g_nsPos[MAX_PLAYERS + 1], g_nsLen[MAX_PLAYERS + 1];

// ---- norecoil ----
new g_nrShots[MAX_PLAYERS + 1];
new Float:g_nrEff[MAX_PLAYERS + 1][MAX_SPRAY][2];
new Float:g_nrPunchMax[MAX_PLAYERS + 1];
new Float:g_nrLast[MAX_PLAYERS + 1];

// ---- knifebot ----
new bool:g_knInRange[MAX_PLAYERS + 1];
new g_knSince[MAX_PLAYERS + 1];
new bool:g_knUsed[MAX_PLAYERS + 1];
new g_knRt[MAX_PLAYERS + 1][KNIFE_SAMPLES];
new g_knPos[MAX_PLAYERS + 1], g_knLen[MAX_PLAYERS + 1];

// ---- fastzoom ----
new bool:g_zZoomed[MAX_PLAYERS + 1];
new g_zAt[MAX_PLAYERS + 1];
new g_zFast[MAX_PLAYERS + 1][ZOOM_SAMPLES];
new g_zPos[MAX_PLAYERS + 1], g_zLen[MAX_PLAYERS + 1];

// ---- rapidfire ----
new g_rfLast[MAX_PLAYERS + 1];
new g_rfIv[MAX_PLAYERS + 1][RAPID_SAMPLES];
new g_rfLen[MAX_PLAYERS + 1];

// ---- noflash ----
new Float:g_flAt[MAX_PLAYERS + 1];
new g_flHits[MAX_PLAYERS + 1], g_flHeads[MAX_PLAYERS + 1];
new bool:g_flReported[MAX_PLAYERS + 1];
new Float:g_flLastHit[MAX_PLAYERS + 1];
new g_clickCmd[MAX_PLAYERS + 1];         // cmd number of the last fresh +attack

// ---- cvars ----
new Float:c_silMinFlick, Float:c_silReturnEps, Float:c_silHoldEps, c_silMaxHold, Float:c_silPts, c_silRawAttack;
new Float:c_snapMin, Float:c_snapStop, Float:c_snapPts;
new c_trigInstantMs, c_trigInstantNeed, c_trigMaxRt, Float:c_trigMaxStd, c_trigMaxMean, Float:c_trigPtsInstant, Float:c_trigPtsConst;
new Float:c_trkFov, Float:c_trkMinDist, c_trkWallMs, Float:c_trkWallTravel, Float:c_trkWallPts, Float:c_trkWallErr;
new c_trkLockMs, Float:c_trkLockTravel, Float:c_trkLockStd, Float:c_trkLockPts, c_trkHsNeed, Float:c_trkHsPts;
new Float:c_nsMinDev, Float:c_nsRatio, c_nsNeed, Float:c_nsPts;
new c_nrMinShots, Float:c_nrMinPunch, Float:c_nrMaxDrift, Float:c_nrPts;
new Float:c_knRange, c_knInstantMs, c_knNeed, Float:c_knPts;
new c_zFastMs, c_zNeed, Float:c_zPts;
new c_rfMaxInterval, Float:c_rfMaxStd, Float:c_rfPts;
new c_flNeed, Float:c_flPts;

public plugin_init()
{
	register_plugin(PLUGIN, AMXAC_VERSION, AUTHOR);

	for (new Det:d = D_SILENT; d < Det; d++)
		register_det(d);

	bind_pcvar_float(create_cvar("amxac_silent_min_flick", "15"), c_silMinFlick);
	bind_pcvar_float(create_cvar("amxac_silent_return_eps", "1.0"), c_silReturnEps);
	bind_pcvar_float(create_cvar("amxac_silent_hold_eps", "0.5"), c_silHoldEps);
	bind_pcvar_num(create_cvar("amxac_silent_max_hold", "2", _, _, true, 1.0, true, float(MAX_HOLD)), c_silMaxHold);
	bind_pcvar_float(create_cvar("amxac_silent_pts", "25"), c_silPts);
	bind_pcvar_num(create_cvar("amxac_silent_raw_attack", "1", _, "Count +attack in the raw usercmd as a shot (needed with aim blockers that delay buttons)"), c_silRawAttack);

	bind_pcvar_float(create_cvar("amxac_snap_min", "20"), c_snapMin);
	bind_pcvar_float(create_cvar("amxac_snap_stop", "0.3"), c_snapStop);
	bind_pcvar_float(create_cvar("amxac_snap_pts", "5"), c_snapPts);

	bind_pcvar_num(create_cvar("amxac_trig_instant_ms", "15"), c_trigInstantMs);
	bind_pcvar_num(create_cvar("amxac_trig_instant_need", "5"), c_trigInstantNeed);
	bind_pcvar_num(create_cvar("amxac_trig_max_rt", "1000"), c_trigMaxRt);
	bind_pcvar_float(create_cvar("amxac_trig_max_std", "8"), c_trigMaxStd);
	bind_pcvar_num(create_cvar("amxac_trig_max_mean", "400"), c_trigMaxMean);
	bind_pcvar_float(create_cvar("amxac_trig_pts_instant", "20"), c_trigPtsInstant);
	bind_pcvar_float(create_cvar("amxac_trig_pts_const", "15"), c_trigPtsConst);

	bind_pcvar_float(create_cvar("amxac_track_fov", "3"), c_trkFov);
	bind_pcvar_float(create_cvar("amxac_track_min_dist", "150"), c_trkMinDist);
	bind_pcvar_num(create_cvar("amxac_track_wall_ms", "600"), c_trkWallMs);
	bind_pcvar_float(create_cvar("amxac_track_wall_travel", "10"), c_trkWallTravel);
	bind_pcvar_float(create_cvar("amxac_track_wall_pts", "6"), c_trkWallPts);
	bind_pcvar_float(create_cvar("amxac_track_wall_err", "1.2", _, "Mean aim error on the enemy behind a wall must be below this, degrees"), c_trkWallErr);
	bind_pcvar_num(create_cvar("amxac_track_lock_ms", "250"), c_trkLockMs);
	bind_pcvar_float(create_cvar("amxac_track_lock_travel", "15"), c_trkLockTravel);
	bind_pcvar_float(create_cvar("amxac_track_lock_std", "0.25"), c_trkLockStd);
	bind_pcvar_float(create_cvar("amxac_track_lock_pts", "4"), c_trkLockPts);
	bind_pcvar_num(create_cvar("amxac_track_hs_need", "17"), c_trkHsNeed);
	bind_pcvar_float(create_cvar("amxac_track_hs_pts", "8"), c_trkHsPts);

	bind_pcvar_float(create_cvar("amxac_nospread_min_dev", "0.3"), c_nsMinDev);
	bind_pcvar_float(create_cvar("amxac_nospread_ratio", "0.25"), c_nsRatio);
	bind_pcvar_num(create_cvar("amxac_nospread_need", "8"), c_nsNeed);
	bind_pcvar_float(create_cvar("amxac_nospread_pts", "20"), c_nsPts);

	bind_pcvar_num(create_cvar("amxac_norecoil_min_shots", "6"), c_nrMinShots);
	bind_pcvar_float(create_cvar("amxac_norecoil_min_punch", "1.0"), c_nrMinPunch);
	bind_pcvar_float(create_cvar("amxac_norecoil_max_drift", "0.25"), c_nrMaxDrift);
	bind_pcvar_float(create_cvar("amxac_norecoil_pts", "12"), c_nrPts);

	bind_pcvar_float(create_cvar("amxac_knife_range", "64"), c_knRange);
	bind_pcvar_num(create_cvar("amxac_knife_instant_ms", "15"), c_knInstantMs);
	bind_pcvar_num(create_cvar("amxac_knife_need", "7"), c_knNeed);
	bind_pcvar_float(create_cvar("amxac_knife_pts", "15"), c_knPts);

	bind_pcvar_num(create_cvar("amxac_zoom_fast_ms", "40"), c_zFastMs);
	bind_pcvar_num(create_cvar("amxac_zoom_need", "3"), c_zNeed);
	bind_pcvar_float(create_cvar("amxac_zoom_pts", "12"), c_zPts);

	bind_pcvar_num(create_cvar("amxac_rapid_max_interval", "300"), c_rfMaxInterval);
	bind_pcvar_float(create_cvar("amxac_rapid_max_std", "2.5"), c_rfMaxStd);
	bind_pcvar_float(create_cvar("amxac_rapid_pts", "10"), c_rfPts);

	bind_pcvar_num(create_cvar("amxac_flash_need", "3"), c_flNeed);
	bind_pcvar_float(create_cvar("amxac_flash_pts", "10"), c_flPts);

	g_tr = create_tr2();

	register_forward(FM_CmdStart, "fw_CmdStart");
	RegisterHam(Ham_Spawn, "player", "fw_Spawn_Post", 1);
	RegisterHam(Ham_Killed, "player", "fw_Killed_Post", 1);
	RegisterHam(Ham_TraceAttack, "player", "fw_TraceAttack_Post", 1);
	amxac_hook_weapons(Ham_Weapon_PrimaryAttack, "fw_Primary_Pre", 0);
	amxac_hook_weapons(Ham_Weapon_PrimaryAttack, "fw_Primary_Post", 1);
	register_event("DeathMsg", "ev_DeathMsg", "a");

	set_task(2.0, "task_refresh", TASK_REFRESH, _, _, "b");
}

public plugin_end()
{
	free_tr2(g_tr);
}

register_det(Det:d)
{
	g_mod[d] = amxac_register_module(g_detName[d], AMXAC_VERSION, AUTHOR);

	new cvar[48];
	formatex(cvar, charsmax(cvar), "amxac_w_%s", g_detName[d]);
	new pcvar = get_cvar_pointer(cvar);
	if (pcvar)
		bind_pcvar_float(pcvar, g_w[d]);
	else
		g_w[d] = 1.0;
}

#define ON(%1) (g_w[%1] > 0.0)

// ---------------------------------------------------------------------------
// Cached player state
// ---------------------------------------------------------------------------

public task_refresh()
{
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_connected(id))
			continue;
		g_monitored[id] = amxac_is_monitored(id);
		g_team[id] = get_user_team(id);
		g_alive[id] = bool:is_user_alive(id);
	}
}

public client_putinserver(id)
{
	g_monitored[id] = amxac_is_monitored(id);
	g_alive[id] = false;
	g_eyeValid[id] = false;
	g_cmd[id] = 0;
	g_clientTime[id] = 0;
	g_prevButtons[id] = 0;
	g_snapCmd[id] = g_nsCmd[id] = 0;
	g_trigTarget[id] = 0;
	g_trigLen[id] = g_trigPos[id] = 0;
	g_seg[id] = 0;
	g_hsLen[id] = g_hsPos[id] = 0;
	g_nsLen[id] = g_nsPos[id] = 0;
	g_nrShots[id] = 0;
	g_knInRange[id] = false;
	g_knLen[id] = g_knPos[id] = 0;
	g_zZoomed[id] = false;
	g_zLen[id] = g_zPos[id] = 0;
	g_rfLen[id] = 0;
	g_flAt[id] = 0.0;
}

public client_disconnected(id)
{
	g_monitored[id] = false;
	g_alive[id] = false;
	g_eyeValid[id] = false;
}

public fw_Spawn_Post(id)
{
	if (!is_user_alive(id))
		return;
	g_alive[id] = true;
	g_team[id] = get_user_team(id);
	g_spawnTime[id] = get_gametime();
	g_cmd[id] = 0;
	g_seg[id] = 0;
	g_trigTarget[id] = 0;
	g_nrShots[id] = 0;
}

public fw_Killed_Post(victim, killer, gib)
{
	g_alive[victim] = false;
	g_eyeValid[victim] = false;
}

// ---------------------------------------------------------------------------
// Per usercmd
// ---------------------------------------------------------------------------

public fw_CmdStart(id, uc, seed)
{
	if (!g_monitored[id] || !g_alive[id])
		return FMRES_IGNORED;

	// A shot that was blocked by another plugin may have left the trace hook on.
	if (g_nsFwd)
		ns_unhook();

	new buttons = get_uc(uc, UC_Buttons);
	new now = g_clientTime[id];
	g_clientTime[id] += get_uc(uc, UC_Msec);

	new Float:view[3];
	get_uc(uc, UC_ViewAngles, view);

	new slot = g_cmd[id] % HIST;
	g_ang[id][slot][0] = view[0];
	g_ang[id][slot][1] = view[1];
	g_shot[id][slot] = false;
	g_cmd[id]++;

	new Float:eye[3];
	amxac_eye_pos(id, eye);
	g_eyeCache[id] = eye;
	g_eyeValid[id] = true;

	new weapon = get_user_weapon(id);

	// Aim blockers (Unreal Aim Blocker "key delay") hand +attack to the game one
	// cmd late, so the bullet leaves after the view is back and the silent flick
	// never lines up with a real shot. The flick still lines up with the button
	// the client pressed, which we see here as long as this plugin's CmdStart
	// runs first (listed above the blocker in plugins.ini).
	g_atk[id][slot] = (buttons & IN_ATTACK) && (amxac_is_gun(weapon) || weapon == CSW_KNIFE);
	new prev = g_prevButtons[id];
	g_prevButtons[id] = buttons;
	if (amxac_pressed(buttons, prev, IN_ATTACK))
		g_clickCmd[id] = g_cmd[id];

	if (ON(D_SILENT) && get_gametime() - g_spawnTime[id] >= SPAWN_GRACE)
		silent_check(id);
	if (ON(D_SNAP))
		snap_on_cmd(id);
	if (ON(D_NOSPREAD))
		ns_on_cmd(id);
	if (ON(D_NORECOIL) && g_nrShots[id] && !(buttons & IN_ATTACK))
		nr_finish(id);
	if (ON(D_ZOOM))
		zoom_on_cmd(id, now);
	if (ON(D_RAPID))
		rapid_on_cmd(id, buttons, prev, now, weapon);

	new bool:gun = amxac_is_gun(weapon);
	new bool:knife = weapon == CSW_KNIFE;
	new bool:wantTrigger = ON(D_TRIGGER) && gun;
	new bool:wantTrack = ON(D_TRACK) && gun;
	new bool:wantKnife = ON(D_KNIFE) && knife;

	if (!wantTrigger) g_trigTarget[id] = 0;
	if (!wantKnife) g_knInRange[id] = false;
	if (!wantTrack && g_seg[id]) track_finish(id, now);

	if (!wantTrigger && !wantTrack && !wantKnife)
		return FMRES_IGNORED;

	new Float:dir[3];
	angle_vector(view, ANGLEVECTOR_FORWARD, dir);

	// Cheap prefilter over all enemies using cached eye positions.
	new bool:rayCand = false;
	new cone[MAX_CAND], coneN = 0;
	new near[MAX_CAND], nearN = 0;

	new Float:coneCos = floatcos(c_trkFov + 4.0, degrees);
	new Float:knifeR = c_knRange + 40.0;

	for (new e = 1; e <= MaxClients; e++)
	{
		if (e == id || !g_alive[e] || !g_eyeValid[e] || g_team[e] == g_team[id])
			continue;

		new Float:d0 = g_eyeCache[e][0] - eye[0];
		new Float:d1 = g_eyeCache[e][1] - eye[1];
		new Float:d2 = g_eyeCache[e][2] - eye[2];
		new Float:dist2 = d0 * d0 + d1 * d1 + d2 * d2;
		new Float:along = d0 * dir[0] + d1 * dir[1] + d2 * dir[2];

		if (wantKnife && nearN < MAX_CAND && dist2 <= knifeR * knifeR)
			near[nearN++] = e;

		if (along <= 0.0)
			continue;

		// Distance from the crosshair ray to the enemy's body (eye minus ~20 units).
		if (wantTrigger && !rayCand)
		{
			new Float:b2 = d2 - 20.0;
			new Float:bAlong = d0 * dir[0] + d1 * dir[1] + b2 * dir[2];
			new Float:perp2 = d0 * d0 + d1 * d1 + b2 * b2 - bAlong * bAlong;
			if (bAlong > 0.0 && perp2 <= 60.0 * 60.0)
				rayCand = true;
		}

		if (wantTrack && coneN < MAX_CAND && along * along >= coneCos * coneCos * dist2)
			cone[coneN++] = e;
	}

	if (wantTrigger)
		trigger_on_cmd(id, eye, dir, rayCand, amxac_pressed(buttons, prev, IN_ATTACK), now);
	if (wantTrack)
		track_on_cmd(id, eye, view, cone, coneN, now);
	if (wantKnife)
		knife_on_cmd(id, eye, near, nearN, amxac_pressed(buttons, prev, IN_ATTACK) || amxac_pressed(buttons, prev, IN_ATTACK2), now);

	return FMRES_IGNORED;
}

// ---------------------------------------------------------------------------
// Weapon hooks (PrimaryAttack runs inside the same usercmd as CmdStart)
// ---------------------------------------------------------------------------

public fw_Primary_Pre(weapon)
{
	new id = amxac_weapon_owner(weapon);
	if (!id || !g_monitored[id] || !g_cmd[id])
		return;

	new wid = amxac_weapon_id(weapon);
	g_clipPre[id] = amxac_weapon_clip(weapon);
	pev(id, pev_punchangle, g_punchPre[id]);
	pev(id, pev_v_angle, g_vangPre[id]);
	g_scopedPre[id] = scoped(id);

	// Capture the bullet's trace. FireBullets3 aims along v_angle + punch with
	// spread applied; recoil is added after.
	if (ON(D_NOSPREAD) && g_cmd[id] >= 2 && g_clipPre[id] > 0 && !((1 << wid) & NO_SPREAD_CHECK))
	{
		g_nsShooter = id;
		g_nsCaptured = false;
		g_nsFwd = register_forward(FM_TraceLine, "fw_TraceLine_Post", 1);
	}
}

public fw_TraceLine_Post(const Float:v1[3], const Float:v2[3], noMonsters, skip, tr)
{
	if (skip != g_nsShooter || g_nsCaptured)
		return FMRES_IGNORED;

	g_nsCaptured = true;
	g_nsBullet[0] = v2[0] - v1[0];
	g_nsBullet[1] = v2[1] - v1[1];
	g_nsBullet[2] = v2[2] - v1[2];
	return FMRES_IGNORED;
}

ns_unhook()
{
	unregister_forward(FM_TraceLine, g_nsFwd, 1);
	g_nsFwd = 0;
}

public fw_Primary_Post(weapon)
{
	new id = amxac_weapon_owner(weapon);
	if (!id || !g_monitored[id] || !g_cmd[id])
		return;

	new bool:captured = false;
	if (g_nsFwd)
	{
		ns_unhook();
		captured = g_nsCaptured && g_nsShooter == id;
	}

	new wid = amxac_weapon_id(weapon);
	new bool:fired = wid == CSW_KNIFE || amxac_weapon_clip(weapon) < g_clipPre[id];
	if (!fired)
		return;

	g_shot[id][(g_cmd[id] - 1) % HIST] = true;

	if (captured)
		ns_on_shot(id);
	if (ON(D_NORECOIL) && ((1 << wid) & AUTO_GUNS))
		nr_on_shot(id);
	if (ON(D_ZOOM) && ((1 << wid) & SNIPERS) && g_scopedPre[id])
		zoom_on_shot(id);
}

public fw_TraceAttack_Post(victim, attacker, Float:damage, Float:dir[3], tr, damagebits)
{
	if (!(1 <= attacker <= MaxClients) || attacker == victim || !g_monitored[attacker] || !(damagebits & DMG_BULLET))
		return HAM_IGNORED;
	if (g_team[attacker] == g_team[victim])
		return HAM_IGNORED;

	new bool:head = get_tr2(tr, TR_iHitgroup) == HIT_HEAD;

	if (ON(D_SNAP) && head)
		snap_on_headshot(attacker);
	if (ON(D_FLASH))
		flash_on_hit(attacker, head);
	return HAM_IGNORED;
}

// ---------------------------------------------------------------------------
// silentaim
// ---------------------------------------------------------------------------

silent_check(id)
{
	new t = g_cmd[id] - 1;   // the cmd just stored, candidate "return" cmd

	for (new h = 1; h <= c_silMaxHold; h++)
	{
		new base = t - h - 1;
		if (base < 0)
			return;

		new sBase = base % HIST, sRet = t % HIST, sFirst = (base + 1) % HIST;

		new Float:flick = amxac_angle_dist(g_ang[id][sBase], g_ang[id][sFirst]);
		if (flick < c_silMinFlick)
			continue;

		new bool:shot = false, bool:stable = true;
		for (new k = base + 1; k < t; k++)
		{
			new s = k % HIST;
			if (g_shot[id][s] || (c_silRawAttack && g_atk[id][s]))
				shot = true;
			if (amxac_angle_dist(g_ang[id][s], g_ang[id][sFirst]) > c_silHoldEps)
				stable = false;
		}
		if (!shot || !stable)
			continue;

		// The real view keeps moving a little while the flick is held.
		new Float:back = amxac_angle_dist(g_ang[id][sRet], g_ang[id][sBase]);
		if (back > floatmax(c_silReturnEps, flick * 0.1))
			continue;

		amxac_report(id, g_mod[D_SILENT], c_silPts, "flick %.1f deg held %d cmd(s), returned within %.2f deg", flick, h, back);
		for (new k = base + 1; k < t; k++)
			g_shot[id][k % HIST] = g_atk[id][k % HIST] = false;
		return;
	}
}

// ---------------------------------------------------------------------------
// aimsnap
// ---------------------------------------------------------------------------

snap_on_headshot(id)
{
	if (g_cmd[id] < 2 || g_snapCmd[id] == g_cmd[id])
		return;   // shotgun pellets: one shot, many traces

	new t = g_cmd[id] - 1;
	new Float:snap = amxac_angle_dist(g_ang[id][(t - 1) % HIST], g_ang[id][t % HIST]);
	if (snap >= c_snapMin)
	{
		g_snapCmd[id] = g_cmd[id];
		g_snapSize[id] = snap;
	}
}

snap_on_cmd(id)
{
	if (!g_snapCmd[id])
		return;
	if (g_snapCmd[id] == g_cmd[id] - 1)
	{
		new t = g_cmd[id] - 1;
		new Float:after = amxac_angle_dist(g_ang[id][(t - 1) % HIST], g_ang[id][t % HIST]);
		if (after <= c_snapStop)
			amxac_report(id, g_mod[D_SNAP], c_snapPts, "headshot after %.1f deg snap, then moved %.2f deg", g_snapSize[id], after);
	}
	g_snapCmd[id] = 0;
}

// ---------------------------------------------------------------------------
// trigger
// ---------------------------------------------------------------------------

trigger_on_cmd(id, const Float:eye[3], const Float:dir[3], bool:rayCand, bool:clicked, now)
{
	new hit = 0;
	if (rayCand)
	{
		new Float:end[3];
		end[0] = eye[0] + dir[0] * 8192.0;
		end[1] = eye[1] + dir[1] * 8192.0;
		end[2] = eye[2] + dir[2] * 8192.0;
		engfunc(EngFunc_TraceLine, eye, end, DONT_IGNORE_MONSTERS, id, g_tr);
		hit = get_tr2(g_tr, TR_pHit);
		if (!(1 <= hit <= MaxClients) || !g_alive[hit] || g_team[hit] == g_team[id])
			hit = 0;
	}

	if (!hit)
		g_trigTarget[id] = 0;
	else if (hit != g_trigTarget[id])
	{
		g_trigTarget[id] = hit;
		g_trigSince[id] = now;
		g_trigUsed[id] = false;
	}

	if (!clicked || !g_trigTarget[id] || g_trigUsed[id])
		return;

	g_trigUsed[id] = true;
	new rt = now - g_trigSince[id];
	if (rt > c_trigMaxRt)
		return;

	new n = ring_push(g_trigRt[id], g_trigPos[id], g_trigLen[id], TRIG_SAMPLES, rt);
	new instant = ring_count_le(g_trigRt[id], n, c_trigInstantMs);

	if (instant >= c_trigInstantNeed)
	{
		amxac_report(id, g_mod[D_TRIGGER], c_trigPtsInstant, "%d/%d shots fired within %d ms of enemy entering crosshair", instant, n, c_trigInstantMs);
		g_trigLen[id] = g_trigPos[id] = 0;
		return;
	}
	if (n < TRIG_SAMPLES)
		return;

	new Float:mean, Float:std;
	ring_stats(g_trigRt[id], n, mean, std);
	if (std <= c_trigMaxStd && mean <= float(c_trigMaxMean))
	{
		amxac_report(id, g_mod[D_TRIGGER], c_trigPtsConst, "reaction %.0f ms +/- %.1f ms over %d shots (fixed delay)", mean, std, n);
		g_trigLen[id] = g_trigPos[id] = 0;
	}
}

// ---------------------------------------------------------------------------
// tracking
// ---------------------------------------------------------------------------

track_on_cmd(id, const Float:eye[3], const Float:view[3], const cone[], coneN, now)
{
	// Exact check with lag-compensated positions, candidates only.
	new best = 0;
	new Float:bestDist = 999.0, Float:bestErr[2];
	new Float:org[3], Float:want[3];
	for (new i = 0; i < coneN; i++)
	{
		new e = cone[i];
		amxac_eye_pos(e, org);
		if (get_distance_f(eye, org) < c_trkMinDist)
			continue;

		amxac_view_to(eye, org, want);
		new Float:d = amxac_angle_dist(view, want);
		if (d < c_trkFov && d < bestDist)
		{
			best = e;
			bestDist = d;
			bestErr[0] = amxac_wrap180(want[0] - view[0]);
			bestErr[1] = amxac_wrap180(want[1] - view[1]);
		}
	}

	if (best != g_seg[id])
	{
		track_finish(id, now);
		if (best)
			track_start(id, best, now);
	}
	if (!best)
		return;

	new t = g_cmd[id] - 1;
	if (t >= 1)
		g_segTravel[id] += floatabs(amxac_wrap180(g_ang[id][t % HIST][1] - g_ang[id][(t - 1) % HIST][1]));

	g_segN[id]++;
	for (new k = 0; k < 2; k++)
	{
		g_segSum[id][k] += bestErr[k];
		g_segSq[id][k] += bestErr[k] * bestErr[k];
	}

	// Visibility only matters until the segment has proven both ways wrong.
	if (g_segHidden[id] || g_segVisible[id])
	{
		if (target_visible(id, eye, best))
			g_segHidden[id] = false;
		else
			g_segVisible[id] = false;
	}
}

track_start(id, target, now)
{
	g_seg[id] = target;
	g_segStart[id] = now;
	g_segTravel[id] = 0.0;
	g_segHidden[id] = true;
	g_segVisible[id] = true;
	g_segN[id] = 0;
	g_segSum[id][0] = g_segSum[id][1] = 0.0;
	g_segSq[id][0] = g_segSq[id][1] = 0.0;
}

track_finish(id, now)
{
	new target = g_seg[id];
	g_seg[id] = 0;
	if (!target || g_segN[id] < 3 || !is_user_connected(target))
		return;

	new len = now - g_segStart[id];
	new name[32];
	get_user_name(target, name, charsmax(name));

	// Mean aim error of the segment (the head-vs-eye offset is part of it).
	new Float:n = float(g_segN[id]);
	new Float:meanErr = floatsqroot(floatpower(g_segSum[id][0] / n, 2.0) + floatpower(g_segSum[id][1] / n, 2.0));

	// Following footsteps through a thin wall is a legit skill, but it's rough:
	// a few degrees off. Only near-perfect aim on someone you can't see counts.
	if (g_segHidden[id] && len >= c_trkWallMs && g_segTravel[id] >= c_trkWallTravel && meanErr <= c_trkWallErr)
	{
		amxac_report(id, g_mod[D_TRACK], c_trkWallPts, "tracked %s through a wall for %d ms (%.0f deg of mouse movement, %.1f deg off)", name, len, g_segTravel[id], meanErr);
	}
	else if (g_segVisible[id] && len >= c_trkLockMs && g_segTravel[id] >= c_trkLockTravel)
	{
		new Float:var = 0.0;
		for (new k = 0; k < 2; k++)
		{
			new Float:mean = g_segSum[id][k] / n;
			var += g_segSq[id][k] / n - mean * mean;
		}
		new Float:std = floatsqroot(floatmax(var, 0.0));
		if (std <= c_trkLockStd)
			amxac_report(id, g_mod[D_TRACK], c_trkLockPts, "locked on %s for %d ms, view turned %.0f deg, aim error std %.2f deg", name, len, g_segTravel[id], std);
	}
}

bool:target_visible(id, const Float:eye[3], target)
{
	new Float:pt[3];
	amxac_eye_pos(target, pt);
	if (trace_clear(id, eye, pt))
		return true;
	pev(target, pev_origin, pt);
	return trace_clear(id, eye, pt);
}

public ev_DeathMsg()
{
	if (!ON(D_TRACK))
		return;

	new killer = read_data(1);
	new victim = read_data(2);
	if (!(1 <= killer <= MaxClients) || killer == victim || !g_monitored[killer])
		return;

	new weapon[16];
	read_data(4, weapon, charsmax(weapon));
	if (equal(weapon, "knife") || equal(weapon, "grenade"))
		return;

	new n = ring_push(g_hs[killer], g_hsPos[killer], g_hsLen[killer], HS_WINDOW, read_data(3) ? 1 : 0);
	if (n < HS_WINDOW)
		return;

	new hs = 0;
	for (new i = 0; i < n; i++)
		hs += g_hs[killer][i];

	if (hs >= c_trkHsNeed)
	{
		amxac_report(killer, g_mod[D_TRACK], c_trkHsPts, "%d/%d recent gun kills were headshots", hs, n);
		g_hsLen[killer] = g_hsPos[killer] = 0;
	}
}

// ---------------------------------------------------------------------------
// nospread
//
//   smooth = midpoint of the cmds before and after the shot (the mouse path)
//   dev    = how far the shot cmd stands out from smooth
//   err    = how far the real bullet is from smooth + punch
// Legit: dev ~ 0, err ~ spread. No-spread: dev ~ spread, err ~ 0.
// ---------------------------------------------------------------------------

ns_on_shot(id)
{
	new Float:ang[3];
	amxac_dir_to_view(g_nsBullet, ang);
	g_nsCmd[id] = g_cmd[id];
	g_nsBulletAng[id][0] = ang[0];
	g_nsBulletAng[id][1] = ang[1];
	g_nsPunch[id][0] = g_punchPre[id][0];
	g_nsPunch[id][1] = g_punchPre[id][1];
}

ns_on_cmd(id)
{
	if (!g_nsCmd[id])
		return;
	new shotCmd = g_nsCmd[id];
	g_nsCmd[id] = 0;
	if (shotCmd != g_cmd[id] - 1 || shotCmd < 2)
		return;

	// shot cmd index = shotCmd - 1; neighbours are -1 and +1 of it.
	new s = shotCmd - 1;
	new Float:smooth[2];
	amxac_angle_mid(g_ang[id][(s - 1) % HIST], g_ang[id][(s + 1) % HIST], smooth);

	new Float:dev = amxac_angle_dist(g_ang[id][s % HIST], smooth);
	if (dev < c_nsMinDev || dev > 10.0)
		return;   // nothing to see, or a flick for silentaim/aimsnap

	new Float:expect[2];
	expect[0] = smooth[0] + g_nsPunch[id][0];
	expect[1] = smooth[1] + g_nsPunch[id][1];
	new Float:err = amxac_angle_dist(g_nsBulletAng[id], expect);

	new n = ring_push(g_nsWin[id], g_nsPos[id], g_nsLen[id], NS_WINDOW, err < dev * c_nsRatio ? 1 : 0);
	if (n < NS_WINDOW)
		return;

	new hits = 0;
	for (new i = 0; i < n; i++)
		hits += g_nsWin[id][i];

	if (hits >= c_nsNeed)
	{
		amxac_report(id, g_mod[D_NOSPREAD], c_nsPts, "%d/%d shots: cmd off the mouse path by spread, bullet dead on (last dev %.2f, err %.2f)", hits, n, dev, err);
		g_nsLen[id] = g_nsPos[id] = 0;
	}
}

// ---------------------------------------------------------------------------
// norecoil: v_angle + punch stays frozen during a spray
// ---------------------------------------------------------------------------

nr_on_shot(id)
{
	new Float:now = get_gametime();
	if (g_nrShots[id] && now - g_nrLast[id] > SPRAY_GAP)
		nr_finish(id);
	g_nrLast[id] = now;

	if (g_nrShots[id] >= MAX_SPRAY)
		return;

	new s = g_nrShots[id]++;
	g_nrEff[id][s][0] = amxac_wrap180(g_vangPre[id][0] + g_punchPre[id][0]);
	g_nrEff[id][s][1] = amxac_wrap180(g_vangPre[id][1] + g_punchPre[id][1]);

	new Float:mag = floatsqroot(g_punchPre[id][0] * g_punchPre[id][0] + g_punchPre[id][1] * g_punchPre[id][1]);
	if (s == 0 || mag > g_nrPunchMax[id])
		g_nrPunchMax[id] = mag;
}

nr_finish(id)
{
	new n = g_nrShots[id];
	g_nrShots[id] = 0;
	if (n < 3)
		return;

	new Float:drift = 0.0;
	for (new i = 1; i < n; i++)
		drift = floatmax(drift, amxac_angle_dist(g_nrEff[id][i], g_nrEff[id][0]));

	amxac_debug(id, "norecoil: %d shots, punch max %.2f (need %.2f), drift %.2f (need <= %.2f and <= 25%% of punch)",
		n, g_nrPunchMax[id], c_nrMinPunch, drift, c_nrMaxDrift);

	if (n < c_nrMinShots || g_nrPunchMax[id] < c_nrMinPunch)
		return;

	// Punch decays ~10 deg/s between shots, so it rarely climbs past 1-2 degrees.
	// A human holding the mouse still drifts by about the punch itself; pulling
	// down still leaves a good part of it. No-recoil cancels it almost fully.
	if (drift <= c_nrMaxDrift && drift <= g_nrPunchMax[id] * 0.25)
		amxac_report(id, g_mod[D_NORECOIL], c_nrPts, "%d-shot spray, recoil %.1f deg cancelled to %.2f deg", n, g_nrPunchMax[id], drift);
}

// ---------------------------------------------------------------------------
// knifebot
// ---------------------------------------------------------------------------

knife_on_cmd(id, const Float:eye[3], const near[], nearN, bool:swing, now)
{
	new bool:inRange = false;
	new Float:org[3], Float:fraction;
	for (new i = 0; i < nearN && !inRange; i++)
	{
		pev(near[i], pev_origin, org);
		if (get_distance_f(eye, org) > c_knRange)
			continue;
		engfunc(EngFunc_TraceLine, eye, org, IGNORE_MONSTERS, id, g_tr);
		get_tr2(g_tr, TR_flFraction, fraction);
		inRange = fraction >= 1.0;
	}

	if (inRange && !g_knInRange[id])
	{
		g_knSince[id] = now;
		g_knUsed[id] = false;
	}
	g_knInRange[id] = inRange;

	if (!swing || !inRange || g_knUsed[id])
		return;
	g_knUsed[id] = true;

	new n = ring_push(g_knRt[id], g_knPos[id], g_knLen[id], KNIFE_SAMPLES, now - g_knSince[id]);
	new instant = ring_count_le(g_knRt[id], n, c_knInstantMs);
	if (instant >= c_knNeed)
	{
		amxac_report(id, g_mod[D_KNIFE], c_knPts, "%d/%d knife swings within %d ms of enemy entering range", instant, n, c_knInstantMs);
		g_knLen[id] = g_knPos[id] = 0;
	}
}

// ---------------------------------------------------------------------------
// fastzoom
// ---------------------------------------------------------------------------

bool:scoped(id)
{
	new Float:fov;
	pev(id, pev_fov, fov);
	return fov > 0.0 && fov < 90.0;
}

zoom_on_cmd(id, now)
{
	// Zoom state after the previous cmd: the zoom happened at the start of this one.
	new bool:z = scoped(id);
	if (z && !g_zZoomed[id])
		g_zAt[id] = now;
	g_zZoomed[id] = z;
}

zoom_on_shot(id)
{
	// Not seen as zoomed at cmd start: scoped and fired within the same cmd.
	new rt = g_zZoomed[id] ? g_clientTime[id] - g_zAt[id] : 0;

	new n = ring_push(g_zFast[id], g_zPos[id], g_zLen[id], ZOOM_SAMPLES, rt <= c_zFastMs ? 1 : 0);
	new fast = 0;
	for (new i = 0; i < n; i++)
		fast += g_zFast[id][i];

	if (fast >= c_zNeed)
	{
		amxac_report(id, g_mod[D_ZOOM], c_zPts, "%d/%d scoped shots fired within %d ms of zooming", fast, n, c_zFastMs);
		g_zLen[id] = g_zPos[id] = 0;
	}
}

// ---------------------------------------------------------------------------
// rapidfire
// ---------------------------------------------------------------------------

rapid_on_cmd(id, buttons, prev, now, weapon)
{
	if (!amxac_pressed(buttons, prev, IN_ATTACK))
		return;
	if (!((1 << weapon) & SEMI_PISTOLS))
	{
		g_rfLen[id] = 0;
		return;
	}

	new iv = now - g_rfLast[id];
	g_rfLast[id] = now;
	if (iv > c_rfMaxInterval)
	{
		g_rfLen[id] = 0;
		return;
	}

	g_rfIv[id][g_rfLen[id]++] = iv;
	if (g_rfLen[id] < RAPID_SAMPLES)
		return;
	g_rfLen[id] = 0;

	new Float:mean, Float:std;
	ring_stats(g_rfIv[id], RAPID_SAMPLES, mean, std);
	if (std <= c_rfMaxStd)
		amxac_report(id, g_mod[D_RAPID], c_rfPts, "%d pistol clicks every %.0f ms +/- %.1f ms", RAPID_SAMPLES, mean, std);
}

// ---------------------------------------------------------------------------
// noflash: hits while the flash hold phase is at full alpha
// ---------------------------------------------------------------------------

flash_on_hit(id, bool:head)
{
	if (get_pdata_int(id, m_iFlashAlpha, AMXAC_XO_PLAYER) < 255)
		return;

	new Float:at = get_pdata_float(id, m_flFlashedAt, AMXAC_XO_PLAYER);
	new Float:hold = get_pdata_float(id, m_flFlashHoldTime, AMXAC_XO_PLAYER);
	new Float:now = get_gametime();
	if (at <= 0.0 || now < at || now > at + hold)
		return;

	if (at != g_flAt[id])
	{
		g_flAt[id] = at;
		g_flHits[id] = g_flHeads[id] = 0;
		g_flReported[id] = false;
	}

	if (now == g_flLastHit[id])
		return;   // pellets of one shot
	g_flLastHit[id] = now;

	// Only hits from a fresh click count. Spraying blind at a doorway and hitting
	// whoever runs into it is a normal thing to do; it counts once per burst.
	// Tapping enemies one by one while the screen is white is not.
	if (g_clickCmd[id] != g_cmd[id])
		return;

	g_flHits[id]++;
	if (head)
		g_flHeads[id]++;

	if (!g_flReported[id] && g_flHits[id] + g_flHeads[id] >= c_flNeed)
	{
		g_flReported[id] = true;
		amxac_report(id, g_mod[D_FLASH], c_flPts, "%d aimed hits (%d headshots) on enemies while fully flashed", g_flHits[id], g_flHeads[id]);
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

bool:trace_clear(id, const Float:from[3], const Float:to[3])
{
	engfunc(EngFunc_TraceLine, from, to, IGNORE_MONSTERS, id, g_tr);
	new Float:fraction;
	get_tr2(g_tr, TR_flFraction, fraction);
	// Brush entities (glass, fences, doors) count as see-through.
	return fraction >= 1.0 || get_tr2(g_tr, TR_pHit) > 0;
}

// Pushes v into a ring buffer of size n; returns the number of valid entries.
ring_push(ring[], &pos, &len, n, v)
{
	ring[pos] = v;
	pos = (pos + 1) % n;
	if (len < n)
		len++;
	return len;
}

ring_count_le(const ring[], len, limit)
{
	new c = 0;
	for (new i = 0; i < len; i++)
		if (ring[i] <= limit) c++;
	return c;
}

ring_stats(const ring[], len, &Float:mean, &Float:std)
{
	new Float:sum = 0.0;
	for (new i = 0; i < len; i++)
		sum += float(ring[i]);
	mean = sum / float(len);

	new Float:var = 0.0;
	for (new i = 0; i < len; i++)
	{
		new Float:d = float(ring[i]) - mean;
		var += d * d;
	}
	std = floatsqroot(var / float(len));
}
