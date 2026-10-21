// AMXAC Core: suspicion scoring, decay, levels, admin notifications, logging.
// Detectors are separate plugins that talk to the core through amxac.inc.

#include <amxmodx>
#include <amxmisc>
#include <amxac>

#define PLUGIN  "AMXAC Core"
#define AUTHOR  "AMXAC"

#define TASK_DECAY  91001

new g_modCount;
new g_modName[AMXAC_MAX_MODULES][32];
new g_modVersion[AMXAC_MAX_MODULES][16];
new g_modAuthor[AMXAC_MAX_MODULES][32];
new g_modWeight[AMXAC_MAX_MODULES];   // pcvar

new Float:g_score[MAX_PLAYERS + 1][AMXAC_MAX_MODULES];
new g_hits[MAX_PLAYERS + 1][AMXAC_MAX_MODULES];
new AcLevel:g_level[MAX_PLAYERS + 1];
new bool:g_actionDone[MAX_PLAYERS + 1];
new Float:g_ignoreAll[MAX_PLAYERS + 1];                       // gametime until which all reports are dropped
new Float:g_ignore[MAX_PLAYERS + 1][AMXAC_MAX_MODULES];       // same, per module

new g_fwdReport, g_fwdLevel;
new g_logFile[64];

new Float:c_halflife, Float:c_warn, Float:c_alert, Float:c_action;
new c_actionCmd[256], c_adminFlag[24], c_immunityFlag[24];
new c_includeBots, c_notifyReports, c_log;

new const g_levelName[AcLevel][] = { "none", "WARN", "ALERT", "ACTION" };

public plugin_natives()
{
	register_library("amxac");

	register_native("amxac_register_module", "native_register_module");
	register_native("amxac_report", "native_report");
	register_native("amxac_get_score", "native_get_score");
	register_native("amxac_get_level", "native_get_level");
	register_native("amxac_is_monitored", "native_is_monitored");
	register_native("amxac_reset", "native_reset");
	register_native("amxac_log", "native_log");
	register_native("amxac_notify", "native_notify");
	register_native("amxac_set_ignore", "native_set_ignore");
	register_native("amxac_get_top_module", "native_get_top_module");
}

public plugin_init()
{
	register_plugin(PLUGIN, AMXAC_VERSION, AUTHOR);
	create_cvar("amxac_version", AMXAC_VERSION, FCVAR_SERVER | FCVAR_SPONLY);

	bind_pcvar_float(create_cvar("amxac_halflife", "120", _, "Seconds for a score to decay by half", true, 1.0), c_halflife);
	bind_pcvar_float(create_cvar("amxac_warn", "30", _, "Score to log a WARN"), c_warn);
	bind_pcvar_float(create_cvar("amxac_alert", "60", _, "Score to notify admins"), c_alert);
	bind_pcvar_float(create_cvar("amxac_action", "100", _, "Score to run amxac_action_cmd"), c_action);
	bind_pcvar_string(create_cvar("amxac_action_cmd", "", _, "Server command on ACTION. Placeholders: %userid% %name% %steamid% %ip% %score% %module%"), c_actionCmd, charsmax(c_actionCmd));
	bind_pcvar_string(create_cvar("amxac_admin_flag", "d", _, "Admin flags that receive notifications"), c_adminFlag, charsmax(c_adminFlag));
	bind_pcvar_string(create_cvar("amxac_immunity_flag", "", _, "Players with these flags are not monitored (empty = nobody)"), c_immunityFlag, charsmax(c_immunityFlag));
	bind_pcvar_num(create_cvar("amxac_include_bots", "0", _, "Monitor bots (for testing)"), c_includeBots);
	bind_pcvar_num(create_cvar("amxac_notify_reports", "0", _, "Show every single report to admins, not only level changes"), c_notifyReports);
	create_cvar("amxac_debug", "0", _, "Print detector internals to the tested player's console (rcon-flag players only)");
	bind_pcvar_num(create_cvar("amxac_log", "1", _, "Write reports to logs/amxac_YYYYMMDD.log"), c_log);

	g_fwdReport = CreateMultiForward("amxac_on_report", ET_STOP, FP_CELL, FP_CELL, FP_FLOAT, FP_STRING);
	g_fwdLevel = CreateMultiForward("amxac_on_level", ET_IGNORE, FP_CELL, FP_CELL, FP_FLOAT);

	register_concmd("amx_ac_status", "cmd_status", ADMIN_KICK, "[target] - suspicion scores");
	register_concmd("amx_ac_reset", "cmd_reset", ADMIN_BAN, "<target> - clear a player's score");
	register_concmd("amx_ac_modules", "cmd_modules", ADMIN_KICK, "- list loaded detector modules");

	set_task(1.0, "task_decay", TASK_DECAY, _, _, "b");
}

