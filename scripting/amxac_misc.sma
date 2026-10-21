// AMXAC: non-gameplay checks in one plugin. Nothing here runs per usercmd.
//
//   misc     name flood, many clients from one IP
//   cvars    client cvar rules from configs/amxac_cvars.ini; cvar queries that
//            never get an answer while the client plays (query blocker, idea from
//            Unreal Cheat Detector by Karaulov)
//   history  remembers past ALERTs per SteamID (nvault)
//
// Plus two direct kicks that don't go through scoring:
//   - a second client with a SteamID that is already on the server (emulators)
//   - IPs / subnets from configs/amxac_blocked_ips.ini (amx_ac_blockip, amx_ac_unblockip)

#include <amxmodx>
#include <amxmisc>
#include <hamsandwich>
#include <fakemeta>
#include <nvault>
#include <amxac>

#define PLUGIN  "AMXAC Misc"
#define AUTHOR  "AMXAC"

#define MAX_RULES   32
#define MAX_BLOCKS  512
#define TASK_JOIN   95000
#define TASK_QUERY  95100

new g_modMisc, g_modCvars, g_modHistory;

// ---- misc ----
new g_name[MAX_PLAYERS + 1][32];
new g_nameChanges[MAX_PLAYERS + 1];
new Float:g_nameWindow[MAX_PLAYERS + 1];

// ---- cvars ----
enum CvarOp { OP_EQ, OP_NE, OP_LE, OP_GE };
new const g_opName[CvarOp][] = { "=", "!=", "<=", ">=" };

new g_ruleCount;
new g_ruleCvar[MAX_RULES][32];
new CvarOp:g_ruleOp[MAX_RULES];
new g_ruleValue[MAX_RULES][32];
new Float:g_rulePts[MAX_RULES];
new Float:g_lastQuery[MAX_PLAYERS + 1];
new Float:g_queryPending[MAX_PLAYERS + 1];   // gametime of an unanswered batch, 0 = none
new g_queryMisses[MAX_PLAYERS + 1];
new bool:g_queryAnswered[MAX_PLAYERS + 1];   // answered at least once this connection
new Float:g_lastCmd[MAX_PLAYERS + 1];
new g_cvarReported[MAX_PLAYERS + 1];   // bitmask of rules already reported this connection

// ---- history ----
new g_vault = INVALID_HANDLE;
new bool:g_counted[MAX_PLAYERS + 1];

// ---- IP blacklist ----
new g_blockCount;
new g_blockNet[MAX_BLOCKS];
new g_blockMask[MAX_BLOCKS];
new g_blockText[MAX_BLOCKS][20];
new g_blockFile[128];

new c_names, Float:c_nameWindow, Float:c_ptsName, c_maxPerIp, Float:c_ptsIp;
new c_dupSteam, c_blockReason[64];
new Float:c_cvarInterval, Float:c_qTimeout, c_qNeed, Float:c_qPts, c_qStrict;
new Float:c_histPer, Float:c_histMax, c_histExpire;

