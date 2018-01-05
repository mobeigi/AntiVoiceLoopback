#include <sourcemod>
#include <sdktools>
#undef REQUIRE_PLUGIN
#include <basecomm>
#include <sourcecomms>

#pragma semicolon 1
#pragma newdecls required

/*********************************
 *  Plugin Information
 *********************************/
#define PLUGIN_VERSION "1.00"

public Plugin myinfo =
{
  name = "Anti Voice Loopback",
  author = "Invex | Byte",
  description = "Block HLDJ/SLAM/Voice Loopback tools",
  version = PLUGIN_VERSION,
  url = "https://invex.gg"
};

/*********************************
 *  Globals
 *********************************/

//ConVars
ConVar g_Cvar_AntiSpamMaxChanges = null;
ConVar g_Cvar_AntiSpamDuration = null;

//Main
bool g_IsClientMutedForLoopback[MAXPLAYERS+1] = {false, ...};
int g_ClientSettingsChangedCount[MAXPLAYERS+1] = {0, ...};
bool g_UsingServerSideBlock = false;
bool g_IsUsingBaseComms = false;
bool g_IsUsingSourceComms = false;

//Lateload
bool g_LateLoaded = false;

/*********************************
 *  Forwards
 *********************************/

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
  g_LateLoaded = late;
  
  return APLRes_Success;
}

public void OnPluginStart()
{
  //Translations
  LoadTranslations("antivoiceloopback.phrases");

  //ConVars
  g_Cvar_AntiSpamMaxChanges = CreateConVar("sm_avlb_antispammaxchanges", "5", "Number of voice_loopback changes allowed over 'sm_avlb_antispamduration' seconds");
  g_Cvar_AntiSpamDuration = CreateConVar("sm_avlb_antispamduration", "60.0", "Duration to count voice_loopback changed over in seconds", _, true, 1.0);

  //Lateload
  if (g_LateLoaded) {
    for (int i = 1; i <= MaxClients; ++i) {
      if (IsClientInGame(i)) {
        OnClientPutInServer(i);
      }
    }

    g_LateLoaded = false;
  }
}

public void OnAllPluginsLoaded()
{
  g_IsUsingBaseComms = LibraryExists("basecomm");
  g_IsUsingSourceComms = LibraryExists("sourcecomms");
  if (!g_IsUsingSourceComms)
    g_IsUsingSourceComms = LibraryExists("sourcecomms++");
}

public void OnLibraryAdded(const char[] name)
{
  if (StrEqual(name, "basecomm"))
    g_IsUsingBaseComms = true;
  if (StrEqual(name, "sourcecomms"))
		g_IsUsingSourceComms = true;
  if (StrEqual(name, "sourcecomms++"))
		g_IsUsingSourceComms = true;
}

public void OnLibraryRemoved(const char[] name)
{
  if (StrEqual(name, "basecomm"))
    g_IsUsingBaseComms = false;
  if (StrEqual(name, "sourcecomms"))
    g_IsUsingSourceComms = false;
  if (StrEqual(name, "sourcecomms++"))
    g_IsUsingSourceComms = false;
}

public void OnClientPutInServer(int client)
{
  g_IsClientMutedForLoopback[client] = false;
  g_ClientSettingsChangedCount[client] = 0;
  OnClientSettingsChanged(client);
}

public void OnConfigsExecuted()
{
  //Some games support disallowing voice_inputfromfile server side
  ConVar Cvar_AllowVoiceFromFile = FindConVar("sv_allow_voice_from_file");
  if (Cvar_AllowVoiceFromFile != null) {
    Cvar_AllowVoiceFromFile.SetBool(false);
    g_UsingServerSideBlock = true;
  }
}

public void OnClientSettingsChanged(int client)
{
  if (!IsClientInGame(client) || IsFakeClient(client))
    return;

  if (g_UsingServerSideBlock)
    return;
  
  QueryClientConVar(client, "voice_loopback", ConVarQuery_VoiceLoopback);
}

public void ConVarQuery_VoiceLoopback(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
  if (!IsClientInGame(client) || IsFakeClient(client))
    return;

  if (g_UsingServerSideBlock)
    return;

  //Ensure query was okay
  if (result != ConVarQuery_Okay) {
    //Todo: Do something here such as retry the query then kick client
    return;
  }

  //Mute or unmute a previously muted client based on their current loopback convar values
  bool usingLoopback = !!StringToInt(cvarValue);
  bool isClientMuted = AVLB_IsClientMuted(client);
  bool actionPerformed = false;

  if (usingLoopback && !isClientMuted) {
    AVLB_SetClientMute(client, true);
    PrintToChat(client, "%t", "Mute Message");
    actionPerformed = true;
  }
  else if (!usingLoopback && isClientMuted && g_IsClientMutedForLoopback[client]) {
    AVLB_SetClientMute(client, false);
    PrintToChat(client, "%t", "Unmute Message");
    actionPerformed = true;
  }

  //Anti-Spam protection
  //Kick users changing voice_loopback too frequently
  if (actionPerformed) {
    ++g_ClientSettingsChangedCount[client];

    if (g_ClientSettingsChangedCount[client] > g_Cvar_AntiSpamMaxChanges.IntValue) {
      KickClient(client, "%t", "Spamming Voice Loopback");
      return;
    }

    CreateTimer(g_Cvar_AntiSpamDuration.FloatValue, Timer_RemoveClientSettingsCount);
  }
}

//On unmutes by other plugins, check to see if we should remute for voice loopback
//This is needed so other unmutes don't allow user to use voice loopback
//Called when mute/unmute occurs by SourceComms_OnBlockAdded also
public void BaseComm_OnClientMute(int client, bool muteState)
{
  if (!IsClientInGame(client) || IsFakeClient(client))
    return;

  if (g_UsingServerSideBlock)
    return;

  if (!muteState)
    OnClientSettingsChanged(client);

  return;
}

/*********************************
 *  Timers
 *********************************/

public Action Timer_RemoveClientSettingsCount(Handle timer, int client)
{
  if (!IsClientInGame(client) || IsFakeClient(client))
    return Plugin_Stop;

  if (g_ClientSettingsChangedCount[client] > 0)
    --g_ClientSettingsChangedCount[client];

  return Plugin_Stop;
}

/*********************************
 *  Helper Functions / Other
 *********************************/

//Check if client is muted using SourceComms, BaseComm if available
bool AVLB_IsClientMuted(int client)
{
  if (g_IsUsingSourceComms) {
    return (SourceComms_GetClientMuteType(client) != bNot);
  }
  else if (g_IsUsingBaseComms) {
    return BaseComm_IsClientMuted(client);
  }
  else {
    return !!(GetClientListeningFlags(client) & VOICE_MUTED);
  }
}

//Set client mute using SourceComms, BaseComm if available
void AVLB_SetClientMute(int client, bool muteState)
{
  if (g_IsUsingSourceComms) {
    if (muteState) {
      char muteReason[64];
      Format(muteReason, sizeof(muteReason), "%t", "Mute Reason");
      SourceComms_SetClientMute(client, muteState, -1, true, muteReason); //-1 session mute, saved to DB
    }
    else
      SourceComms_SetClientMute(client, muteState);
  }
  else if (g_IsUsingBaseComms) {
    BaseComm_SetClientMute(client, muteState);
  }
  else {
    SetClientListeningFlags(client,  muteState ? (GetClientListeningFlags(client) | VOICE_MUTED) : (GetClientListeningFlags(client) & ~VOICE_MUTED));
  }

  g_IsClientMutedForLoopback[client] = muteState;
}
