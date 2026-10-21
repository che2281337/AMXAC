**English** | [Русский](README_RU.md)

# AMXAC

Modular server-side anti-cheat for Counter-Strike 1.6.

- AMX Mod X 1.9+ with `fakemeta`, `hamsandwich`, `nvault`.
- ReAPI is only needed for `amxac_antiesp` (sound ESP protection); everything else runs on plain HLDS too.

## How it works

Detectors never ban on their own. Every suspicious action adds points to the player, points decay over time (half-life 2 minutes by default), and the total triggers levels:

| Level | Points | Default |
|---|---|---|
| WARN | 30 | logged |
| ALERT | 60 | admins notified in chat |
| ACTION | 100 | action from `amxac_punish_action` (`none` by default) |

For each level you choose `none`, `mute`, `kick` or `ban`. Kicks and bans are delayed to the end of the round, so a cheater can't tell what gave him away; leaving the server doesn't dodge a pending ban. Bans go through your ban system (`amxac_punish_ban_cmd`) or the engine's `banid`/`addip`.

Each detector is a separate module with its own weight `amxac_w_<name>` (0 = off). Everything is logged to `logs/amxac_YYYYMMDD.log` with name, SteamID and IP.

## Plugins

| Plugin | What it does |
|---|---|
| `amxac_core` | scoring, levels, logs, admin notifications, API for your own modules |
| `amxac_antiwh` | doesn't send enemies the player can't see (wallhack, radar); sends no enemies at all while the player is fully flashed (no-flash) |
| `amxac_antiesp` | hidden enemies' footsteps and other sounds come from the right direction and loudness but not from their real position; gunshot events are hidden from those who can't see the shooter (**ReAPI**) |
| `amxac_aim` | **silentaim** (flick on the shot with an exact return), **aimsnap**, **trigger** (instant or fixed-delay reaction), **tracking** (aim on an enemy behind a wall, aim lock, HS ratio), **nospread**, **norecoil**, **knifebot**, **fastzoom**, **rapidfire**, **noflash** (aimed hits while flashed) |
| `amxac_move` | **bhop** and **sgs** scripts (frame-perfect jumps/ducktaps), jump/duck **macros** (AHK timers), **strafe** (auto-strafe, strafe helper), **speedhack**, fake `msec 0` commands, **angles** (anti-aim pitch, spinbot), **netcode** (fakelag, lag shot), **movecheck** (movement no real client can send) |
| `amxac_misc` | name flood, players per IP, client cvar rules (`amxac_cvars.ini`), cvar query blockers, history of offences per SteamID, duplicate SteamID kick, IP/subnet blacklist |
| `amxac_punish` | mute / kick / ban per level, delayed and offline bans, custom ban/kick commands and chat texts |
| `amxac_ghost` | honeypot: an admin becomes invisible; ESP still draws him and aimbots lock on him, so whoever keeps shooting at or tracking him is flagged |
| `amxac_selftest` | **test servers only**: fakes cheat behaviour on your own usercmds to check that detectors fire |

## Modules

Every module below has its own score and weight `amxac_w_<module>`; thresholds are in `amxac.cfg`.

| Module | Plugin | Catches | How |
|---|---|---|---|
| `antiwh` | antiwh | wallhack, ESP, radar | Prevention: an enemy is sent to a player only if a trace from his eyes reaches the enemy's head, body, sides or feet (also extrapolated by ping). Only world geometry blocks sight; a seen enemy stays visible for 0.3 s. Trace budget per second, fails open under load |
| *(anti no-flash)* | antiwh | no-flash | Prevention: while a player's screen is fully white after a flashbang, no enemies are sent to him |
| `antiesp` | antiesp | sound ESP, sound radar | Prevention (ReAPI): sounds of enemies the player can't see come from the world entity at a fake distance with recomputed volume — right direction and loudness, wrong position. Gunshot events go only to those who see the shooter or the impact |
| `silentaim` | aim | pSilent | Flick ≥15° on the shot cmd, held 1–2 cmds, then back to the old angle within 1° / 10%. Also counts the raw `+attack`, so it still works behind Unreal Aim Blocker |
| `aimsnap` | aim | aimbot snaps (weak) | Headshot right after a ≥20° snap, aim stops dead (≤0.3°) on the next cmd |
| `trigger` | aim | triggerbot | Time from an enemy entering the crosshair to a fresh click: ≥5 of 10 within 15 ms, or 10 reactions with σ ≤ 8 ms (fixed-delay trigger) |
| `tracking` | aim | wallhack aiming, smooth aimbot | Crosshair kept on a hidden enemy ≥600 ms with mean error ≤1.2° while moving the mouse; aim lock: σ of aim error ≤0.25° while the view turns ≥15°; ≥17 headshots in the last 20 gun kills |
| `nospread` | aim | no-spread | The shot cmd sits off the mouse path by the spread while the real bullet (captured trace) flies dead on the path — 8 of 10 shots |
| `norecoil` | aim | no-recoil | `v_angle + punchangle` frozen (≤0.25°, ≤25% of recoil) through a spray of ≥6 shots |
| `knifebot` | aim | knifebot | First swing within 15 ms of an enemy entering 64 units, 7 of 10 times |
| `fastzoom` | aim | fast-zoom script | Scoped shot within 40 ms of zooming, 3 of 6 scoped shots |
| `rapidfire` | aim | pistol autoclicker | 12 pistol clicks with interval σ ≤ 2.5 ms |
| `noflash` | aim | no-flash | ≥3 hits from fresh clicks on enemies during one full blindness (headshot counts double) |
| `bhop` | move | bhop script, jump macros | 10 frame-perfect jumps in a row, 6 "clean" ones (no presses in the air), 80% of 30; jump pressed ≥25×/s for 3 s at an even interval (AHK) |
| `sgs` | move | SGS / ducktap script, duck macros | Same as bhop for `+duck` |
| `strafe` | move | auto-strafe, strafe helper | `sidemove` without A/D on ≥50% of air cmds; A/D switched exactly on the mouse reversal frame in ≥90% of 40 switches (humans: 20–40%) |
| `speedhack` | move | speedhack, fake commands | Client clock (sum of `msec`) runs ≥300 ms ahead of the server; bursts of `msec = 0` cmds |
| `movecheck` | move | movement hacks | Movement against the only key held, or a move vector longer than the `maxspeed` the client clamps to |
| `angles` | move | anti-aim, spinbot | Pitch beyond ±89.9°; yaw turning faster than 2000°/s for 2 s |
| `netcode` | move | fakelag, lag shot | Steady bursts of 12+ choked cmds; shots arriving in choked packets far more often than other cmds (backtrack) |
| `misc` | misc | name stealer, multi-client | ≥4 name changes in 10 s; more than 3 players from one IP |
| `cvars` | misc | lazy cheats, query blockers | Protected client cvars from `amxac_cvars.ini`; cvar queries left unanswered while the client keeps playing |
| `history` | misc | repeat offenders | Players who reached ALERT before start with extra points (per SteamID, 30 days) |
| `honeypot` | ghost | ESP, aimbot | Fresh shots aimed at, or crosshair following, an invisible admin (`amx_ac_ghost`) that no honest player can see |

