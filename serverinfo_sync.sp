#include <sourcemod>
#include <cstrike>
#include <SteamWorks> // get real server IP
#include "include/restorecvars.inc"

#pragma newdecls required
#pragma semicolon 1

enum struct ClientInfo {
	char ip[32];
	char name[64];
}

enum struct ServerInfo {
	char ip[32];
	int port;

	int players; // player counts
	char hostname[256];
	char map[32];
}

Database g_db = null;

ConVar g_cDatabaseName,
g_cSyncPeriod;

bool g_bEnabled = false;

Handle g_hSyncTimer = INVALID_HANDLE;

StringMap g_Players;

ServerInfo g_ServerInfo;

public Plugin myinfo = {
	name = "Server Info Sync",
	author = "Xc_ace",
	description = "Sync server info to database",
	version = "1.0 alpha",
	url = "https://github.com/Cola-Ace/Server-Info-Sync"
}

public void OnPluginStart(){
	g_cDatabaseName = CreateConVar("sm_serverinfo_db_name", "serverinfo_sync", "Name in databases.cfg");
	g_cSyncPeriod = CreateConVar("sm_serverinfo_sync_period", "10.0", "Sync Period (recommended not too low and high)");	
	AutoExecConfig(true, "serverinfo_sync");
	ExecuteAndSaveCvars("sourcemod/serverinfo_sync.cfg");

	char error[256], db_name[64];
	g_cDatabaseName.GetString(db_name, sizeof(db_name));
	g_db = SQL_Connect(db_name, false, error, sizeof(error));
	if (g_db == null) SetFailState("Failed to connect database! Error: %s", error); // program ending

	g_Players = new StringMap();

	HookEvent("server_shutdown", Event_ShutDown);
}

public Action Event_ShutDown(Event event, const char[] error, bool dontBroadcast){
	char query[512];
	FormatEx(query, sizeof(query), "DELETE server_players WHERE ip='%s' AND port='%d'", g_ServerInfo.ip, g_ServerInfo.port);
	g_db.Query(SQL_CheckErrors, query);

	FormatEx(query, sizeof(query), "DELETE server_info WHERE ip='%s' AND port='%d'", g_ServerInfo.ip, g_ServerInfo.port);
	g_db.Query(SQL_CheckErrors, query);

	return Plugin_Continue;
}

public int SteamWorks_SteamServersConnected(){
	g_bEnabled = true;
	// it will be auto sync once when plugin is loaded
	Sync();
}

public void OnMapStart(){
	if (!g_bEnabled) return;
	g_hSyncTimer = CreateTimer(g_cSyncPeriod.FloatValue, Timer_Sync, _, TIMER_REPEAT);
}

public void OnMapEnd(){
	KillTimer(g_hSyncTimer);
	g_hSyncTimer = INVALID_HANDLE;
}

public Action Timer_Sync(Handle timer){
	Sync();

	return Plugin_Continue;
}

stock void UpdateServerInfo(){
	GetServerIP(g_ServerInfo.ip, sizeof(ServerInfo::ip));
	g_ServerInfo.port = GetServerPort();

	g_ServerInfo.players = GetPlayerCounts();
	FindConVar("hostname").GetString(g_ServerInfo.hostname, sizeof(ServerInfo::hostname));
	GetCurrentMap(g_ServerInfo.map, sizeof(ServerInfo::map));
}

stock void Sync(){
	UpdateServerInfo();
	
	char query[512];
	FormatEx(query, sizeof(query), "SELECT * FROM server_info WHERE ip='%s' AND port='%d'", g_ServerInfo.ip, g_ServerInfo.port);
	g_db.Query(SQL_CheckStatus, query);

	UpdatePlayerInfo();

	FormatEx(query, sizeof(query), "SELECT * FROM server_players WHERE server_ip='%s' AND port='%d'", g_ServerInfo.ip, g_ServerInfo.port);
	g_db.Query(SQL_SyncPlayers, query);
}