public plugin_cfg()
{
	get_time("amxac_%Y%m%d.log", g_logFile, charsmax(g_logFile));

	new path[128];
	get_configsdir(path, charsmax(path));
	format(path, charsmax(path), "%s/amxac.cfg", path);
	if (file_exists(path))
		server_cmd("exec %s", path);
}

public client_putinserver(id)
{
	reset_player(id, -1);
	g_ignoreAll[id] = 0.0;
	for (new m = 0; m < AMXAC_MAX_MODULES; m++)
		g_ignore[id][m] = 0.0;
}

public client_disconnected(id)
{
	new Float:total = total_score(id);
	if (total >= c_warn)
	{
		new info[128];
		player_info(id, info, charsmax(info));
		ac_log("DISCONNECT %s left with score %.1f (%s)", info, total, g_levelName[g_level[id]]);
	}
	reset_player(id, -1);
}

// ---------------------------------------------------------------------------
// Scoring
// ---------------------------------------------------------------------------

public task_decay()
{
	new Float:factor = floatpower(0.5, 1.0 / c_halflife);
	new players[MAX_PLAYERS], num;
	get_players(players, num, "h");

	for (new i = 0; i < num; i++)
	{
		new id = players[i];
		for (new m = 0; m < g_modCount; m++)
		{
			g_score[id][m] *= factor;
			if (g_score[id][m] < 0.01)
				g_score[id][m] = 0.0;
		}
		update_level(id);
	}
}

Float:total_score(id)
{
	new Float:total = 0.0;
	for (new m = 0; m < g_modCount; m++)
		total += g_score[id][m];
	return total;
}

AcLevel:level_for(Float:score)
{
	if (score >= c_action) return AC_LEVEL_ACTION;
	if (score >= c_alert) return AC_LEVEL_ALERT;
	if (score >= c_warn) return AC_LEVEL_WARN;
	return AC_LEVEL_NONE;
}

Float:level_threshold(AcLevel:level)
{
	switch (level)
	{
		case AC_LEVEL_WARN: return c_warn;
		case AC_LEVEL_ALERT: return c_alert;
		case AC_LEVEL_ACTION: return c_action;
	}
	return 0.0;
}

update_level(id)
{
	new Float:total = total_score(id);
	new AcLevel:target = level_for(total);

	if (target > g_level[id])
	{
		g_level[id] = target;
		on_level_up(id, target, total);
		return;
	}

	// Hysteresis: drop a level only once the score falls well below its threshold,
	// so a player hovering around a threshold doesn't spam notifications.
	while (g_level[id] > AC_LEVEL_NONE && total < level_threshold(g_level[id]) * 0.7)
		g_level[id] = AcLevel:(_:g_level[id] - 1);

	if (g_level[id] < AC_LEVEL_ACTION)
		g_actionDone[id] = false;
}

on_level_up(id, AcLevel:level, Float:total)
{
	new info[128], top[32];
	player_info(id, info, charsmax(info));
	top_module(id, top, charsmax(top));

	ac_log("LEVEL %s %s score %.1f (top module: %s)", g_levelName[level], info, total, top);

	if (level >= AC_LEVEL_ALERT)
	{
		new name[32];
		get_user_name(id, name, charsmax(name));
		notify_admins("^4%s^1 %s: ^3%s^1 score ^4%.0f^1 (%s)", AMXAC_TAG, g_levelName[level], name, total, top);
	}

	if (level == AC_LEVEL_ACTION && !g_actionDone[id] && c_actionCmd[0])
	{
		g_actionDone[id] = true;
		run_action(id, total, top);
	}

	new ret;
	ExecuteForward(g_fwdLevel, ret, id, level, total);
}

run_action(id, Float:total, const top[])
{
	new cmd[256], buf[64];
	copy(cmd, charsmax(cmd), c_actionCmd);

	num_to_str(get_user_userid(id), buf, charsmax(buf));
	replace_string(cmd, charsmax(cmd), "%userid%", buf);

	get_user_name(id, buf, charsmax(buf));
	amxac_sanitize(buf);
	replace_string(cmd, charsmax(cmd), "%name%", buf);

	get_user_authid(id, buf, charsmax(buf));
	amxac_sanitize(buf);
	replace_string(cmd, charsmax(cmd), "%steamid%", buf);

	get_user_ip(id, buf, charsmax(buf), 1);
	replace_string(cmd, charsmax(cmd), "%ip%", buf);

	formatex(buf, charsmax(buf), "%.0f", total);
	replace_string(cmd, charsmax(cmd), "%score%", buf);

	replace_string(cmd, charsmax(cmd), "%module%", top);

	ac_log("ACTION running: %s", cmd);
	server_cmd("%s", cmd);
}

