// AMXAC: punishments.
//
// Turns core levels into actions: none / mute / kick / ban, configured per level.
// Kicks and bans are delayed (until the end of the round, or a random delay), so
// a cheater can't tell which action got him flagged. Leaving the server while a
// ban is pending doesn't help: the ban is applied by SteamID/IP on disconnect.
//
// Bans go through amxac_punish_ban_cmd if set (AMXBans, Fresh Bans, ...), else
// the engine's banid/addip.
//
// Placeholders in the command templates:
//   %userid% %name% %steamid% %ip% %time% (minutes) %reason% %module%

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <amxac>

#define PLUGIN  "AMXAC Punish"
#define AUTHOR  "AMXAC"

#define TASK_TICK   97000

enum PAct { PA_NONE = 0, PA_MUTE, PA_KICK, PA_BAN };
new const g_actName[PAct][] = { "none", "mute", "kick", "ban" };

new PAct:g_pending[MAX_PLAYERS + 1];
new Float:g_pendSince[MAX_PLAYERS + 1];
new Float:g_pendAt[MAX_PLAYERS + 1];          // 0 = waiting for round end
new g_pendUserid[MAX_PLAYERS + 1];
new g_pendName[MAX_PLAYERS + 1][32];
new g_pendSteam[MAX_PLAYERS + 1][35];
new g_pendIp[MAX_PLAYERS + 1][24];
new g_pendModule[MAX_PLAYERS + 1][32];
new g_pendTime[MAX_PLAYERS + 1];              // ban length for this punishment, minutes

new Float:g_muteUntil[MAX_PLAYERS + 1];        // gametime, 0 = not muted
new g_muteMinutes[MAX_PLAYERS + 1];

new c_actWarn[8], c_actAlert[8], c_actAction[8];
new c_banTime, c_muteTime, Float:c_delayMin, Float:c_delayMax, c_roundEnd;
new c_reason[64], c_banCmd[192], c_offlineCmd[192], c_kickCmd[192], c_immunity[24], c_announce;
new c_banTimeLevel[AcLevel], c_muteTimeLevel[AcLevel];    // -1 = use the common value
new c_msgKick[160], c_msgBan[160], c_msgMute[160];