public void SQL_SyncPlayers(Database db, DBResultSet results, const char[] error, any data){
	if (results.FetchRow()){
		ArrayList delData = new ArrayList(64);
		ArrayList uploadData = new ArrayList(64);
		StringMap temple = g_Players.Clone();
		do {
			char auth[64];
			results.FetchString(3, auth, sizeof(auth));
			if (temple.ContainsKey(auth)){
				temple.Remove(auth);
				continue;
			}
			delData.PushString(auth);
		} while (results.FetchRow());
		StringMapSnapshot snap = temple.Snapshot();
		for (int i = 0; i < snap.Length; i++){
			char key[64];
			snap.GetKey(i, key, sizeof(key));
			uploadData.PushString(key);
		}
		delete temple;

		SyncPlayerInfo(delData, uploadData);

		return;
	}

	ArrayList uploadData = new ArrayList(64);
	StringMapSnapshot snap = g_Players.Snapshot();
	for (int i = 0; i < snap.Length; i++){
		char key[64];
		snap.GetKey(i, key, sizeof(key));
		uploadData.PushString(key);
	}
	
	SyncPlayerInfo(_, uploadData);
}

stock void SyncPlayerInfo(ArrayList del = INVALID_HANDLE, ArrayList upload = INVALID_HANDLE){
	char query[512], auth[64];
	if (del != INVALID_HANDLE){
		for (int i = 0; i < del.Length; i++){
			del.GetString(i, auth, sizeof(auth));
			FormatEx(query, sizeof(query), "DELETE FROM server_players WHERE steamid='%s'", auth);
			g_db.Query(SQL_CheckErrors, query);
		}
	}
	
	if (upload != INVALID_HANDLE){
		for (int i = 0; i < upload.Length; i++){
			upload.GetString(i, auth, sizeof(auth));
			ClientInfo info;
			g_Players.GetArray(auth, info, sizeof(info));
			FormatEx(query, sizeof(query), "INSERT INTO server_players (server_ip, port, steamid, ip, name) VALUES ('%s', '%d', '%s', '%s', '%s')", g_ServerInfo.ip, g_ServerInfo.port, auth, info.ip, info.name);
			g_db.Query(SQL_CheckErrors, query);
		}
	}
}

public void SQL_CheckStatus(Database db, DBResultSet results, const char[] error, any data){
	if (results.FetchRow()) SyncServerInfo();
	else Init();
}

stock void Init(){
	LogMessage("Initing...");
	char query[512];
	FormatEx(query, sizeof(query), "INSERT INTO server_info (ip, port, map, players, hostname) VALUES ('%s', '%d', '%s', '%d', '%s')", g_ServerInfo.ip, g_ServerInfo.port, g_ServerInfo.map, g_ServerInfo.players, g_ServerInfo.hostname);
	g_db.Query(SQL_CheckErrors, query);
}

stock void SyncServerInfo(){
	char query[512];
	FormatEx(query, sizeof(query), "UPDATE server_info SET map='%s', players='%d', hostname='%s' WHERE ip='%s' AND port='%d'", g_ServerInfo.map, g_ServerInfo.players, g_ServerInfo.hostname, g_ServerInfo.ip, g_ServerInfo.port);
	g_db.Query(SQL_CheckErrors, query);
}

stock void UpdatePlayerInfo(){
	for (int i = 0; i < MaxClients; i++){
		if (!IsPlayer(i)) continue;

		char auth[64];
		GetClientAuthId(i, AuthId_Steam2, auth, sizeof(auth));
		ClientInfo info;
		GetClientIP(i, info.ip, sizeof(ClientInfo::ip));
		GetClientName(i, info.name, sizeof(ClientInfo::name));
		g_Players.SetArray(auth, info, sizeof(info));
	}
}

// useful features

public void SQL_CheckErrors(Database db, DBResultSet results, const char[] error, any data){
	if (!StrEqual("", error)) LogError("Query Failed! %s", error);
}

stock void GetServerIP(char[] format, int size){
	int ip[4];
	SteamWorks_GetPublicIP(ip);
	FormatEx(format, size, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
}

stock int GetServerPort(){
	return FindConVar("hostport").IntValue;
}

stock int GetPlayerCounts(){ // including bot
	int count = 0;
	for (int i = 0; i < MaxClients; i++){
		if (IsPlayer(i)) count++;
	}
	return count;
}



stock bool IsPlayer(int client){
	return IsValidClient(client) && !IsFakeClient(client);
}

stock bool IsValidClient(int client){
	return (1 <= client <= MaxClients) && IsClientConnected(client) && IsClientInGame(client);
}