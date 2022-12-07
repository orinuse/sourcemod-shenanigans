// An excuse to learn KeyValues, eh?
#include <sourcemod>
#include <profiler>
#include <WeaponHandling>

#define DEBUG 1
#define PLUGIN_VERSION "1.0"
#define CONFIG_L4D1 "data/l4d1_shotgun_handler.cfg"
#define CONFIG_L4D2 "data/l4d2_shotgun_handler.cfg"

#pragma semicolon 1
#pragma newdecls required

ConVar g_hCvarDebug;
int g_iCvarDebug;
bool g_bL4D1;
Profiler g_hProfiler;

// ++ Preload ++ 
// -------------
public Plugin myinfo = 
{
	name = "[L4D/L4D2] Shotgun Handler",
	author = "Orinuse",
	description = "Framework to allow modding shotguns in ways you'd want, but you couldn't in weapon scripts.",
	version = PLUGIN_VERSION,
	url = "N/A"
};
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion engine = GetEngineVersion();
	g_bL4D1 = (engine == Engine_Left4Dead);
	if( g_bL4D1 != true && engine != Engine_Left4Dead2 )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

// ++ Loading ++ 
// -------------
public void OnPluginStart()
{
	CreateConVar("l4d_shotgun_handler_version", PLUGIN_VERSION, "'Shotgun Handler' plugin's version", FCVAR_SPONLY|FCVAR_DONTRECORD|FCVAR_NOTIFY);
	g_hCvarDebug = CreateConVar("l4d_shotgun_handler_debug", "0", "Outputs relevant weapon stats when shooting or reloading.", FCVAR_NOTIFY);

	RegAdminCmd("sm_sh_reload", 				CmdHandlerReload, ADMFLAG_ROOT, "Resets and reload the Shotgun Handler's config data.");
	
	g_hCvarDebug.AddChangeHook(ConVarChanged_Cvars);
	LoadKVConfig();
}
public void OnConfigsExecuted()
{
	g_iCvarDebug = g_hCvarDebug.IntValue;
}
public void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	g_iCvarDebug = g_hCvarDebug.IntValue;
}
////////////////////////////////////////////////////////////////////////////////////////
// Main variables
///////////////////////
enum // For reload modifiers's conditionals
{
	RELOADSTATE_NONE = 0,
	RELOADSTATE_FULLRELOAD = 2,
	RELOADSTATE_NORMAL = 3
}
enum
{
	RELOADANIMSTATE_NONE = 0,
	RELOADANIMSTATE_START = 1,
	RELOADANIMSTATE_INSERT = 2,
	RELOADANIMSTATE_END = 3
}

enum struct MedDef
{
	float mult_firetime_anim;
	float mult_reloadtime_start;
	float mult_reloadtime_insert;
	float mult_reloadtime_end;
	
	int mod_reloadpump_mode;
	
	float base_reloadtime_start;
	float base_reloadtime_insert;
	float base_reloadtime_end;

	L4D2WeaponType weapontype;
}

static StringMap g_hMapHandlerDefs;
static bool g_bStartedOnce[MAXPLAYERS+1], g_bInsertedOnce[MAXPLAYERS+1], g_bFinishedOnce[MAXPLAYERS+1]; // these ensure multipliers are resetted

////////////////////////////////////////////////////////////////////////////////////////
// Main routine
///////////////////////
public void WH_OnGetRateOfFire(int client, int weapon, L4D2WeaponType weapontype, float &speedmodifier)
{
	#if DEBUG
	g_hProfiler = CreateProfiler();
	g_hProfiler.Start();
	#endif
	
	//// ------------------------------------------ ////

	static MedDef def;
	static char sWeapon[24];
	GetEntityClassname(weapon, sWeapon, sizeof(sWeapon));
	g_hMapHandlerDefs.GetArray(sWeapon, def, sizeof(MedDef));

	if( def.weapontype != weapontype ) {
		return;
	}

	float modifier = def.mult_firetime_anim;
	float inverted_mult = 1.0 - (modifier - 1.0);
	speedmodifier = inverted_mult > 0.0 ? inverted_mult : 0.0;

	if( g_iCvarDebug ) {
		PrintToChatAll("(%.2fx)", modifier);
	}
	
	//// ------------------------------------------ ////

	#if DEBUG
	g_hProfiler.Stop();
	delete g_hProfiler;
	if( g_iCvarDebug ) {
		PrintToChatAll("\x04WH_OnGetRateOfFire: %f", g_hProfiler.Time);
	}
	#endif
}