public plugin_init()
{
	register_plugin(PLUGIN, AMXAC_VERSION, AUTHOR);

	bind_pcvar_string(create_cvar("amxac_punish_warn", "none", _, "Action at WARN: none, mute, kick, ban"), c_actWarn, charsmax(c_actWarn));
	bind_pcvar_string(create_cvar("amxac_punish_alert", "none", _, "Action at ALERT: none, mute, kick, ban"), c_actAlert, charsmax(c_actAlert));
	bind_pcvar_string(create_cvar("amxac_punish_action", "none", _, "Action at ACTION: none, mute, kick, ban"), c_actAction, charsmax(c_actAction));
	bind_pcvar_num(create_cvar("amxac_punish_ban_time", "10080", _, "Ban length, minutes (0 = permanent)"), c_banTime);
	bind_pcvar_num(create_cvar("amxac_punish_mute_time", "30", _, "Mute length, minutes (0 = until map change)"), c_muteTime);
	bind_pcvar_num(create_cvar("amxac_punish_round_end", "1", _, "Apply kicks/bans at the end of the round"), c_roundEnd);
	bind_pcvar_float(create_cvar("amxac_punish_delay_min", "30", _, "Random delay before kick/ban when not waiting for round end, seconds"), c_delayMin);
	bind_pcvar_float(create_cvar("amxac_punish_delay_max", "120", _, "Upper bound of the delay; also the longest wait for a round end"), c_delayMax);
	bind_pcvar_string(create_cvar("amxac_punish_reason", "Cheating", _, "Reason shown to the player (don't name the detector)"), c_reason, charsmax(c_reason));
	bind_pcvar_string(create_cvar("amxac_punish_ban_cmd", "", _, "Ban command template for your ban system (empty = banid/addip)"), c_banCmd, charsmax(c_banCmd));
	bind_pcvar_string(create_cvar("amxac_punish_offline_cmd", "", _, "Ban template for players who left before the ban (no %userid%; empty = banid/addip)"), c_offlineCmd, charsmax(c_offlineCmd));
	bind_pcvar_string(create_cvar("amxac_punish_kick_cmd", "", _, "Kick command template (empty = kick #userid)"), c_kickCmd, charsmax(c_kickCmd));
	bind_pcvar_string(create_cvar("amxac_punish_immunity", "", _, "Players with these flags are never punished, only reported"), c_immunity, charsmax(c_immunity));
	bind_pcvar_num(create_cvar("amxac_punish_announce", "1", _, "Tell everyone in chat when someone is kicked/banned"), c_announce);

	bind_pcvar_num(create_cvar("amxac_punish_ban_time_warn", "-1", _, "Ban length at WARN, minutes (-1 = amxac_punish_ban_time)"), c_banTimeLevel[AC_LEVEL_WARN]);
	bind_pcvar_num(create_cvar("amxac_punish_ban_time_alert", "-1", _, "Ban length at ALERT, minutes (-1 = amxac_punish_ban_time)"), c_banTimeLevel[AC_LEVEL_ALERT]);
	bind_pcvar_num(create_cvar("amxac_punish_ban_time_action", "-1", _, "Ban length at ACTION, minutes (-1 = amxac_punish_ban_time)"), c_banTimeLevel[AC_LEVEL_ACTION]);
	bind_pcvar_num(create_cvar("amxac_punish_mute_time_warn", "-1", _, "Mute length at WARN, minutes (-1 = amxac_punish_mute_time)"), c_muteTimeLevel[AC_LEVEL_WARN]);
	bind_pcvar_num(create_cvar("amxac_punish_mute_time_alert", "-1", _, "Mute length at ALERT, minutes (-1 = amxac_punish_mute_time)"), c_muteTimeLevel[AC_LEVEL_ALERT]);
	bind_pcvar_num(create_cvar("amxac_punish_mute_time_action", "-1", _, "Mute length at ACTION, minutes (-1 = amxac_punish_mute_time)"), c_muteTimeLevel[AC_LEVEL_ACTION]);

	bind_pcvar_string(create_cvar("amxac_punish_msg_kick", "!g[AC]!n !t%name%!n was kicked by the anti-cheat.", _, "Chat text on kick. !g green, !t team color, !n normal; %name% %time%"), c_msgKick, charsmax(c_msgKick));
	bind_pcvar_string(create_cvar("amxac_punish_msg_ban", "!g[AC]!n !t%name%!n was banned by the anti-cheat (%time%).", _, "Chat text on ban"), c_msgBan, charsmax(c_msgBan));
	bind_pcvar_string(create_cvar("amxac_punish_msg_mute", "!g[AC]!n You are muted (%time%).", _, "Text shown to a muted player"), c_msgMute, charsmax(c_msgMute));

	register_forward(FM_Voice_SetClientListening, "fw_Voice");
	register_clcmd("say", "cmd_say");
	register_clcmd("say_team", "cmd_say");
	register_logevent("ev_RoundEnd", 2, "1=Round_End");

	register_concmd("amx_ac_punish", "cmd_punish", ADMIN_BAN, "<target> <kick|ban|mute> - punish now, no delay");
	register_concmd("amx_ac_cancel", "cmd_cancel", ADMIN_BAN, "<target> - cancel a pending kick/ban");
	register_concmd("amx_ac_unmute", "cmd_unmute", ADMIN_BAN, "<target> - lift an AMXAC mute");

	set_task(1.0, "task_tick", TASK_TICK, _, _, "b");
}

public client_putinserver(id)
{
	g_pending[id] = PA_NONE;
	g_muteUntil[id] = 0.0;
}