top_module(id, out[], len)
{
	new best = -1;
	new Float:bestScore = 0.0;
	for (new m = 0; m < g_modCount; m++)
	{
		if (g_score[id][m] > bestScore)
		{
			bestScore = g_score[id][m];
			best = m;
		}
	}
	copy(out, len, best == -1 ? "-" : g_modName[best]);
}

reset_player(id, module)
{
	if (module == -1)
	{
		for (new m = 0; m < AMXAC_MAX_MODULES; m++)
		{
			g_score[id][m] = 0.0;
			g_hits[id][m] = 0;
		}
		g_level[id] = AC_LEVEL_NONE;
		g_actionDone[id] = false;
	}
	else
	{
		g_score[id][module] = 0.0;
		g_hits[id][module] = 0;
		update_level(id);
	}
}

bool:is_monitored(id)
{
	if (id < 1 || id > MaxClients || !is_user_connected(id) || is_user_hltv(id))
		return false;
	if (is_user_bot(id) && !c_includeBots)
		return false;
	if (c_immunityFlag[0] && (get_user_flags(id) & read_flags(c_immunityFlag)))
		return false;
	return true;
}

// ---------------------------------------------------------------------------
// Natives
// ---------------------------------------------------------------------------

public native_register_module(plugin, params)
{
	new name[32];
	get_string(1, name, charsmax(name));
	strtolower(name);

	for (new m = 0; m < g_modCount; m++)
	{
		if (equal(g_modName[m], name))
			return m;   // plugin reloaded on map change
	}

	if (g_modCount >= AMXAC_MAX_MODULES || !name[0])
	{
		log_error(AMX_ERR_NATIVE, "Cannot register module ^"%s^"", name);
		return -1;
	}

	new m = g_modCount++;
	copy(g_modName[m], charsmax(g_modName[]), name);
	get_string(2, g_modVersion[m], charsmax(g_modVersion[]));
	get_string(3, g_modAuthor[m], charsmax(g_modAuthor[]));

	new cvar[48], desc[64];
	formatex(cvar, charsmax(cvar), "amxac_w_%s", name);
	formatex(desc, charsmax(desc), "Score multiplier for module %s (0 = mute)", name);
	g_modWeight[m] = create_cvar(cvar, "1.0", _, desc, true, 0.0);

	return m;
}

public native_report(plugin, params)
{
	new id = get_param(1);
	new module = get_param(2);
	new Float:points = get_param_f(3);

	if (module < 0 || module >= g_modCount)
	{
		log_error(AMX_ERR_NATIVE, "Invalid module id %d", module);
		return 0;
	}
	if (!is_monitored(id))
		return 0;

	// Another plugin asked to ignore this player (teleport, speed boost, ...).
	new Float:now = get_gametime();
	if (now < g_ignoreAll[id] || now < g_ignore[id][module])
		return 0;

	new reason[192];
	vdformat(reason, charsmax(reason), 4, 5);

	new ret;
	ExecuteForward(g_fwdReport, ret, id, module, points, reason);
	if (ret == PLUGIN_HANDLED)
		return 0;

	new Float:weight = get_pcvar_float(g_modWeight[module]);
	new Float:applied = points * weight;

	g_score[id][module] += applied;
	g_hits[id][module]++;

	new info[128];
	player_info(id, info, charsmax(info));
	ac_log("REPORT [%s] %s +%.1f (total %.1f): %s", g_modName[module], info, applied, total_score(id), reason);

	if (c_notifyReports && applied > 0.0)
	{
		new name[32];
		get_user_name(id, name, charsmax(name));
		notify_admins("^4%s^1 [%s] ^3%s^1 +%.1f: %s", AMXAC_TAG, g_modName[module], name, applied, reason);
	}

	update_level(id);
	return 1;
}

public Float:native_get_score(plugin, params)
{
	new id = get_param(1);
	new module = get_param(2);
	if (id < 1 || id > MaxClients)
		return 0.0;
	if (module == -1)
		return total_score(id);
	if (module < 0 || module >= g_modCount)
		return 0.0;
	return g_score[id][module];
}

public AcLevel:native_get_level(plugin, params)
{
	new id = get_param(1);
	if (id < 1 || id > MaxClients)
		return AC_LEVEL_NONE;
	return g_level[id];
}

public bool:native_is_monitored(plugin, params)
{
	return is_monitored(get_param(1));
}

public native_reset(plugin, params)
{
	new id = get_param(1);
	new module = get_param(2);
	if (id < 1 || id > MaxClients || module < -1 || module >= g_modCount)
		return 0;
	reset_player(id, module);
	return 1;
}