public void WH_OnReloadModifier(int client, int weapon, L4D2WeaponType weapontype, float &speedmodifier)
{
	#if DEBUG
	g_hProfiler = CreateProfiler();
	g_hProfiler.Start();
	#endif

	// This isn't a shotgun!!!
	if( HasEntProp(weapon, Prop_Send, "m_reloadAnimState") == false ) {
		return;
	}
	
	//// ------------------------------------------ ////
	
	// A-1) Prep stuff for getting the definition
	/// I learnt that static doesn't really do anything in SM perf-wise, and only controls its "visibility"
	static MedDef def;
	static char sWeapon[24];
	static char sPropName[24];
	GetEntityClassname(weapon, sWeapon, sizeof(sWeapon));
	
	// A-2) Get and validate definition
	g_hMapHandlerDefs.GetArray(sWeapon, def, sizeof(MedDef));
	if( def.weapontype != weapontype ) {
		return;
	}
	
	// B) Variables
	int animstate = GetEntProp(weapon, Prop_Send, "m_reloadAnimState");
	
	// #1 - Pump modes
	////////////////////
	if( g_bL4D1 == true && def.mod_reloadpump_mode != -1 ) {
		SetEntProp(weapon, Prop_Send, "m_needPump", view_as<int>(def.mod_reloadpump_mode != 0 && def.mod_reloadpump_mode != 2));

		switch( def.mod_reloadpump_mode ) {
			case 2: {
				SetEntProp(weapon, Prop_Send, "m_reloadState", RELOADSTATE_NORMAL);
			}
			case 3: {
				SetEntProp(weapon, Prop_Send, "m_reloadState", RELOADSTATE_FULLRELOAD);
			}
		}
	}

	// #2 - Reload Modifiers
	//////////////////////////
	// When we get the current animstate, we can't apply multipliers
	// right away! Because the reload anim state order is.. hm. 
	//
	//	///////////////////////////////////////////////////////
	//	// Reload anim state order (without "is_dupeanim")
	//	// Variable "X" is the amount of shells that can be reloaded in the clip
	//	//
	//	// 1. STATE_END (isolated)
	//	// 2. STATE_END (isolated)
	//	// 3. STATE_START (isolated)
	//	// 4. STATE_START
	//	// 5 to (X-1) - STATE_INSERT
	//	// X. STATE_START
	//	///////////////////////////////////////////////////////
	//
	// With this in mind, we must check if states have already been
	// happened for a client to avoid applying modifiers twice or more,
	// including the NONE state since that actually pops up iirc?
	//
	// I know.. but there's no better way to write this.. SO SHIELD
	// YOUR EYES!!!
	///////////////////////////////////////////////////////////////////
	if( animstate == RELOADANIMSTATE_NONE ) {
		g_bStartedOnce[client] = false, g_bInsertedOnce[client] = false, g_bFinishedOnce[client] = false;
		return;
	}
	
	// 1. Reload Anim States
	// Grab the correct reload mod, go find the correct
	// netprop and set the correct array entries.
	///////////////////////////////////////////////////////
	bool is_dupeanim = (animstate == RELOADANIMSTATE_START && g_bStartedOnce[client] || animstate == RELOADANIMSTATE_INSERT && g_bInsertedOnce[client] || animstate == RELOADANIMSTATE_END && g_bFinishedOnce[client]);
	float modifier, duration;
	switch( animstate )
	{
		case RELOADANIMSTATE_START: {
			if( is_dupeanim == false ) {
				duration = def.base_reloadtime_start;
				strcopy(sPropName, sizeof(sPropName), "m_reloadStartDuration");
				g_bStartedOnce[client] = true, g_bInsertedOnce[client] = false, g_bFinishedOnce[client] = false;

				if( g_iCvarDebug ) {
					PrintToChatAll("\x05%N - %s (%i)", client, sWeapon, weapon);
					PrintToChatAll("\x05| Start", g_bStartedOnce[client]);
				}
			}
			modifier = def.mult_reloadtime_start;

		}
		case RELOADANIMSTATE_INSERT: {
			if( is_dupeanim == false ) {
				duration = def.base_reloadtime_insert;
				strcopy(sPropName, sizeof(sPropName), "m_reloadInsertDuration");
				g_bStartedOnce[client]  = false, g_bInsertedOnce[client] = true, g_bFinishedOnce[client] = false;

				if( g_iCvarDebug ) {
					PrintToChatAll("\x05| Insert", g_bInsertedOnce[client]);
				}
			}
			modifier = def.mult_reloadtime_insert;

		}
		case RELOADANIMSTATE_END: {
			if( is_dupeanim == false ) {
				duration = def.base_reloadtime_end;
				strcopy(sPropName, sizeof(sPropName), "m_reloadEndDuration");
				g_bStartedOnce[client]  = false, g_bInsertedOnce[client] = false, g_bFinishedOnce[client] = true;

				if( g_iCvarDebug ) {
					PrintToChatAll("\x05| Finish", g_bFinishedOnce[client]);
				}
			}
			modifier = def.mult_reloadtime_end;

		}
	}

	// 2. Apply multipliers
	// Before setting the reload duration props, we need to
	// invert the numbers first, like "1.75" to "0.25".
	///////////////////////////////////////////////////////
	if( is_dupeanim == false ) {
		duration *= modifier;
		SetEntPropFloat(weapon, Prop_Send, sPropName, duration);

		if( g_iCvarDebug ) {
			PrintToChatAll("(%.2fx | %.3f duration)", modifier, duration);
		}
	}
	float inverted_mult = 1.0 - (modifier - 1.0);
	if( inverted_mult > 0.0 ) {
		speedmodifier = inverted_mult;
	}

	//// ------------------------------------------ ////

	#if DEBUG
	g_hProfiler.Stop();
	delete g_hProfiler;
	if( g_iCvarDebug ) {
		PrintToChatAll("\x04WH_OnReloadModifier: %f", g_hProfiler.Time);
	}
	#endif
}

