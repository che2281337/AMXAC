// AMXAC: movement and timing detectors in one plugin.
//
//   bhop       streaks of frame-perfect jumps
//   sgs        the same for ducktaps (SGS / ground strafe scripts)
//              bhop and sgs also catch timer macros (AHK) that spam the button
//              at a fixed rate regardless of landing
//   strafe     sidemove without strafe keys (auto-strafe); A/D switched on the
//              exact frame the mouse turns around, switch after switch (helper)
//   speedhack  client clock running ahead of the server; bursts of msec = 0 cmds
//   movecheck  move values a real client can't send: wrong sign for the key held,
//              or more than the maxspeed the client clamps to
//   angles     pitch beyond +-89, spinbot
//   netcode    steady pattern of choked packets (fakelag, weak); shots that
//              arrive in choked packets far more often than other cmds (lag shot)
//
// Everything here is arithmetic on the usercmd; no traces.

#include <amxmodx>
#include <amxac_util>

#define PLUGIN  "AMXAC Move"
#define AUTHOR  "AMXAC"

#define TASK_REFRESH    94000
#define HOP_WINDOW      30
#define PITCH_COOLDOWN  5.0

enum Det { D_BHOP, D_SGS, D_STRAFE, D_SPEED, D_ANGLES, D_NET, D_MOVE };
new const g_detName[Det][] = { "bhop", "sgs", "strafe", "speedhack", "angles", "netcode", "movecheck" };
new g_mod[Det];
new Float:g_w[Det];

#define ON(%1) (g_w[%1] > 0.0)

new bool:g_monitored[MAX_PLAYERS + 1];
new g_prevButtons[MAX_PLAYERS + 1];
new g_clientTime[MAX_PLAYERS + 1];      // ms, sum of usercmd msec
new Float:g_prevYaw[MAX_PLAYERS + 1];

// bhop / sgs: the same frame-perfect-press tracker for +jump and +duck
#define H_JUMP      0
#define H_DUCK      1
#define HOP_KINDS   2
new const g_hopDet[HOP_KINDS] = { _:D_BHOP, _:D_SGS };
new const g_hopButton[HOP_KINDS] = { IN_JUMP, IN_DUCK };
new const g_hopWord[HOP_KINDS][] = { "bhops", "ducktaps" };

new g_hGround[HOP_KINDS][MAX_PLAYERS + 1];
new g_hAirPresses[HOP_KINDS][MAX_PLAYERS + 1];
new g_hStreak[HOP_KINDS][MAX_PLAYERS + 1];
new g_hClean[HOP_KINDS][MAX_PLAYERS + 1];
new g_hWin[HOP_KINDS][MAX_PLAYERS + 1][HOP_WINDOW];
new g_hPos[HOP_KINDS][MAX_PLAYERS + 1], g_hLen[HOP_KINDS][MAX_PLAYERS + 1];

// button macro: presses per second and interval statistics
new g_mPresses[HOP_KINDS][MAX_PLAYERS + 1];
new g_mBucket[HOP_KINDS][MAX_PLAYERS + 1];
new g_mLast[HOP_KINDS][MAX_PLAYERS + 1];
new g_mSeconds[HOP_KINDS][MAX_PLAYERS + 1];
new g_mN[HOP_KINDS][MAX_PLAYERS + 1];
new Float:g_mSum[HOP_KINDS][MAX_PLAYERS + 1];
new Float:g_mSq[HOP_KINDS][MAX_PLAYERS + 1];

// strafe
new g_stAir[MAX_PLAYERS + 1], g_stNoKey[MAX_PLAYERS + 1];
new g_stCmd[MAX_PLAYERS + 1];          // air cmd counter
new g_stYawSign[MAX_PLAYERS + 1];      // direction the mouse turns: -1, 0, 1
new g_stRevCmd[MAX_PLAYERS + 1];       // air cmd of the last mouse reversal
new g_stLastKey[MAX_PLAYERS + 1];      // last single strafe key: -1 = A, 1 = D
new g_stSwitchCmd[MAX_PLAYERS + 1];    // pending key switch, 0 = none
new g_stSwitchBest[MAX_PLAYERS + 1];   // closest reversal seen for it, in cmds
new g_stSwitches[MAX_PLAYERS + 1], g_stExact[MAX_PLAYERS + 1];

// speedhack
new bool:g_spStarted[MAX_PLAYERS + 1];
new Float:g_spBalance[MAX_PLAYERS + 1];
new Float:g_spLast[MAX_PLAYERS + 1];
new g_zStreak[MAX_PLAYERS + 1];         // consecutive msec = 0 cmds
new g_zEvents[MAX_PLAYERS + 1];         // streaks that reached the limit in this window
new g_zCmds[MAX_PLAYERS + 1];
new Float:g_zWindow[MAX_PLAYERS + 1];
new Float:g_zAvgMsec[MAX_PLAYERS + 1];  // running average of nonzero msec