public plugin_init()
{
	register_plugin(PLUGIN, AMXAC_VERSION, AUTHOR);
	g_modMisc = amxac_register_module("misc", AMXAC_VERSION, AUTHOR);
	g_modCvars = amxac_register_module("cvars", AMXAC_VERSION, AUTHOR);
	g_modHistory = amxac_register_module("history", AMXAC_VERSION, AUTHOR);

	bind_pcvar_num(create_cvar("amxac_misc_names", "4", _, "Name changes within the window to report"), c_names);
	bind_pcvar_float(create_cvar("amxac_misc_name_window", "10"), c_nameWindow);
	bind_pcvar_float(create_cvar("amxac_misc_name_pts", "10"), c_ptsName);
	bind_pcvar_num(create_cvar("amxac_misc_max_per_ip", "3", _, "Players allowed per IP before reporting (0 = off)"), c_maxPerIp);
	bind_pcvar_float(create_cvar("amxac_misc_ip_pts", "10"), c_ptsIp);

	bind_pcvar_float(create_cvar("amxac_cvars_interval", "60", _, "Min seconds between cvar queries per player"), c_cvarInterval);
	bind_pcvar_float(create_cvar("amxac_query_timeout", "10", _, "Seconds to wait for a cvar query answer"), c_qTimeout);
	bind_pcvar_num(create_cvar("amxac_query_need", "2", _, "Unanswered query batches (while playing) to report"), c_qNeed);
	bind_pcvar_float(create_cvar("amxac_query_pts", "15"), c_qPts);
	bind_pcvar_num(create_cvar("amxac_query_strict", "0", _, "1 = also count clients that never answered a query (Steam-only servers)"), c_qStrict);

	bind_pcvar_float(create_cvar("amxac_history_pts", "5", _, "Starting points per previous alert"), c_histPer);
	bind_pcvar_float(create_cvar("amxac_history_max", "25", _, "Cap for starting points"), c_histMax);
	bind_pcvar_num(create_cvar("amxac_history_expire", "30", _, "Forget players not seen for this many days"), c_histExpire);

	bind_pcvar_num(create_cvar("amxac_misc_dup_steamid", "1", _, "Kick a client whose SteamID is already on the server"), c_dupSteam);
	bind_pcvar_string(create_cvar("amxac_misc_blocked_reason", "Your IP is blocked on this server", _, "Kick reason for blacklisted IPs"), c_blockReason, charsmax(c_blockReason));

	register_concmd("amx_ac_blockip", "cmd_blockip", ADMIN_BAN, "<ip[/bits]> - block an IP or subnet");
	register_concmd("amx_ac_unblockip", "cmd_unblockip", ADMIN_BAN, "<ip[/bits]> - remove a block");
	register_concmd("amx_ac_blocklist", "cmd_blocklist", ADMIN_BAN, "- list blocked IPs");

	RegisterHam(Ham_Spawn, "player", "fw_Spawn_Post", 1);
	register_forward(FM_CmdStart, "fw_CmdStart");
	set_task(2.0, "task_queries", TASK_QUERY, _, _, "b");
	load_rules();
	load_blocks();

	g_vault = nvault_open("amxac_history");
	if (g_vault == INVALID_HANDLE)
		log_amx("Cannot open nvault amxac_history, history disabled");
}

public plugin_cfg()
{
	if (g_vault != INVALID_HANDLE && c_histExpire > 0)
		nvault_prune(g_vault, 0, get_systime() - c_histExpire * 86400);
}

public plugin_end()
{
	if (g_vault != INVALID_HANDLE)
		nvault_close(g_vault);
}

public client_putinserver(id)
{
	get_user_name(id, g_name[id], charsmax(g_name[]));
	g_nameChanges[id] = 0;
	g_nameWindow[id] = get_gametime();
	g_lastQuery[id] = -1000.0;
	g_queryPending[id] = 0.0;
	g_queryMisses[id] = 0;
	g_queryAnswered[id] = false;
	g_lastCmd[id] = 0.0;
	g_cvarReported[id] = 0;
	g_counted[id] = false;

	if (c_maxPerIp > 0 && !is_user_bot(id))
		check_ip(id);

	// The core resets scores in its own client_putinserver; add history points after it.
	if (g_vault != INVALID_HANDLE)
		set_task(1.0, "task_join", TASK_JOIN + id);
}

public client_disconnected(id)
{
	remove_task(TASK_JOIN + id);
}

public client_connect(id)
{
	if (!g_blockCount || is_user_bot(id))
		return;

	new ip[24];
	get_user_ip(id, ip, charsmax(ip), 1);
	new addr;
	if (!parse_ipv4(ip, addr))
		return;

	for (new i = 0; i < g_blockCount; i++)
	{
		if ((addr & g_blockMask[i]) == (g_blockNet[i] & g_blockMask[i]))
		{
			amxac_log("BLOCKED %s matched %s, kicked", ip, g_blockText[i]);
			server_cmd("kick #%d ^"%s^"", get_user_userid(id), c_blockReason);
			return;
		}
	}
}

public client_authorized(id, const authid[])
{
	if (!c_dupSteam || is_user_bot(id) || !real_steamid(authid))
		return;

	new other[35];
	for (new i = 1; i <= MaxClients; i++)
	{
		if (i == id || !is_user_connected(i))
			continue;
		get_user_authid(i, other, charsmax(other));
		if (equal(authid, other))
		{
			new name[32];
			get_user_name(id, name, charsmax(name));
			amxac_log("DUPLICATE %s tried to join with SteamID %s already in use, kicked", name, authid);
			server_cmd("kick #%d ^"This SteamID is already on the server^"", get_user_userid(id));
			return;
		}
	}
}