public client_disconnected(id)
{
	// Quitting doesn't dodge a pending ban.
	if (g_pending[id] == PA_BAN)
	{
		amxac_log("PUNISH %s left with a pending ban, banning offline", g_pendName[id]);
		ban_offline(id);
	}
	g_pending[id] = PA_NONE;
	g_muteUntil[id] = 0.0;
}

PAct:parse_action(const s[])
{
	for (new PAct:a = PA_NONE; a <= PA_BAN; a++)
		if (equali(s, g_actName[a]))
			return a;
	return PA_NONE;
}

// ---------------------------------------------------------------------------
// Level -> action
// ---------------------------------------------------------------------------

public amxac_on_level(id, AcLevel:level, Float:score)
{
	new PAct:act;
	switch (level)
	{
		case AC_LEVEL_WARN: act = parse_action(c_actWarn);
		case AC_LEVEL_ALERT: act = parse_action(c_actAlert);
		case AC_LEVEL_ACTION: act = parse_action(c_actAction);
		default: return;
	}
	if (act == PA_NONE)
		return;

	new name[32];
	get_user_name(id, name, charsmax(name));

	// Bots only get here with amxac_include_bots 1 (testing). Never ban them:
	// a bot has no SteamID and its "IP" is the server's own address.
	if (is_user_bot(id))
	{
		amxac_log("PUNISH %s is a bot, %s skipped", name, g_actName[act]);
		return;
	}

	if (c_immunity[0] && (get_user_flags(id) & read_flags(c_immunity)))
	{
		amxac_log("PUNISH %s is immune, %s skipped", name, g_actName[act]);
		return;
	}

	if (act == PA_MUTE)
	{
		mute(id, level_time(c_muteTimeLevel[level], c_muteTime));
		amxac_notify("^4%s^1 ^3%s^1 muted (score %.0f)", AMXAC_TAG, name, score);
		return;
	}

	if (act <= g_pending[id])
		return;   // something at least as harsh is already scheduled

	capture(id, act);
	g_pendTime[id] = level_time(c_banTimeLevel[level], c_banTime);
	g_pendSince[id] = get_gametime();
	g_pendAt[id] = c_roundEnd ? 0.0 : get_gametime() + random_float(c_delayMin, floatmax(c_delayMin, c_delayMax));

	amxac_log("PUNISH %s scheduled for %s (score %.0f, module %s)", g_actName[act], name, score, g_pendModule[id]);
	if (c_roundEnd)
		amxac_notify("^4%s^1 ^3%s^1: %s at round end (amx_ac_cancel to stop)", AMXAC_TAG, name, g_actName[act]);
	else
		amxac_notify("^4%s^1 ^3%s^1: %s in %.0f s (amx_ac_cancel to stop)", AMXAC_TAG, name, g_actName[act], g_pendAt[id] - get_gametime());
}

level_time(perLevel, common)
{
	return perLevel >= 0 ? perLevel : common;
}

// "30 min", "2 h", "3 d", "permanent", in the units a player reads easily.
format_minutes(minutes, out[], len)
{
	if (minutes <= 0)
		copy(out, len, "permanent");
	else if (minutes % 1440 == 0)
		formatex(out, len, "%d d", minutes / 1440);
	else if (minutes % 60 == 0)
		formatex(out, len, "%d h", minutes / 60);
	else
		formatex(out, len, "%d min", minutes);
}

// Chat template -> colored message.
format_msg(const tpl[], const name[], minutes, out[], len)
{
	new t[24];
	format_minutes(minutes, t, charsmax(t));
	copy(out, len, tpl);
	replace_string(out, len, "%name%", name);
	replace_string(out, len, "%time%", t);
	replace_string(out, len, "!g", "^4");
	replace_string(out, len, "!t", "^3");
	replace_string(out, len, "!n", "^1");
}