// movecheck
new g_mvCmds[MAX_PLAYERS + 1], g_mvSign[MAX_PLAYERS + 1], g_mvOver[MAX_PLAYERS + 1];
new Float:g_mvLimit[MAX_PLAYERS + 1], Float:g_mvLimitTime[MAX_PLAYERS + 1];
new Float:g_mvWorst[MAX_PLAYERS + 1];

// angles
new Float:g_anLastReport[MAX_PLAYERS + 1];
new Float:g_anSpinDeg[MAX_PLAYERS + 1];
new g_anSpinMs[MAX_PLAYERS + 1];
new g_anSpinSec[MAX_PLAYERS + 1];

// netcode
new Float:g_ncFrame[MAX_PLAYERS + 1];
new g_ncBatch[MAX_PLAYERS + 1];
new g_ncBig[MAX_PLAYERS + 1];
new Float:g_ncWindow[MAX_PLAYERS + 1];
new g_ncBatchShots[MAX_PLAYERS + 1];    // shots in the packet being counted
new g_lsShots[MAX_PLAYERS + 1], g_lsLagShots[MAX_PLAYERS + 1];
new g_lsCmds[MAX_PLAYERS + 1], g_lsLagCmds[MAX_PLAYERS + 1];

new Float:c_mRate, c_mSeconds, Float:c_mCv, Float:c_mPts;
new c_hStreak[HOP_KINDS], c_hClean[HOP_KINDS], Float:c_hRatio[HOP_KINDS], Float:c_hPtsStreak[HOP_KINDS], Float:c_hPtsClean[HOP_KINDS], Float:c_hPtsRatio[HOP_KINDS];
new c_stAirWindow, Float:c_stAutoRatio, c_stSwWindow, Float:c_stSwExact, Float:c_stPtsAuto, Float:c_stPtsSync;
new Float:c_spTolerance, Float:c_spCredit, Float:c_spPts;
new c_zStreakLen, c_zNeed, Float:c_zWindowSec, Float:c_zPts;
new c_mvWindow, c_mvSignNeed, Float:c_mvOverRatio, Float:c_mvPtsSign, Float:c_mvPtsOver;
new Float:c_anMaxPitch, Float:c_anPts, Float:c_anSpinDeg, c_anSpinSec, Float:c_anPtsSpin;
new c_ncBatch, c_ncNeed, Float:c_ncWindow, Float:c_ncPts;
new c_lsWindow, Float:c_lsShotRatio, Float:c_lsCmdRatio, Float:c_lsPts;