bool:real_steamid(const s[])
{
	return (equal(s, "STEAM_", 6) || equal(s, "VALVE_", 6)) && containi(s, "_ID_") == -1;
}

// ---------------------------------------------------------------------------
// IP blacklist: one entry per line, "1.2.3.4" or "1.2.3.0/24"; ; # // comments
// ---------------------------------------------------------------------------

bool:parse_ipv4(const s[], &addr)
{
	new parts[4], part = 0, value = 0, digits = 0;
	for (new i = 0; ; i++)
	{
		new c = s[i];
		if (c >= '0' && c <= '9')
		{
			value = value * 10 + (c - '0');
			if (++digits > 3 || value > 255)
				return false;
			continue;
		}
		if (c != '.' && c != 0 && c != ':')
			return false;
		if (!digits || part > 3)
			return false;
		parts[part++] = value;
		value = digits = 0;
		if (c != '.')
			break;   // end of string, or ":port"
	}
	if (part != 4)
		return false;
	addr = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
	return true;
}

// "ip" or "ip/bits" -> network and mask.
bool:parse_block(const s[], &net, &mask)
{
	new ip[20], bitsStr[4];
	new slash = contain(s, "/");
	if (slash == -1)
	{
		copy(ip, charsmax(ip), s);
		mask = -1;
	}
	else
	{
		copy(ip, min(slash, charsmax(ip)), s);
		copy(bitsStr, charsmax(bitsStr), s[slash + 1]);
		new bits = str_to_num(bitsStr);
		if (bits < 0 || bits > 32 || !bitsStr[0])
			return false;
		mask = bits == 0 ? 0 : (-1 << (32 - bits));
	}
	return parse_ipv4(ip, net);
}

bool:add_block(const s[])
{
	if (g_blockCount >= MAX_BLOCKS)
		return false;
	new net, mask;
	if (!parse_block(s, net, mask))
		return false;
	for (new i = 0; i < g_blockCount; i++)
		if (g_blockNet[i] == net && g_blockMask[i] == mask)
			return true;

	g_blockNet[g_blockCount] = net;
	g_blockMask[g_blockCount] = mask;
	copy(g_blockText[g_blockCount], charsmax(g_blockText[]), s);
	g_blockCount++;
	return true;
}

load_blocks()
{
	get_configsdir(g_blockFile, charsmax(g_blockFile));
	format(g_blockFile, charsmax(g_blockFile), "%s/amxac_blocked_ips.ini", g_blockFile);

	new f = fopen(g_blockFile, "rt");
	if (!f)
		return;

	new line[64];
	while (!feof(f))
	{
		fgets(f, line, charsmax(line));
		trim(line);   // fgets keeps the newline; without this nothing would ever match
		if (!line[0] || line[0] == ';' || line[0] == '#' || (line[0] == '/' && line[1] == '/'))
			continue;
		if (!add_block(line))
			log_amx("amxac_blocked_ips.ini: bad entry ^"%s^"", line);
	}
	fclose(f);
}

save_blocks()
{
	new f = fopen(g_blockFile, "wt");
	if (!f)
		return;
	fputs(f, "; AMXAC blocked IPs: one per line, 1.2.3.4 or 1.2.3.0/24^n");
	for (new i = 0; i < g_blockCount; i++)
		fprintf(f, "%s^n", g_blockText[i]);
	fclose(f);
}

public cmd_blockip(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new arg[20];
	read_argv(1, arg, charsmax(arg));
	if (!add_block(arg))
	{
		console_print(id, "[AC] Bad address or list full: %s", arg);
		return PLUGIN_HANDLED;
	}
	save_blocks();
	amxac_log("BLOCKIP %s added", arg);
	console_print(id, "[AC] Blocked %s", arg);
	return PLUGIN_HANDLED;
}

public cmd_unblockip(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new arg[20], net, mask;
	read_argv(1, arg, charsmax(arg));
	if (!parse_block(arg, net, mask))
	{
		console_print(id, "[AC] Bad address: %s", arg);
		return PLUGIN_HANDLED;
	}

	for (new i = 0; i < g_blockCount; i++)
	{
		if (g_blockNet[i] != net || g_blockMask[i] != mask)
			continue;

		g_blockCount--;
		g_blockNet[i] = g_blockNet[g_blockCount];
		g_blockMask[i] = g_blockMask[g_blockCount];
		copy(g_blockText[i], charsmax(g_blockText[]), g_blockText[g_blockCount]);
		save_blocks();
		amxac_log("BLOCKIP %s removed", arg);
		console_print(id, "[AC] Unblocked %s", arg);
		return PLUGIN_HANDLED;
	}
	console_print(id, "[AC] %s is not blocked", arg);
	return PLUGIN_HANDLED;
}