capture(id, PAct:act)
{
	g_pendTime[id] = c_banTime;
	g_pending[id] = act;
	g_pendUserid[id] = get_user_userid(id);
	get_user_name(id, g_pendName[id], charsmax(g_pendName[]));
	get_user_authid(id, g_pendSteam[id], charsmax(g_pendSteam[]));
	get_user_ip(id, g_pendIp[id], charsmax(g_pendIp[]), 1);
	amxac_get_top_module(id, g_pendModule[id], charsmax(g_pendModule[]));
	amxac_sanitize(g_pendName[id]);
	amxac_sanitize(g_pendSteam[id]);
}

public ev_RoundEnd()
{
	for (new id = 1; id <= MaxClients; id++)
		if (g_pending[id] && g_pendAt[id] == 0.0)
			g_pendAt[id] = get_gametime() + random_float(0.5, 3.0);
}

public task_tick()
{
	new Float:now = get_gametime();
	for (new id = 1; id <= MaxClients; id++)
	{
		if (g_muteUntil[id] > 0.0 && now >= g_muteUntil[id])
			g_muteUntil[id] = 0.0;

		if (!g_pending[id])
			continue;

		// Modes without round ends (deathmatch): don't wait forever.
		if (g_pendAt[id] == 0.0 && now - g_pendSince[id] >= c_delayMax)
			g_pendAt[id] = now;

		if (g_pendAt[id] > 0.0 && now >= g_pendAt[id])
			execute(id);
	}
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

execute(id)
{
	new PAct:act = g_pending[id];
	g_pending[id] = PA_NONE;
	if (!is_user_connected(id))
		return;

	new cmd[256];
	if (act == PA_KICK)
	{
		if (c_kickCmd[0])
			fill_template(id, c_kickCmd, cmd, charsmax(cmd));
		else
			formatex(cmd, charsmax(cmd), "kick #%d ^"%s^"", g_pendUserid[id], c_reason);
	}
	else if (act == PA_BAN)
	{
		if (c_banCmd[0])
			fill_template(id, c_banCmd, cmd, charsmax(cmd));
		else
			builtin_ban(id, true, cmd, charsmax(cmd));
	}
	else
		return;

	amxac_log("PUNISH %s %s: %s", g_actName[act], g_pendName[id], cmd);
	server_cmd("%s", cmd);

	if (c_announce)
	{
		new msg[191];
		format_msg(act == PA_BAN ? c_msgBan : c_msgKick, g_pendName[id], g_pendTime[id], msg, charsmax(msg));
		client_print_color(0, print_team_red, "%s", msg);
	}
}

ban_offline(id)
{
	new cmd[256];
	if (c_offlineCmd[0])
		fill_template(id, c_offlineCmd, cmd, charsmax(cmd));
	else
		builtin_ban(id, false, cmd, charsmax(cmd));
	amxac_log("PUNISH ban %s (offline): %s", g_pendName[id], cmd);
	server_cmd("%s", cmd);
}

bool:valid_steamid(const s[])
{
	return (equal(s, "STEAM_", 6) || equal(s, "VALVE_", 6)) && containi(s, "_ID_") == -1;
}

// banid by SteamID when it's a real one, otherwise addip.
builtin_ban(id, bool:online, cmd[], len)
{
	if (valid_steamid(g_pendSteam[id]))
		formatex(cmd, len, "banid %d %s%s;writeid", g_pendTime[id], g_pendSteam[id], online ? " kick" : "");
	else if (online)
		formatex(cmd, len, "addip %d %s;writeip;kick #%d ^"%s^"", g_pendTime[id], g_pendIp[id], g_pendUserid[id], c_reason);
	else
		formatex(cmd, len, "addip %d %s;writeip", g_pendTime[id], g_pendIp[id]);
}

fill_template(id, const tpl[], cmd[], len)
{
	new buf[32];
	copy(cmd, len, tpl);

	num_to_str(g_pendUserid[id], buf, charsmax(buf));
	replace_string(cmd, len, "%userid%", buf);
	replace_string(cmd, len, "%name%", g_pendName[id]);
	replace_string(cmd, len, "%steamid%", g_pendSteam[id]);
	replace_string(cmd, len, "%ip%", g_pendIp[id]);
	num_to_str(g_pendTime[id], buf, charsmax(buf));
	replace_string(cmd, len, "%time%", buf);
	replace_string(cmd, len, "%reason%", c_reason);
	replace_string(cmd, len, "%module%", g_pendModule[id]);
}

mute(id, minutes)
{
	g_muteUntil[id] = minutes > 0 ? get_gametime() + float(minutes) * 60.0 : 999999999.0;
	g_muteMinutes[id] = minutes;
	show_mute_msg(id);
}

show_mute_msg(id)
{
	new name[32], tpl[160], msg[191];
	get_user_name(id, name, charsmax(name));
	copy(tpl, charsmax(tpl), c_msgMute);
	if (g_muteMinutes[id] <= 0)
		replace_string(tpl, charsmax(tpl), "%time%", "until map change");
	format_msg(tpl, name, g_muteMinutes[id], msg, charsmax(msg));
	client_print_color(id, print_team_red, "%s", msg);
}

public fw_Voice(receiver, sender, bool:listen)
{
	if (!(1 <= sender <= MaxClients) || g_muteUntil[sender] == 0.0 || receiver == sender)
		return FMRES_IGNORED;

	engfunc(EngFunc_SetClientListening, receiver, sender, false);
	forward_return(FMV_CELL, false);
	return FMRES_SUPERCEDE;
}

public cmd_say(id)
{
	if (g_muteUntil[id] == 0.0)
		return PLUGIN_CONTINUE;
	show_mute_msg(id);
	return PLUGIN_HANDLED;
}

// ---------------------------------------------------------------------------
// Admin commands
// ---------------------------------------------------------------------------

public cmd_punish(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3))
		return PLUGIN_HANDLED;

	new who[32], what[8];
	read_argv(1, who, charsmax(who));
	read_argv(2, what, charsmax(what));

	new target = cmd_target(id, who, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_ALLOW_SELF);
	if (!target)
		return PLUGIN_HANDLED;

	new PAct:act = parse_action(what);
	if (act == PA_NONE)
	{
		console_print(id, "[AC] Action must be kick, ban or mute");
		return PLUGIN_HANDLED;
	}

	new admin[32];
	get_user_name(id, admin, charsmax(admin));
	amxac_log("PUNISH manual %s on %s by %s", g_actName[act], who, id ? admin : "server");

	if (act == PA_MUTE)
	{
		mute(target, c_muteTime);
		console_print(id, "[AC] Muted");
		return PLUGIN_HANDLED;
	}

	if (act == PA_BAN && is_user_bot(target))
		act = PA_KICK;   // banid/addip on a bot would ban the server's own address

	capture(target, act);
	execute(target);
	return PLUGIN_HANDLED;
}

public cmd_cancel(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new who[32];
	read_argv(1, who, charsmax(who));
	new target = cmd_target(id, who, CMDTARGET_ALLOW_SELF);
	if (!target)
		return PLUGIN_HANDLED;

	if (!g_pending[target])
	{
		console_print(id, "[AC] Nothing pending for that player");
		return PLUGIN_HANDLED;
	}

	new admin[32];
	get_user_name(id, admin, charsmax(admin));
	amxac_log("PUNISH %s on %s cancelled by %s", g_actName[g_pending[target]], g_pendName[target], id ? admin : "server");
	g_pending[target] = PA_NONE;
	console_print(id, "[AC] Cancelled");
	return PLUGIN_HANDLED;
}

public cmd_unmute(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new who[32];
	read_argv(1, who, charsmax(who));
	new target = cmd_target(id, who, CMDTARGET_ALLOW_SELF);
	if (!target)
		return PLUGIN_HANDLED;

	g_muteUntil[target] = 0.0;
	console_print(id, "[AC] Unmuted");
	return PLUGIN_HANDLED;
}