Plus direct kicks without scoring: duplicate SteamID (emulators) and the IP/subnet blacklist.

## Installation

1. Compile `scripting/*.sma` with the includes from `scripting/include/` (for `amxac_antiesp` also the ReAPI includes).
2. Put the `.amxx` files into `addons/amxmodx/plugins/` and add the lines from `configs/plugins-amxac.ini` to `plugins.ini`. `amxac_core` goes first; drop `amxac_antiesp` without ReAPI.
3. Copy `configs/amxac.cfg` (or `configs/ru/amxac.cfg` with Russian comments), `amxac_cvars.ini` and `amxac_blocked_ips.ini` into `addons/amxmodx/configs/`.
4. For the first week keep all punishments at `none` and `amxac_notify_reports 1`, read the logs and tune thresholds. Then enable punishments.

Every setting is commented in `amxac.cfg`.

**Server types:**
- autobhop servers: `amxac_w_bhop 0`;
- KZ / bhop servers: `amxac_w_sgs 0`, `amxac_w_strafe 0` or raised thresholds — scrolling and good strafes are normal there;
- knife servers: knifebot is already strict, lower `amxac_w_knifebot` if needed.

## Commands

| Command | |
|---|---|
| `amx_ac_status [player]` | scores per player / per module |
| `amx_ac_reset <player>` | clear a player's score |
| `amx_ac_modules` | loaded modules and weights |
| `amx_ac_punish <player> <kick\|ban\|mute>` | punish now |
| `amx_ac_cancel <player>` / `amx_ac_unmute <player>` | cancel a pending punishment / lift a mute |
| `amx_ac_blockip` / `amx_ac_unblockip` / `amx_ac_blocklist` | IP blacklist (`1.2.3.4` or `1.2.3.0/24`) |
| `amx_ac_ghost` | toggle the honeypot ghost (walk with Shift: footsteps can't be muted) |
| `amx_awh_stats` | anti-wallhack trace usage |
| `amx_ac_test <mode\|list\|off> [player]` | self-test modes |

`amxac_debug 1` prints why a detector fired or not into the console of admins with the rcon flag.

## Testing

Enable `amxac_selftest` on a test server (above `amxac_aim`/`amxac_move` in `plugins.ini`), add bots and turn on one mode at a time: `silent`, `aim`, `trigger`, `wall`, `norecoil`, `knife`, `zoom`, `rapid`, `bhop`, `sgs`, `macro`, `strafe`, `speed`, `zero`, `movehack`, `pitch`, `spin`. Watch `amx_ac_status` and the log; `amx_ac_test list` explains each mode.

## API

```pawn
#include <amxac>

new g_mod = amxac_register_module("mycheck");
amxac_report(id, g_mod, 10.0, "reason %d", value);
amxac_set_ignore(id, -1, 2.0);   // e.g. around a teleport in your mod
```

Forwards `amxac_on_report` (return `PLUGIN_HANDLED` to drop a report) and `amxac_on_level`. Full list in `scripting/include/amxac.inc`.

## Compatibility

- **Unreal Aim Blocker**: list it below `amxac_aim` and `amxac_move`.
- **WHBlocker**: can replace `amxac_antiwh` (set `amxac_awh_enabled 0`, keep `amxac_awh_flash 1`); `amxac_antiesp` works with either.
- **UNREAL_ANTI_ESP**: don't run it together with `amxac_antiesp`.