public cmd_blocklist(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	console_print(id, "[AC] %d blocked entries:", g_blockCount);
	for (new i = 0; i < g_blockCount; i++)
		console_print(id, "  %s", g_blockText[i]);
	return PLUGIN_HANDLED;
}

// ---------------------------------------------------------------------------
// misc
// ---------------------------------------------------------------------------

check_ip(id)
{
	new ip[24], other[24];
	get_user_ip(id, ip, charsmax(ip), 1);
	if (equal(ip, "127.0.0.1") || equal(ip, "loopback"))
		return;

	new players[MAX_PLAYERS], num, same = 0;
	get_players(players, num, "ch");
	for (new i = 0; i < num; i++)
	{
		get_user_ip(players[i], other, charsmax(other), 1);
		if (equal(ip, other))
			same++;
	}

	if (same > c_maxPerIp)
		amxac_report(id, g_modMisc, c_ptsIp, "%d players connected from %s", same, ip);
}

public client_infochanged(id)
{
	if (!is_user_connected(id))
		return;

	new name[32];
	get_user_info(id, "name", name, charsmax(name));
	if (equal(name, g_name[id]))
		return;
	copy(g_name[id], charsmax(g_name[]), name);

	new Float:now = get_gametime();
	if (now - g_nameWindow[id] > c_nameWindow)
	{
		g_nameWindow[id] = now;
		g_nameChanges[id] = 0;
	}

	if (++g_nameChanges[id] >= c_names)
	{
		amxac_report(id, g_modMisc, c_ptsName, "%d name changes in %.0f s (now ^"%s^")", g_nameChanges[id], now - g_nameWindow[id], name);
		g_nameChanges[id] = 0;
		g_nameWindow[id] = now;
	}
}

// ---------------------------------------------------------------------------
// cvars
// Line format:  <cvar> <op> <value> <points>   op: =  !=  <=  >=
// ---------------------------------------------------------------------------

load_rules()
{
	new path[128];
	get_configsdir(path, charsmax(path));
	format(path, charsmax(path), "%s/amxac_cvars.ini", path);

	new f = fopen(path, "rt");
	if (!f)
		return;

	new line[128], name[32], op[4], value[32], pts[16];
	while (!feof(f) && g_ruleCount < MAX_RULES)
	{
		fgets(f, line, charsmax(line));
		trim(line);
		if (!line[0] || line[0] == ';' || (line[0] == '/' && line[1] == '/'))
			continue;
		if (parse(line, name, charsmax(name), op, charsmax(op), value, charsmax(value), pts, charsmax(pts)) < 4)
			continue;

		new CvarOp:o;
		if (equal(op, "=")) o = OP_EQ;
		else if (equal(op, "!=")) o = OP_NE;
		else if (equal(op, "<=")) o = OP_LE;
		else if (equal(op, ">=")) o = OP_GE;
		else continue;

		new r = g_ruleCount++;
		copy(g_ruleCvar[r], charsmax(g_ruleCvar[]), name);
		g_ruleOp[r] = o;
		copy(g_ruleValue[r], charsmax(g_ruleValue[]), value);
		g_rulePts[r] = str_to_float(pts);
	}
	fclose(f);
}

public fw_Spawn_Post(id)
{
	if (!is_user_alive(id) || is_user_bot(id) || !amxac_is_monitored(id))
		return;

	new Float:now = get_gametime();
	if (now - g_lastQuery[id] < c_cvarInterval)
		return;
	g_lastQuery[id] = now;

	if (g_queryPending[id] == 0.0)
		g_queryPending[id] = now;

	// A cvar every client has, so the blocker check works without any rules.
	new param[1] = { -1 };
	query_client_cvar(id, "sensitivity", "cvar_result", sizeof param, param);

	for (new r = 0; r < g_ruleCount; r++)
	{
		param[0] = r;
		query_client_cvar(id, g_ruleCvar[r], "cvar_result", sizeof param, param);
	}
}