public native_set_ignore(plugin, params)
{
	new id = get_param(1);
	new module = get_param(2);
	new Float:seconds = get_param_f(3);
	if (id < 1 || id > MaxClients || module < -1 || module >= g_modCount)
		return 0;

	// < 0: until disconnect; 0: stop ignoring.
	new Float:until = seconds < 0.0 ? 999999999.0 : (seconds == 0.0 ? 0.0 : get_gametime() + seconds);
	if (module == -1)
		g_ignoreAll[id] = until;
	else
		g_ignore[id][module] = until;
	return 1;
}

public native_get_top_module(plugin, params)
{
	new id = get_param(1);
	new name[32];
	if (id < 1 || id > MaxClients)
		name = "-";
	else
		top_module(id, name, charsmax(name));
	set_string(2, name, get_param(3));
	return 1;
}

public native_log(plugin, params)
{
	new msg[320];
	vdformat(msg, charsmax(msg), 1, 2);
	ac_log("%s", msg);
}

public native_notify(plugin, params)
{
	new msg[191];
	vdformat(msg, charsmax(msg), 1, 2);
	notify_admins("%s", msg);
}

// ---------------------------------------------------------------------------
// Admin commands
// ---------------------------------------------------------------------------

public cmd_status(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	if (read_argc() >= 2)
	{
		new arg[32];
		read_argv(1, arg, charsmax(arg));
		new target = cmd_target(id, arg, CMDTARGET_ALLOW_SELF);
		if (!target)
			return PLUGIN_HANDLED;

		new name[32];
		get_user_name(target, name, charsmax(name));
		console_print(id, "%s %s: total %.1f, level %s", AMXAC_TAG, name, total_score(target), g_levelName[g_level[target]]);
		for (new m = 0; m < g_modCount; m++)
		{
			if (g_hits[target][m])
				console_print(id, "  %-16s score %6.1f  hits %d", g_modName[m], g_score[target][m], g_hits[target][m]);
		}
		return PLUGIN_HANDLED;
	}

	console_print(id, "%s %-24s %8s %-7s %s", AMXAC_TAG, "name", "score", "level", "top");
	new players[MAX_PLAYERS], num, name[32], top[32];
	get_players(players, num, "h");
	for (new i = 0; i < num; i++)
	{
		new p = players[i];
		get_user_name(p, name, charsmax(name));
		top_module(p, top, charsmax(top));
		console_print(id, "%s %-24s %8.1f %-7s %s", AMXAC_TAG, name, total_score(p), g_levelName[g_level[p]], top);
	}
	return PLUGIN_HANDLED;
}

public cmd_reset(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new arg[32];
	read_argv(1, arg, charsmax(arg));
	new target = cmd_target(id, arg, CMDTARGET_ALLOW_SELF);
	if (!target)
		return PLUGIN_HANDLED;

	reset_player(target, -1);

	new name[32], admin[32];
	get_user_name(target, name, charsmax(name));
	get_user_name(id, admin, charsmax(admin));
	ac_log("RESET %s by %s", name, id ? admin : "server");
	console_print(id, "%s Score of %s cleared", AMXAC_TAG, name);
	return PLUGIN_HANDLED;
}

public cmd_modules(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	console_print(id, "%s %d module(s):", AMXAC_TAG, g_modCount);
	for (new m = 0; m < g_modCount; m++)
		console_print(id, "  %-16s v%-8s weight %.2f  %s", g_modName[m], g_modVersion[m], get_pcvar_float(g_modWeight[m]), g_modAuthor[m]);
	return PLUGIN_HANDLED;
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

player_info(id, out[], len)
{
	new name[32], authid[35], ip[24];
	get_user_name(id, name, charsmax(name));
	get_user_authid(id, authid, charsmax(authid));
	get_user_ip(id, ip, charsmax(ip), 1);
	formatex(out, len, "^"%s<%d><%s><%s>^"", name, get_user_userid(id), authid, ip);
}

ac_log(const fmt[], any:...)
{
	if (!c_log)
		return;
	new msg[320];
	vformat(msg, charsmax(msg), fmt, 2);
	log_to_file(g_logFile, "%s", msg);
}

notify_admins(const fmt[], any:...)
{
	new msg[191];
	vformat(msg, charsmax(msg), fmt, 2);

	new flags = read_flags(c_adminFlag);
	new players[MAX_PLAYERS], num;
	get_players(players, num, "ch");
	for (new i = 0; i < num; i++)
	{
		if (get_user_flags(players[i]) & flags)
			client_print_color(players[i], print_team_default, "%s", msg);
	}
}