////////////////////////////////////////////////////////////////////////////////////////
// ++ Keyvalues ++
// Configuration file parsing
///////////////////////
void LoadKVConfig()
{
	// ++ Load ++
	// ----------
	g_hMapHandlerDefs = new StringMap();
	KeyValues kv = new KeyValues("ShotgunHandler");
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), g_bL4D1 ? CONFIG_L4D1 : CONFIG_L4D2);
	if( !kv.ImportFromFile(sPath) )
	{
		delete kv;
		SetFailState("Couldn't load the config file?! The hell did you do?");
		return;
	}
	
	// ++ Start ++
	// -----------
	char sSection[24];
	MedDef def;
	kv.GotoFirstSubKey();
	do
	{
		// Operation C.I.T.
		/// #1 Collect
		def.mult_firetime_anim	= kv.GetFloat("mult_firetime_anim", 1.0);
		def.mult_reloadtime_start	= kv.GetFloat("mult_reloadtime_start", 1.0);
		def.mult_reloadtime_insert	= kv.GetFloat("mult_reloadtime_insert", 1.0);
		def.mult_reloadtime_end 	= kv.GetFloat("mult_reloadtime_end", 1.0);
		
		def.base_reloadtime_start	= kv.GetFloat("base_reloadtime_start", 0.5);
		def.base_reloadtime_insert	= kv.GetFloat("base_reloadtime_insert", 0.5);
		def.base_reloadtime_end 	= kv.GetFloat("base_reloadtime_end", 0.5);
		
		def.weapontype	= view_as<L4D2WeaponType>(kv.GetNum("weapontype", 0));
		def.mod_reloadpump_mode	= kv.GetNum("mod_reloadpump_mode", -1);
		
		/// #2 Insert
		kv.GetSectionName(sSection, sizeof(sSection));
		g_hMapHandlerDefs.SetArray(sSection, def, sizeof(MedDef), false);
		
		/// #3 There isn't one
	} while (kv.GotoNextKey(false));
	delete kv;
}
// Reload the config
public Action CmdHandlerReload(int client, int args)
{
	// The profiler is just for flair really, the number won't ever be anything meaningful
	// My KV config isn't setup in a complex way with many blocks to traverse
	g_hProfiler = CreateProfiler();
	g_hProfiler.Start();

	g_hMapHandlerDefs.Clear();
	LoadKVConfig();
	
	g_hProfiler.Stop();
	ReplyToCommand(client, "\x05[Shotgun Handler]\x01 Config Reloaded. \x04(took %fs)", g_hProfiler.Time);

	// Okay, lets go home
	delete g_hProfiler;
	return Plugin_Handled;
}