public cvar_result(id, const cvar[], const value[], const param[])
{
	g_queryPending[id] = 0.0;   // the client answers queries
	g_queryAnswered[id] = true;

	new r = param[0];
	if (r < 0 || r >= g_ruleCount || (g_cvarReported[id] & (1 << r)))
		return;
	if (equal(value, "Bad CVAR request"))
		return;   // cvar doesn't exist on this client build
	if (rule_ok(r, value))
		return;

	g_cvarReported[id] |= 1 << r;
	amxac_report(id, g_modCvars, g_rulePts[r], "%s = ^"%s^" (expected %s %s)", cvar, value, g_opName[g_ruleOp[r]], g_ruleValue[r]);
}

bool:rule_ok(r, const value[])
{
	new bool:numeric = is_number_like(value) && is_number_like(g_ruleValue[r]);
	new Float:v = str_to_float(value), Float:want = str_to_float(g_ruleValue[r]);

	switch (g_ruleOp[r])
	{
		case OP_EQ: return numeric ? v == want : bool:equali(value, g_ruleValue[r]);
		case OP_NE: return numeric ? v != want : !equali(value, g_ruleValue[r]);
		case OP_LE: return v <= want;
		case OP_GE: return v >= want;
	}
	return true;
}

bool:is_number_like(const s[])
{
	if (!s[0])
		return false;
	for (new i = 0; s[i]; i++)
		if (!isdigit(s[i]) && s[i] != '.' && s[i] != '-')
			return false;
	return true;
}

// ---------------------------------------------------------------------------
// history
// ---------------------------------------------------------------------------

bool:history_key(id, key[], len)
{
	get_user_authid(id, key, len);
	return !(!key[0] || containi(key, "LAN") != -1 || containi(key, "PENDING") != -1 || equal(key, "BOT"));
}

public task_join(task)
{
	new id = task - TASK_JOIN;
	new key[35];
	if (!is_user_connected(id) || !history_key(id, key, charsmax(key)))
		return;

	new alerts = nvault_get(g_vault, key);
	if (alerts <= 0)
		return;
	nvault_touch(g_vault, key);

	new name[32];
	get_user_name(id, name, charsmax(name));
	amxac_notify("^4%s^1 ^3%s^1 joined with ^4%d^1 previous alert(s)", AMXAC_TAG, name, alerts);

	new Float:pts = floatmin(c_histPer * float(alerts), c_histMax);
	if (pts > 0.0)
		amxac_report(id, g_modHistory, pts, "%d previous alert(s) on record", alerts);
}

public amxac_on_level(id, AcLevel:level, Float:score)
{
	// A single big report can jump straight to ACTION; count one alert per session.
	if (g_vault == INVALID_HANDLE || level < AC_LEVEL_ALERT || g_counted[id])
		return;
	g_counted[id] = true;

	new key[35];
	if (!history_key(id, key, charsmax(key)))
		return;

	new value[12];
	num_to_str(nvault_get(g_vault, key) + 1, value, charsmax(value));
	nvault_set(g_vault, key, value);
}

// ---------------------------------------------------------------------------
// Query blocker: some cheats swallow query_client_cvar so the server can't see
// their cvars. A real client always answers, even "Bad CVAR request". No answer
// for a long time while the client keeps sending usercmds (so it isn't just
// lagging or loading) means something eats the queries.
// ---------------------------------------------------------------------------

public fw_CmdStart(id, uc, seed)
{
	g_lastCmd[id] = get_gametime();
	return FMRES_IGNORED;
}

public task_queries()
{
	new Float:now = get_gametime();
	for (new id = 1; id <= MaxClients; id++)
	{
		if (g_queryPending[id] == 0.0 || now - g_queryPending[id] < c_qTimeout)
			continue;
		g_queryPending[id] = 0.0;

		if (!is_user_connected(id) || now - g_lastCmd[id] > 1.0)
			continue;   // not playing right now, can't tell

		// Old protocol 47 (non-Steam) clients can't answer queries at all. Unless
		// the server is Steam-only, only a client that answered before and then
		// went silent is suspicious.
		if (!g_queryAnswered[id] && !c_qStrict)
			continue;

		amxac_debug(id, "cvars: query unanswered for %.0f s while playing (%d/%d)", c_qTimeout, g_queryMisses[id] + 1, c_qNeed);
		if (++g_queryMisses[id] >= c_qNeed)
		{
			amxac_report(id, g_modCvars, c_qPts, "%d cvar query batches unanswered while playing (query blocker)", g_queryMisses[id]);
			g_queryMisses[id] = 0;
		}
	}
}
