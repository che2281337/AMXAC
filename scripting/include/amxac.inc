// AMXAC - modular server-side anticheat for Counter-Strike 1.6
// Public API shared by the core (amxac_core.sma) and detector modules.

#if defined _amxac_included
	#endinput
#endif
#define _amxac_included

#pragma reqlib amxac
#if !defined AMXMODX_NOAUTOLOAD
	#pragma loadlib amxac
#endif

#define AMXAC_VERSION       "0.1.0"
#define AMXAC_MAX_MODULES   32
#define AMXAC_TAG           "[AC]"

enum AcLevel
{
	AC_LEVEL_NONE = 0,
	AC_LEVEL_WARN,      // logged
	AC_LEVEL_ALERT,     // admins notified in chat
	AC_LEVEL_ACTION     // amxac_action_cmd is executed (empty by default)
};

/**
 * Registers a detector module. Call from plugin_init().
 * The core creates a weight cvar "amxac_w_<name>" (default 1.0, 0 = mute module).
 *
 * @return  Module id, or -1 on failure.
 */
native amxac_register_module(const name[], const version[] = "", const author[] = "");

/**
 * Adds suspicion points to a player. Points are multiplied by the module weight
 * and decay over time (amxac_halflife).
 *
 * @return  1 if the report was accepted, 0 if blocked or the player is not monitored.
 */
native amxac_report(id, module, Float:points, const fmt[], any:...);

/**
 * Current suspicion score of a player.
 *
 * @param module    Module id, or -1 for the weighted total.
 */
native Float:amxac_get_score(id, module = -1);

/**
 * Current level of a player.
 */
native AcLevel:amxac_get_level(id);

/**
 * Whether detectors should analyse this player
 * (connected, not HLTV, not immune, bots only if amxac_include_bots 1).
 */
native bool:amxac_is_monitored(id);

/**
 * Clears a player's score.
 *
 * @param module    Module id, or -1 for all modules.
 */
native amxac_reset(id, module = -1);

/**
 * Drops reports for a player for a while, e.g. around a teleport or a speed
 * boost from another plugin. Detectors keep running; only scoring is skipped.
 *
 * @param module    Module id, or -1 for all modules.
 * @param seconds   Duration; 0 stops ignoring, < 0 ignores until disconnect.
 */
native amxac_set_ignore(id, module = -1, Float:seconds = 1.0);

/**
 * Name of the module with the highest score for a player ("-" if none).
 */
native amxac_get_top_module(id, name[], len);

/**
 * Writes a line to the AMXAC log (logs/amxac_YYYYMMDD.log).
 */
native amxac_log(const fmt[], any:...);

/**
 * Prints a chat message to admins with amxac_admin_flag. Colors: ^1 ^3 ^4.
 */
native amxac_notify(const fmt[], any:...);

/**
 * Called before a report is applied. Return PLUGIN_HANDLED to drop it.
 */
forward amxac_on_report(id, module, Float:points, const reason[]);

/**
 * Called when a player's level rises.
 */
forward amxac_on_level(id, AcLevel:level, Float:score);


// ---------------------------------------------------------------------------
// Shared helpers for detectors
// ---------------------------------------------------------------------------

stock Float:amxac_wrap180(Float:a)
{
	while (a > 180.0) a -= 360.0;
	while (a < -180.0) a += 360.0;
	return a;
}

// Angular distance in degrees between two view angles ([0] = pitch, [1] = yaw).
// Usercmd angles travel as 16-bit [0, 360) values, so a pitch of -1 can arrive
// as 359: both components are wrapped, or crossing the horizon would look like
// a 358 degree flick.
stock Float:amxac_angle_dist(const Float:a[], const Float:b[])
{
	new Float:dp = amxac_wrap180(a[0] - b[0]);
	new Float:dy = amxac_wrap180(a[1] - b[1]);
	return floatsqroot(dp * dp + dy * dy);
}

// Prints detector internals ("why didn't it trigger") to the player's own
// console when amxac_debug is 1. Only players with the rcon flag get it, so a
// cheater can't use it to tune his settings.
stock amxac_debug(id, const fmt[], any:...)
{
	static pcvar;
	if (!pcvar)
		pcvar = get_cvar_pointer("amxac_debug");
	if (!pcvar || !get_pcvar_num(pcvar) || !(get_user_flags(id) & ADMIN_RCON))
		return;

	new msg[192];
	vformat(msg, charsmax(msg), fmt, 3);
	client_print(id, print_console, "[AC debug] %s", msg);
}

// Player-controlled strings go into server commands: strip anything that could
// terminate the command or break out of quotes.
stock amxac_sanitize(str[])
{
	for (new i = 0; str[i]; i++)
	{
		switch (str[i])
		{
			case ';', '"', '^n', '^r', '\', '%': str[i] = '_';
		}
	}
}

stock bool:amxac_is_gun(weapon_id)
{
	switch (weapon_id)
	{
		case 0, CSW_KNIFE, CSW_HEGRENADE, CSW_FLASHBANG, CSW_SMOKEGRENADE, CSW_C4: return false;
	}
	return true;
}