public plugin_init()
{
	register_plugin(PLUGIN, AMXAC_VERSION, AUTHOR);

	for (new Det:d = D_BHOP; d < Det; d++)
		register_det(d);

	bind_pcvar_num(create_cvar("amxac_bhop_streak", "10"), c_hStreak[H_JUMP]);
	bind_pcvar_num(create_cvar("amxac_bhop_clean_streak", "6"), c_hClean[H_JUMP]);
	bind_pcvar_float(create_cvar("amxac_bhop_ratio", "0.8"), c_hRatio[H_JUMP]);
	bind_pcvar_float(create_cvar("amxac_bhop_pts_streak", "8"), c_hPtsStreak[H_JUMP]);
	bind_pcvar_float(create_cvar("amxac_bhop_pts_clean", "15"), c_hPtsClean[H_JUMP]);
	bind_pcvar_float(create_cvar("amxac_bhop_pts_ratio", "6"), c_hPtsRatio[H_JUMP]);

	bind_pcvar_num(create_cvar("amxac_sgs_streak", "10"), c_hStreak[H_DUCK]);
	bind_pcvar_num(create_cvar("amxac_sgs_clean_streak", "6"), c_hClean[H_DUCK]);
	bind_pcvar_float(create_cvar("amxac_sgs_ratio", "0.8"), c_hRatio[H_DUCK]);
	bind_pcvar_float(create_cvar("amxac_sgs_pts_streak", "8"), c_hPtsStreak[H_DUCK]);
	bind_pcvar_float(create_cvar("amxac_sgs_pts_clean", "15"), c_hPtsClean[H_DUCK]);
	bind_pcvar_float(create_cvar("amxac_sgs_pts_ratio", "6"), c_hPtsRatio[H_DUCK]);

	bind_pcvar_float(create_cvar("amxac_macro_rate", "25", _, "Jump/duck presses per second considered spam"), c_mRate);
	bind_pcvar_num(create_cvar("amxac_macro_seconds", "3", _, "Seconds in a row at that rate"), c_mSeconds);
	bind_pcvar_float(create_cvar("amxac_macro_cv", "0.4", _, "Interval spread (std/mean) at or below this is a timer, not a hand"), c_mCv);
	bind_pcvar_float(create_cvar("amxac_macro_pts", "10"), c_mPts);

	bind_pcvar_num(create_cvar("amxac_strafe_air_window", "200"), c_stAirWindow);
	bind_pcvar_float(create_cvar("amxac_strafe_auto_ratio", "0.5"), c_stAutoRatio);
	bind_pcvar_num(create_cvar("amxac_strafe_switch_window", "40", _, "A/D switches per helper check"), c_stSwWindow);
	bind_pcvar_float(create_cvar("amxac_strafe_switch_exact", "0.9", _, "Share of switches on the exact reversal frame to report"), c_stSwExact);
	bind_pcvar_float(create_cvar("amxac_strafe_pts_auto", "15"), c_stPtsAuto);
	bind_pcvar_float(create_cvar("amxac_strafe_pts_sync", "10"), c_stPtsSync);

	bind_pcvar_float(create_cvar("amxac_speed_tolerance", "300"), c_spTolerance);
	bind_pcvar_float(create_cvar("amxac_speed_credit", "1000"), c_spCredit);
	bind_pcvar_float(create_cvar("amxac_speed_pts", "10"), c_spPts);
	bind_pcvar_num(create_cvar("amxac_zero_streak", "3", _, "msec = 0 cmds in a row that count as one fake-command burst"), c_zStreakLen);
	bind_pcvar_num(create_cvar("amxac_zero_need", "3", _, "Bursts within the window to report"), c_zNeed);
	bind_pcvar_float(create_cvar("amxac_zero_window", "5", _, "Window, seconds"), c_zWindowSec);
	bind_pcvar_float(create_cvar("amxac_zero_pts", "15"), c_zPts);

	bind_pcvar_num(create_cvar("amxac_move_window", "200", _, "Moving cmds per check"), c_mvWindow);
	bind_pcvar_num(create_cvar("amxac_move_sign_need", "3", _, "Cmds moving against the held key to report"), c_mvSignNeed);
	bind_pcvar_float(create_cvar("amxac_move_over_ratio", "0.2", _, "Share of cmds above maxspeed to report"), c_mvOverRatio);
	bind_pcvar_float(create_cvar("amxac_move_pts_sign", "15"), c_mvPtsSign);
	bind_pcvar_float(create_cvar("amxac_move_pts_over", "10"), c_mvPtsOver);

	bind_pcvar_float(create_cvar("amxac_angles_max_pitch", "89.9"), c_anMaxPitch);
	bind_pcvar_float(create_cvar("amxac_angles_pts", "20"), c_anPts);
	bind_pcvar_float(create_cvar("amxac_spin_deg", "2000"), c_anSpinDeg);
	bind_pcvar_num(create_cvar("amxac_spin_seconds", "2"), c_anSpinSec);
	bind_pcvar_float(create_cvar("amxac_spin_pts", "20"), c_anPtsSpin);

	bind_pcvar_num(create_cvar("amxac_net_batch", "12"), c_ncBatch);
	bind_pcvar_num(create_cvar("amxac_net_need", "8"), c_ncNeed);
	bind_pcvar_float(create_cvar("amxac_net_window", "10"), c_ncWindow);
	bind_pcvar_float(create_cvar("amxac_net_pts", "5"), c_ncPts);
	bind_pcvar_num(create_cvar("amxac_lagshot_window", "20", _, "Shots per lag-shot check"), c_lsWindow);
	bind_pcvar_float(create_cvar("amxac_lagshot_shot_ratio", "0.5", _, "Share of shots in choked packets to report"), c_lsShotRatio);
	bind_pcvar_float(create_cvar("amxac_lagshot_cmd_ratio", "0.15", _, "...while at most this share of all cmds is choked"), c_lsCmdRatio);
	bind_pcvar_float(create_cvar("amxac_lagshot_pts", "10"), c_lsPts);

	register_forward(FM_CmdStart, "fw_CmdStart");
	RegisterHam(Ham_Spawn, "player", "fw_Spawn_Post", 1);

	set_task(2.0, "task_refresh", TASK_REFRESH, _, _, "b");
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

public task_refresh()
{
	for (new id = 1; id <= MaxClients; id++)
		if (is_user_connected(id))
			g_monitored[id] = amxac_is_monitored(id);
}

public client_putinserver(id)
{
	g_monitored[id] = amxac_is_monitored(id);
	g_prevButtons[id] = 0;
	g_clientTime[id] = 0;
	hop_reset(id);
	g_stAir[id] = g_stNoKey[id] = 0;
	g_stCmd[id] = g_stYawSign[id] = g_stRevCmd[id] = g_stLastKey[id] = g_stSwitchCmd[id] = 0;
	g_stSwitches[id] = g_stExact[id] = 0;
	g_spStarted[id] = false;
	g_zStreak[id] = g_zEvents[id] = g_zCmds[id] = 0;
	g_zWindow[id] = get_gametime();
	g_zAvgMsec[id] = 10.0;
	g_mvCmds[id] = g_mvSign[id] = g_mvOver[id] = 0;
	g_mvLimit[id] = g_mvWorst[id] = 0.0;
	g_mvLimitTime[id] = 0.0;
	g_anLastReport[id] = -PITCH_COOLDOWN;
	g_anSpinDeg[id] = 0.0;
	g_anSpinMs[id] = g_anSpinSec[id] = 0;
	g_ncFrame[id] = 0.0;
	g_ncBatch[id] = g_ncBig[id] = g_ncBatchShots[id] = 0;
	g_lsShots[id] = g_lsLagShots[id] = g_lsCmds[id] = g_lsLagCmds[id] = 0;
	g_ncWindow[id] = get_gametime();
}

public client_disconnected(id)
{
	g_monitored[id] = false;
}

public fw_Spawn_Post(id)
{
	if (is_user_alive(id))
		hop_reset(id);
}

public fw_CmdStart(id, uc, seed)
{
	if (!g_monitored[id])
		return FMRES_IGNORED;

	new msec = get_uc(uc, UC_Msec);
	new now = g_clientTime[id];
	g_clientTime[id] += msec;

	// Timing checks run for the dead too: a speedhack doesn't stop at death.
	if (ON(D_SPEED))
		speed_on_cmd(id, msec);

	if (!is_user_alive(id))
		return FMRES_IGNORED;

	if (ON(D_SPEED))
		zero_on_cmd(id, msec);

	new buttons = get_uc(uc, UC_Buttons);
	new prev = g_prevButtons[id];
	g_prevButtons[id] = buttons;

	if (ON(D_NET))
		net_on_cmd(id, amxac_pressed(buttons, prev, IN_ATTACK));

	new Float:view[3];
	get_uc(uc, UC_ViewAngles, view);
	new Float:dyaw = amxac_wrap180(view[1] - g_prevYaw[id]);
	g_prevYaw[id] = view[1];

	if (ON(D_ANGLES))
		angles_on_cmd(id, amxac_wrap180(view[0]), dyaw, msec);   // pitch may arrive as [0, 360)

	new bool:special = amxac_on_ladder_or_water(id);
	new bool:onGround = (pev(id, pev_flags) & FL_ONGROUND) != 0;

	for (new k = H_JUMP; k < HOP_KINDS; k++)
	{
		if (!ON(Det:g_hopDet[k]))
			continue;
		new bool:pressed = amxac_pressed(buttons, prev, g_hopButton[k]);
		hop_on_cmd(k, id, special, onGround, pressed);
		macro_on_cmd(k, id, pressed, now, msec);
	}
	if (ON(D_STRAFE) && !special && !onGround)
		strafe_on_cmd(id, uc, buttons, dyaw);
	if (ON(D_MOVE))
		movecheck_on_cmd(id, uc, buttons);

	return FMRES_IGNORED;
}

// ---------------------------------------------------------------------------
// bhop / sgs
// "Perfect" press: on the very first cmd on the ground. "Clean" perfect: no
// presses of that button in the air before landing (wheel users spam it,
// scripts press once). For +duck this is the SGS / ducktap script: a ducktap
// lifts the player off the ground, so ducktap chains land and take off just
// like bhops.
// ---------------------------------------------------------------------------

hop_reset(id)
{
	for (new k = H_JUMP; k < HOP_KINDS; k++)
	{
		g_hGround[k][id] = g_hAirPresses[k][id] = 0;
		g_hStreak[k][id] = g_hClean[k][id] = 0;
		g_hPos[k][id] = g_hLen[k][id] = 0;
		macro_reset(k, id);
	}
}

macro_reset(k, id)
{
	g_mPresses[k][id] = g_mBucket[k][id] = g_mLast[k][id] = 0;
	g_mSeconds[k][id] = g_mN[k][id] = 0;
	g_mSum[k][id] = g_mSq[k][id] = 0.0;
}

// Timer macros (AHK and the like) tap the button every N ms no matter where the
// player is, so the perfect-landing check never sees them. They show up as a
// press rate a hand can't hold for seconds, with near-constant intervals.
// A scroll wheel gives bursts: high rate for a fraction of a second, then a gap.
// Intervals are quantized to client frames (10 ms at 100 fps), so a 17 ms timer
// reads as 10/20/20/10...: spread ~0.3 of the mean. Hands are well above 0.5.
macro_on_cmd(k, id, bool:pressed, now, msec)
{
	g_mBucket[k][id] += msec;
	if (pressed)
	{
		g_mPresses[k][id]++;
		if (g_mLast[k][id] > 0)
		{
			new Float:iv = float(now - g_mLast[k][id]);
			g_mSum[k][id] += iv;
			g_mSq[k][id] += iv * iv;
			g_mN[k][id]++;
		}
		g_mLast[k][id] = now;
	}

	if (g_mBucket[k][id] < 1000)
		return;

	new Float:rate = float(g_mPresses[k][id]) * 1000.0 / float(g_mBucket[k][id]);
	g_mPresses[k][id] = g_mBucket[k][id] = 0;

	if (rate < c_mRate)
	{
		macro_reset(k, id);
		return;
	}

	new Det:d = Det:g_hopDet[k];
	new Float:n = float(max(g_mN[k][id], 1));
	new Float:mean = g_mSum[k][id] / n;
	new Float:std = floatsqroot(floatmax(g_mSq[k][id] / n - mean * mean, 0.0));
	new Float:cv = mean > 0.0 ? std / mean : 1.0;
	g_mSeconds[k][id]++;
	amxac_debug(id, "%s macro: %.0f presses/s, second %d/%d, interval %.1f +/- %.1f ms (spread %.2f, report at <= %.2f)",
		g_detName[d], rate, g_mSeconds[k][id], c_mSeconds, mean, std, cv, c_mCv);

	if (g_mSeconds[k][id] < c_mSeconds)
		return;

	if (cv <= c_mCv)
		amxac_report(id, g_mod[d], c_mPts, "%s pressed %.0f times/s for %d s, every %.0f +/- %.0f ms (macro)",
			k == H_JUMP ? "jump" : "duck", rate, g_mSeconds[k][id], mean, std);
	macro_reset(k, id);
}

hop_on_cmd(k, id, bool:special, bool:onGround, bool:pressed)
{
	if (special)
	{
		g_hGround[k][id] = g_hAirPresses[k][id] = 0;
		return;
	}

	// Flags reflect the state after the previous cmd, i.e. before this one moves.
	if (!onGround)
	{
		if (g_hGround[k][id] > 0)
			g_hAirPresses[k][id] = 0;   // just took off
		g_hGround[k][id] = 0;
		if (pressed)
			g_hAirPresses[k][id]++;
		return;
	}

	g_hGround[k][id]++;
	if (!pressed)
		return;

	if (g_hGround[k][id] > 10)
	{
		g_hStreak[k][id] = g_hClean[k][id] = 0;   // from standing (or crouching to walk), not a chain
		return;
	}

	new Det:d = Det:g_hopDet[k];
	new bool:perfect = g_hGround[k][id] == 1;
	new bool:clean = perfect && g_hAirPresses[k][id] == 0;
	g_hStreak[k][id] = perfect ? g_hStreak[k][id] + 1 : 0;
	g_hClean[k][id] = clean ? g_hClean[k][id] + 1 : 0;
	amxac_debug(id, "%s: pressed on ground cmd %d, %d air presses, streak %d/%d, clean %d/%d",
		g_detName[d], g_hGround[k][id], g_hAirPresses[k][id], g_hStreak[k][id], c_hStreak[k], g_hClean[k][id], c_hClean[k]);

	g_hWin[k][id][g_hPos[k][id]] = perfect ? 1 : 0;
	g_hPos[k][id] = (g_hPos[k][id] + 1) % HOP_WINDOW;
	if (g_hLen[k][id] < HOP_WINDOW)
		g_hLen[k][id]++;

	if (c_hClean[k] > 0 && g_hClean[k][id] >= c_hClean[k])
	{
		amxac_report(id, g_mod[d], c_hPtsClean[k], "%d clean perfect %s in a row", g_hClean[k][id], g_hopWord[k]);
		g_hClean[k][id] = g_hStreak[k][id] = 0;
	}
	else if (c_hStreak[k] > 0 && g_hStreak[k][id] >= c_hStreak[k])
	{
		amxac_report(id, g_mod[d], c_hPtsStreak[k], "%d perfect %s in a row", g_hStreak[k][id], g_hopWord[k]);
		g_hStreak[k][id] = 0;
	}

	if (g_hLen[k][id] == HOP_WINDOW)
	{
		new hits = 0;
		for (new i = 0; i < HOP_WINDOW; i++)
			hits += g_hWin[k][id][i];
		if (float(hits) / float(HOP_WINDOW) >= c_hRatio[k])
		{
			amxac_report(id, g_mod[d], c_hPtsRatio[k], "%d/%d perfect %s", hits, HOP_WINDOW, g_hopWord[k]);
			g_hLen[k][id] = 0;
		}
	}
}

// ---------------------------------------------------------------------------
// strafe (air only)
// ---------------------------------------------------------------------------

strafe_on_cmd(id, uc, buttons, Float:dyaw)
{
	new Float:side;
	get_uc(uc, UC_SideMove, side);
	new bool:left = (buttons & IN_MOVELEFT) != 0;
	new bool:right = (buttons & IN_MOVERIGHT) != 0;

	g_stAir[id]++;
	// A key released mid-frame still leaves a fractional sidemove without its
	// button bit, once per strafe switch; that's a few percent, far below the ratio.
	if (side != 0.0 && !left && !right)
		g_stNoKey[id]++;

	if (g_stAir[id] >= c_stAirWindow)
	{
		new Float:ratio = float(g_stNoKey[id]) / float(g_stAir[id]);
		amxac_debug(id, "strafe: keyless sidemove %.0f%% of %d air cmds (report at %.0f%%)", ratio * 100.0, g_stAir[id], c_stAutoRatio * 100.0);
		if (ratio >= c_stAutoRatio)
			amxac_report(id, g_mod[D_STRAFE], c_stPtsAuto, "sidemove without strafe keys on %.0f%% of %d air cmds", ratio * 100.0, g_stAir[id]);
		g_stAir[id] = g_stNoKey[id] = 0;
	}

	// Strafe helper. Plain sync (mouse direction matches the key) can't tell a
	// good bhopper from a helper: at the moment the mouse turns around it barely
	// moves, so the few frames where a human is off don't show. What does show is
	// timing: a human hits the key switch within a couple of frames of the mouse
	// reversal, sometimes early, sometimes late. A helper switches on that exact
	// frame every time.
	new cmd = ++g_stCmd[id];

	if (floatabs(dyaw) > 0.01)
	{
		new sign = dyaw > 0.0 ? 1 : -1;
		if (g_stYawSign[id] != 0 && sign != g_stYawSign[id])
		{
			g_stRevCmd[id] = cmd;
			if (g_stSwitchCmd[id])
				g_stSwitchBest[id] = min(g_stSwitchBest[id], cmd - g_stSwitchCmd[id]);
		}
		g_stYawSign[id] = sign;
	}

	new key = (left && !right) ? -1 : ((right && !left) ? 1 : 0);
	if (key != 0)
	{
		if (g_stLastKey[id] != 0 && key != g_stLastKey[id])
		{
			if (g_stSwitchCmd[id])
				strafe_switch_done(id);
			g_stSwitchCmd[id] = cmd;
			g_stSwitchBest[id] = g_stRevCmd[id] ? cmd - g_stRevCmd[id] : 99;   // reversal before the switch
		}
		g_stLastKey[id] = key;
	}

	// Give the reversal up to 5 cmds after the switch to show up.
	if (g_stSwitchCmd[id] && cmd - g_stSwitchCmd[id] >= 5)
		strafe_switch_done(id);
}

strafe_switch_done(id)
{
	new best = g_stSwitchBest[id];
	g_stSwitchCmd[id] = 0;
	if (best > 5)
		return;   // the mouse wasn't turning around here, not a strafe switch

	g_stSwitches[id]++;
	if (best == 0)
		g_stExact[id]++;

	if (g_stSwitches[id] < c_stSwWindow)
		return;

	new Float:exact = float(g_stExact[id]) / float(g_stSwitches[id]);
	amxac_debug(id, "strafe: %d/%d key switches on the exact reversal frame (%.0f%%, report at %.0f%%)",
		g_stExact[id], g_stSwitches[id], exact * 100.0, c_stSwExact * 100.0);
	if (exact >= c_stSwExact)
		amxac_report(id, g_mod[D_STRAFE], c_stPtsSync, "%d of %d A/D switches on the exact frame the mouse turned (strafe helper)", g_stExact[id], g_stSwitches[id]);
	g_stSwitches[id] = g_stExact[id] = 0;
}

// ---------------------------------------------------------------------------
// speedhack: timer balance = sum of msec minus real time, clamped below
// ---------------------------------------------------------------------------

speed_on_cmd(id, msec)
{
	new Float:now = get_gametime();
	if (!g_spStarted[id])
	{
		g_spStarted[id] = true;
		g_spBalance[id] = 0.0;
		g_spLast[id] = now;
		return;
	}

	g_spBalance[id] += float(msec) - (now - g_spLast[id]) * 1000.0;
	g_spLast[id] = now;

	if (g_spBalance[id] < -c_spCredit)
		g_spBalance[id] = -c_spCredit;

	if (g_spBalance[id] > c_spTolerance)
	{
		amxac_report(id, g_mod[D_SPEED], c_spPts, "client clock %.0f ms ahead of server", g_spBalance[id]);
		g_spBalance[id] = 0.0;
	}
}

// ---------------------------------------------------------------------------
// angles
// ---------------------------------------------------------------------------

angles_on_cmd(id, Float:pitch, Float:dyaw, msec)
{
	if (floatabs(pitch) > c_anMaxPitch)
	{
		new Float:now = get_gametime();
		if (now - g_anLastReport[id] >= PITCH_COOLDOWN)
		{
			g_anLastReport[id] = now;
			amxac_report(id, g_mod[D_ANGLES], c_anPts, "pitch %.1f outside [-%.1f, %.1f]", pitch, c_anMaxPitch, c_anMaxPitch);
		}
	}

	g_anSpinDeg[id] += floatabs(dyaw);
	g_anSpinMs[id] += msec;
	if (g_anSpinMs[id] < 1000)
		return;

	new Float:rate = g_anSpinDeg[id] * 1000.0 / float(g_anSpinMs[id]);
	g_anSpinDeg[id] = 0.0;
	g_anSpinMs[id] = 0;

	if (rate < c_anSpinDeg)
	{
		g_anSpinSec[id] = 0;
		return;
	}
	if (++g_anSpinSec[id] >= c_anSpinSec)
	{
		amxac_report(id, g_mod[D_ANGLES], c_anPtsSpin, "yaw spinning at %.0f deg/s for %d s", rate, g_anSpinSec[id]);
		g_anSpinSec[id] = 0;
	}
}

// ---------------------------------------------------------------------------
// netcode: cmds of one packet all run in the same server frame
// ---------------------------------------------------------------------------

net_on_cmd(id, bool:shot)
{
	new Float:now = get_gametime();
	if (now == g_ncFrame[id])
	{
		g_ncBatch[id]++;
		if (shot)
			g_ncBatchShots[id]++;
		return;
	}

	// The previous packet is complete.
	new bool:big = g_ncBatch[id] >= c_ncBatch;
	if (big)
		g_ncBig[id]++;
	lagshot_on_packet(id, g_ncBatch[id], g_ncBatchShots[id], big);

	g_ncFrame[id] = now;
	g_ncBatch[id] = 1;
	g_ncBatchShots[id] = shot ? 1 : 0;

	if (now - g_ncWindow[id] < c_ncWindow)
		return;

	if (g_ncBig[id] >= c_ncNeed)
		amxac_report(id, g_mod[D_NET], c_ncPts, "%d choked packets (%d+ cmds each) in %.0f s", g_ncBig[id], c_ncBatch, now - g_ncWindow[id]);
	g_ncBig[id] = 0;
	g_ncWindow[id] = now;
}

// ---------------------------------------------------------------------------
// speedhack: fake commands
// A real client always simulates some time per cmd (msec >= 1 up to 1000 fps).
// Several msec = 0 cmds in a row are made up: they move nothing on the clock
// but still run weapons and inputs, which some speed/rapid-fire hacks abuse.
// The timer balance above can't see them, they add no time.
// ---------------------------------------------------------------------------

zero_on_cmd(id, msec)
{
	g_zCmds[id]++;
	if (msec == 0)
	{
		// Above ~1000 fps (fps_override on some builds) frames shorter than 1 ms
		// truncate to msec 0 for real. Only a client that otherwise runs at a
		// normal frame rate is suspicious.
		if (++g_zStreak[id] == c_zStreakLen && g_zAvgMsec[id] >= 4.0)
			g_zEvents[id]++;
	}
	else
	{
		g_zStreak[id] = 0;
		g_zAvgMsec[id] += (float(msec) - g_zAvgMsec[id]) * 0.05;
	}

	new Float:now = get_gametime();
	if (now - g_zWindow[id] < c_zWindowSec)
		return;

	if (g_zEvents[id])
		amxac_debug(id, "speedhack: %d bursts of %d+ zero-msec cmds in %.0f s (report at %d)", g_zEvents[id], c_zStreakLen, now - g_zWindow[id], c_zNeed);
	if (g_zEvents[id] >= c_zNeed)
		amxac_report(id, g_mod[D_SPEED], c_zPts, "%d bursts of %d+ cmds with msec 0 in %.0f s (fake commands)", g_zEvents[id], c_zStreakLen, now - g_zWindow[id]);

	g_zEvents[id] = g_zCmds[id] = 0;
	g_zWindow[id] = now;
}

// ---------------------------------------------------------------------------
// movecheck
// The client builds forward/side/upmove from the keys (cl_forwardspeed etc.
// times the key fraction) and then scales the vector down to the maxspeed the
// server sent it. So a real client never sends:
//   - movement against the only key held (A held, sidemove to the right);
//   - a movement vector longer than maxspeed.
// maxspeed changes (weapon switch, scope, freezetime) reach the client one ping
// later, so the limit is the highest maxspeed of the last second.
// cl_forwardspeed/cl_sidespeed set negative would flip signs too; that's not a
// default setup, so it scores like a hack.
// ---------------------------------------------------------------------------

movecheck_on_cmd(id, uc, buttons)
{
	new Float:fwd, Float:side, Float:up;
	get_uc(uc, UC_ForwardMove, fwd);
	get_uc(uc, UC_SideMove, side);
	get_uc(uc, UC_UpMove, up);
	if (fwd == 0.0 && side == 0.0 && up == 0.0)
		return;

	new bool:kl = (buttons & IN_MOVELEFT) != 0, bool:kr = (buttons & IN_MOVERIGHT) != 0;
	new bool:kf = (buttons & IN_FORWARD) != 0, bool:kb = (buttons & IN_BACK) != 0;

	g_mvCmds[id]++;
	if ((kl && !kr && side > 1.0) || (kr && !kl && side < -1.0) || (kf && !kb && fwd < -1.0) || (kb && !kf && fwd > 1.0))
		g_mvSign[id]++;

	new Float:now = get_gametime();
	new Float:maxspeed;
	pev(id, pev_maxspeed, maxspeed);
	if (maxspeed >= g_mvLimit[id] || now - g_mvLimitTime[id] > 1.0)
	{
		g_mvLimit[id] = maxspeed;
		g_mvLimitTime[id] = now;
	}

	// maxspeed 0 means the client doesn't clamp at all.
	if (g_mvLimit[id] > 0.0)
	{
		new Float:len = floatsqroot(fwd * fwd + side * side + up * up);
		if (len > g_mvLimit[id] * 1.01 + 1.0)
		{
			g_mvOver[id]++;
			g_mvWorst[id] = floatmax(g_mvWorst[id], len / g_mvLimit[id]);
		}
	}

	if (g_mvCmds[id] < c_mvWindow)
		return;

	new Float:overRatio = float(g_mvOver[id]) / float(g_mvCmds[id]);
	amxac_debug(id, "movecheck: %d/%d against the key (report at %d), %.0f%% above maxspeed (report at %.0f%%, worst x%.2f)",
		g_mvSign[id], g_mvCmds[id], c_mvSignNeed, overRatio * 100.0, c_mvOverRatio * 100.0, g_mvWorst[id]);

	if (g_mvSign[id] >= c_mvSignNeed)
		amxac_report(id, g_mod[D_MOVE], c_mvPtsSign, "%d of %d cmds moved against the only key held", g_mvSign[id], g_mvCmds[id]);
	else if (overRatio >= c_mvOverRatio)
		amxac_report(id, g_mod[D_MOVE], c_mvPtsOver, "%.0f%% of %d cmds above maxspeed (up to x%.2f)", overRatio * 100.0, g_mvCmds[id], g_mvWorst[id]);

	g_mvCmds[id] = g_mvSign[id] = g_mvOver[id] = 0;
	g_mvWorst[id] = 0.0;
}

// Lag shot (idea from UnrealDemoScanner "AIM TYPE 4"): the cheat chokes packets
// right when it shoots, so the shot reaches the server late and gets
// lag-compensated further back (backtrack). A bad connection chokes at random,
// so shots end up in choked packets about as often as any other cmd.
lagshot_on_packet(id, cmds, shots, bool:big)
{
	g_lsCmds[id] += cmds;
	g_lsShots[id] += shots;
	if (big)
	{
		g_lsLagCmds[id] += cmds;
		g_lsLagShots[id] += shots;
	}

	if (g_lsShots[id] < c_lsWindow)
		return;

	new Float:shotRatio = float(g_lsLagShots[id]) / float(g_lsShots[id]);
	new Float:cmdRatio = float(g_lsLagCmds[id]) / float(max(g_lsCmds[id], 1));
	amxac_debug(id, "netcode: %.0f%% of shots and %.0f%% of cmds in choked packets (report at %.0f%% / <= %.0f%%)",
		shotRatio * 100.0, cmdRatio * 100.0, c_lsShotRatio * 100.0, c_lsCmdRatio * 100.0);

	if (shotRatio >= c_lsShotRatio && cmdRatio <= c_lsCmdRatio)
		amxac_report(id, g_mod[D_NET], c_lsPts, "%d of %d shots arrived in choked packets, only %.0f%% of other cmds did (lag shot)",
			g_lsLagShots[id], g_lsShots[id], cmdRatio * 100.0);

	g_lsShots[id] = g_lsLagShots[id] = g_lsCmds[id] = g_lsLagCmds[id] = 0;
}
