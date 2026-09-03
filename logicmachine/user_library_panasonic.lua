--[[
================================================================================
  PANASONIC COMFORT CLOUD — C-BUS / LOGICMACHINE INTEGRATION MODULE
================================================================================
  Module:      user.panasonic / panasonic
  Platform:    LogicMachine 5 / SE Wiser / NAC / SHAC (C-Bus)
  Description: Bi-directional driver for Panasonic Comfort Cloud AC & Heat Pumps.
               Follows cbus-lua skill structure, safe C-Bus I/O with error suppression,
               Auth0 OAuth2 token refresh, dynamic SHA-256 HMAC signing, version
               auto-fallback on 4106 errors, and secrets isolation via user.secrets.
================================================================================
--]]

-- =============================================================================
-- 1. REQUIRE / MODULE TABLE & GLOBAL REGISTRATION
-- =============================================================================

local https = require("ssl.https")
local ltn12 = require("ltn12")
local json  = require("json")

-- Support both 'crypto' and 'sha2' libraries across different LM firmware builds
local sha2 = nil
local ok, mod = pcall(require, "sha2")
if ok and mod then
  sha2 = mod
else
  ok, mod = pcall(require, "crypto")
  if ok and mod and mod.digest then
    sha2 = {
      sha256hex = function(s) return mod.digest("sha256", s) end
    }
  end
end

local P = {}
panasonic = P   -- Global registration for C-Bus / LM execution environment


-- =============================================================================
-- 2. CONFIGURATION
-- =============================================================================

-- C-Bus Network ID (Default: 0 for local network)
local CBUS_NETWORK = 0

-- UserParam name for toggling debug output (Boolean: true/false or 1/0)
local DEBUG_PARAM = "Panasonic_Debug"

-- Panasonic Client Constants (Auth0 public client configuration)
local APP_CLIENT_ID   = "X3n9Xyc118pkd73PChweC4w87Wnc1ids"
local AUTH0_CLIENT    = "eyJuYW1lIjoiQXV0aDAuc3dpZnQiLCJlbnYiOnsiaU9TIjoiMTYuNSJ9LCJ2ZXJzaW9uIjoiMi41LjAifQ=="
local AUTH_USER_AGENT = "Panasonic/2.18.0 CFNetwork/1408.0.4 Darwin/22.5.0"
local BASE_PATH_AUTH  = "https://authglb.digital.panasonic.com"
local BASE_PATH_ACC   = "https://accsmart.panasonic.com"
local DEFAULT_APP_VERSION = "1.20.0"

-- Persistent storage keys in LogicMachine database
local STORAGE_KEY         = "panasonic_session"
local STORAGE_VERSION_KEY = "panasonic_app_version"

-- Target temperature boundaries (°C)
local MIN_TARGET_TEMP = 16.0
local MAX_TARGET_TEMP = 30.0

-- Network timeouts (seconds)
local HTTP_TIMEOUT_SEC = 10


-- =============================================================================
-- 3. ID MAPS / LOOKUP TABLES
-- =============================================================================

-- Operation Modes (0: Auto, 1: Dry, 2: Cool, 3: Heat, 4: Fan)
P.OperationMode = {
  Auto = 0,
  Dry  = 1,
  Cool = 2,
  Heat = 3,
  Fan  = 4
}

-- Fan Speeds (0: Auto, 1: Low, 2: LowMid, 3: Mid, 4: HighMid, 5: High)
P.FanSpeed = {
  Auto    = 0,
  Low     = 1,
  LowMid  = 2,
  Mid     = 3,
  HighMid = 4,
  High    = 5
}

-- Eco / Preset Modes (0: Auto, 1: Powerful, 2: Quiet)
P.EcoMode = {
  Auto     = 0,
  Powerful = 1,
  Quiet    = 2
}

-- Vertical Air Swing (UD)
P.AirSwingUD = {
  Auto    = -1,
  Up      = 0,
  UpMid   = 3,
  Mid     = 2,
  DownMid = 4,
  Down    = 1,
  Swing   = 5
}

-- Horizontal Air Swing (LR)
P.AirSwingLR = {
  Auto     = -1,
  Left     = 1,
  LeftMid  = 5,
  Mid      = 2,
  RightMid = 4,
  Right    = 0
}

-- Nanoe Air Purification Modes
P.NanoeMode = {
  Unavailable = 0,
  Off         = 1,
  On          = 2,
  ModeG       = 3,
  All         = 4
}

local OPERATION_MODE_NAMES = {
  [0] = "Auto",
  [1] = "Dry",
  [2] = "Cool",
  [3] = "Heat",
  [4] = "Fan"
}

local FAN_SPEED_NAMES = {
  [0] = "Auto",
  [1] = "Low",
  [2] = "LowMid",
  [3] = "Mid",
  [4] = "HighMid",
  [5] = "High"
}

local ECO_MODE_NAMES = {
  [0] = "Auto",
  [1] = "Powerful",
  [2] = "Quiet"
}


-- =============================================================================
-- 4. MODULE STATE
-- =============================================================================

-- Tracks missing UserParams to log warning once per session and avoid flooding
local _missingParamWarned = {}

-- Cached in-memory token state
local _cachedSession = nil

-- Cached App Version
local _cachedAppVersion = nil


-- =============================================================================
-- 5. LOGGING HELPERS
-- =============================================================================

-- Check if debug logging is enabled via C-Bus UserParam or LM storage
local function isDebuggingEnabled()
  local ok, val = pcall(GetUserParam, CBUS_NETWORK, DEBUG_PARAM)
  if ok and val ~= nil then
    if type(val) == "boolean" then return val end
    if type(val) == "number" then return val ~= 0 end
    if type(val) == "string" then return val == "1" or val:lower() == "true" or val:lower() == "yes" end
  end
  return false
end

-- Conditional debug logger
local function debuglog(str, debugEnabled)
  if debugEnabled then
    log("PANASONIC [DEBUG]: " .. tostring(str))
  end
end


-- =============================================================================
-- 6. C-BUS I/O HELPERS (ALWAYS WRAPPED IN PCALL)
-- =============================================================================

-- Safe read for UserParam — returns value or nil
local function safeGetUserParam(network, name)
  local ok, val = pcall(GetUserParam, network, name)
  return ok and val or nil
end

-- Safe write for UserParam — silently skips nil values; warns once per missing param
local function safeSetUserParam(network, name, value, debugEnabled)
  if value == nil then return end
  local ok = pcall(SetUserParam, network, name, value)
  if not ok then
    local key = tostring(network) .. ":" .. tostring(name)
    if debugEnabled or not _missingParamWarned[key] then
      log("PANASONIC: UserParam '" .. tostring(name) .. "' does not exist on network '"
          .. tostring(network) .. "' – skipping write")
      _missingParamWarned[key] = true
    end
  end
end

-- Safe write for Group Address — silently skips nil; checks for updates before writing
local function safeSetGroup(addr, value, debugEnabled)
  if addr == nil or value == nil then return end
  if type(grp) == "table" and grp.checkupdate then
    local ok, err = pcall(grp.checkupdate, addr, value)
    if not ok and debugEnabled then
      debuglog("Failed grp.checkupdate on " .. tostring(addr) .. ": " .. tostring(err), debugEnabled)
    end
  elseif type(SetCBusLevel) == "function" then
    pcall(SetCBusLevel, CBUS_NETWORK, 56, addr, value, 0)
  end
end


-- =============================================================================
-- 7. UTILITY & SECRETS HELPERS
-- =============================================================================

-- Load secrets safely from user.secrets or global secrets table
local function loadSecrets()
  local sec = nil
  if type(secrets) == "table" and secrets.panasonic then
    sec = secrets.panasonic
  else
    local ok, mod = pcall(require, "user.secrets")
    if ok and mod and mod.panasonic then
      sec = mod.panasonic
    else
      ok, mod = pcall(require, "secrets")
      if ok and mod and mod.panasonic then
        sec = mod.panasonic
      end
    end
  end
  return sec
end

-- Extract numeric float/int from string or raw value
local function extractNumber(val)
  if val == nil then return nil end
  if type(val) == "number" then return val end
  local n = tostring(val):match("^%-?%d+%.?%d*")
  return n and tonumber(n) or nil
end

-- Clamp numeric value between min and max
local function clamp(val, min_val, max_val)
  if val == nil then return nil end
  if val < min_val then return min_val end
  if val > max_val then return max_val end
  return val
end

-- Generate dynamic HMAC / SHA-256 signature key for Panasonic API requests
local function generateCfcApiKey(timestamp_ms, access_token)
  local raw_str = "Comfort Cloud" .. "521325fb2dd486bf4831b47644317fca" .. tostring(timestamp_ms) .. "Bearer " .. access_token
  local hex_hash = ""

  if sha2 and sha2.sha256hex then
    hex_hash = sha2.sha256hex(raw_str)
  else
    local handle = io.popen("printf '%s' " .. string.format("%q", raw_str) .. " | sha256sum | awk '{print $1}'")
    if handle then
      hex_hash = handle:read("*a"):gsub("%s+", "")
      handle:close()
    end
  end

  -- Insert "cfc" at character index 10 (1-based Lua string index)
  local api_key = string.sub(hex_hash, 1, 9) .. "cfc" .. string.sub(hex_hash, 10)
  return api_key
end

-- Retrieve active app version (or fetch latest if updated)
local function getAppVersion()
  if _cachedAppVersion then return _cachedAppVersion end
  if type(storage) == "table" and storage.get then
    local stored = storage.get(STORAGE_VERSION_KEY)
    if stored and #stored > 0 then
      _cachedAppVersion = stored
      return _cachedAppVersion
    end
  end
  _cachedAppVersion = DEFAULT_APP_VERSION
  return _cachedAppVersion
end

local function setAppVersion(new_version)
  if new_version and #new_version > 0 then
    _cachedAppVersion = new_version
    if type(storage) == "table" and storage.set then
      storage.set(STORAGE_VERSION_KEY, new_version)
    end
  end
end


-- =============================================================================
-- 8. DERIVED VALUE FUNCTIONS
-- =============================================================================

-- Format temperature values, ignoring Panasonic sentinel unplugged values (126, 255)
local function sanitizeTemperature(raw_val)
  local t = extractNumber(raw_val)
  if t == nil or t == 126 or t == 255 or t < -40 or t > 70 then
    return nil
  end
  return t
end

-- Human readable mode name
local function getModeName(mode_val)
  local m = extractNumber(mode_val)
  return m and OPERATION_MODE_NAMES[m] or "Unknown"
end

-- Human readable fan speed name
local function getFanSpeedName(speed_val)
  local s = extractNumber(speed_val)
  return s and FAN_SPEED_NAMES[s] or "Unknown"
end

-- Human readable eco mode name
local function getEcoModeName(eco_val)
  local e = extractNumber(eco_val)
  return e and ECO_MODE_NAMES[e] or "Unknown"
end


-- =============================================================================
-- 9. HTTP FETCH & AUTHENTICATION
-- =============================================================================

-- Internal HTTPS POST helper
local function httpsPostJson(url, payload_table, extra_headers, dbg)
  local req_body = json.encode(payload_table)
  local resp_body = {}

  local headers = {
    ["content-type"] = "application/json",
    ["content-length"] = tostring(#req_body),
    ["user-agent"] = "G-RAC"
  }

  if extra_headers then
    for k, v in pairs(extra_headers) do headers[k] = v end
  end

  debuglog("POST " .. url .. "\n  payload: " .. req_body, dbg)

  local res, code, response_headers, status = https.request{
    url = url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(req_body),
    sink = ltn12.sink.table(resp_body)
  }

  local body_str = table.concat(resp_body)
  debuglog("POST response code: " .. tostring(code) .. "\n  body: " .. body_str, dbg)

  local data = nil
  if body_str and #body_str > 0 then
    pcall(function() data = json.pdecode(body_str) or json.decode(body_str) end)
  end

  return code, data, body_str
end

-- Internal HTTPS GET helper
local function httpsGetJson(url, extra_headers, dbg)
  local resp_body = {}
  local headers = {
    ["accept"] = "application/json",
    ["user-agent"] = "G-RAC"
  }

  if extra_headers then
    for k, v in pairs(extra_headers) do headers[k] = v end
  end

  debuglog("GET " .. url, dbg)

  local res, code, response_headers, status = https.request{
    url = url,
    method = "GET",
    headers = headers,
    sink = ltn12.sink.table(resp_body)
  }

  local body_str = table.concat(resp_body)
  debuglog("GET response code: " .. tostring(code) .. "\n  body: " .. body_str, dbg)

  local data = nil
  if body_str and #body_str > 0 then
    pcall(function() data = json.pdecode(body_str) or json.decode(body_str) end)
  end

  return code, data, body_str
end

-- Build Comfort Cloud request headers
local function getAccHeaders(session, include_client_id)
  local now_sec = os.time()
  local timestamp_str = os.date("!%Y-%m-%d %H:%M:%S", now_sec)
  local timestamp_ms = now_sec * 1000

  local api_key = generateCfcApiKey(timestamp_ms, session.access_token)

  local headers = {
    ["accept"] = "application/json; charset=utf-8",
    ["content-type"] = "application/json",
    ["user-agent"] = "G-RAC",
    ["x-app-name"] = "Comfort Cloud",
    ["x-app-timestamp"] = timestamp_str,
    ["x-app-type"] = "1",
    ["x-app-version"] = getAppVersion(),
    ["x-cfc-api-key"] = api_key,
    ["x-user-authorization-v2"] = "Bearer " .. session.access_token
  }

  if include_client_id and session.client_id and #session.client_id > 0 then
    headers["x-client-id"] = session.client_id
  end

  return headers
end

-- Refresh OAuth2 Access Token using Refresh Token
function P.RefreshAccessToken(session, dbg)
  if not session or not session.refresh_token then
    log("PANASONIC: Cannot refresh token — missing refresh_token")
    return nil, "Missing refresh token"
  end

  debuglog("Refreshing OAuth2 access token...", dbg)

  local payload = {
    scope = session.scope or "openid offline_access comfortcloud.control a2w.control",
    client_id = APP_CLIENT_ID,
    refresh_token = session.refresh_token,
    grant_type = "refresh_token"
  }

  local extra_headers = {
    ["Auth0-Client"] = AUTH0_CLIENT,
    ["user-agent"] = AUTH_USER_AGENT
  }

  local code, resp = httpsPostJson(BASE_PATH_AUTH .. "/oauth/token", payload, extra_headers, dbg)
  if code ~= 200 or not resp or not resp.access_token then
    log("PANASONIC: Token refresh failed (HTTP " .. tostring(code) .. ")")
    return nil, "Token refresh failed: " .. tostring(code)
  end

  session.access_token = resp.access_token
  if resp.refresh_token then
    session.refresh_token = resp.refresh_token
  end
  session.expires_at = os.time() + (resp.expires_in or 3600)

  -- Acquire fresh Comfort Cloud Client ID
  local login_headers = getAccHeaders(session, false)
  local acc_code, acc_resp, acc_raw = httpsPostJson(BASE_PATH_ACC .. "/auth/v2/login", { language = 0 }, login_headers, dbg)

  -- Error 4106 indicates app version is outdated — attempt fallback/bump
  if acc_code == 401 and acc_raw and acc_raw:find("4106") then
    log("PANASONIC: App version rejected (code 4106), attempting version refresh...")
    -- Bump minor version fallback or fetch latest
    setAppVersion("1.21.0")
    login_headers = getAccHeaders(session, false)
    acc_code, acc_resp = httpsPostJson(BASE_PATH_ACC .. "/auth/v2/login", { language = 0 }, login_headers, dbg)
  end

  if acc_code == 200 and acc_resp and acc_resp.clientId then
    session.client_id = acc_resp.clientId
    debuglog("Acquired fresh ACC client_id: " .. tostring(session.client_id), dbg)
  end

  -- Save to persistent storage
  if type(storage) == "table" and storage.set then
    storage.set(STORAGE_KEY, session)
  end
  _cachedSession = session

  return session
end

-- Get a guaranteed valid session (auto-bootstraps from user.secrets if storage is empty)
function P.GetValidSession(dbg)
  local session = _cachedSession
  if not session and type(storage) == "table" and storage.get then
    session = storage.get(STORAGE_KEY)
  end

  -- Fallback / Bootstrap from user.secrets if storage is not yet initialized
  if not session or not session.refresh_token then
    local sec = loadSecrets()
    if sec and sec.refresh_token then
      debuglog("Bootstrapping session from user.secrets...", dbg)
      session = {
        refresh_token = sec.refresh_token,
        access_token  = sec.access_token,
        client_id     = sec.client_id,
        scope         = sec.scope or "openid offline_access comfortcloud.control a2w.control"
      }
    else
      log("PANASONIC: No credentials found in storage or user.secrets.")
      return nil, "No credentials"
    end
  end

  local now = os.time()
  if not session.access_token or not session.expires_at or (now >= session.expires_at - 120) or not session.client_id then
    return P.RefreshAccessToken(session, dbg)
  end

  _cachedSession = session
  return session
end


-- =============================================================================
-- 10. PAYLOAD PARSER & STATUS GETTERS
-- =============================================================================

-- Fetch all registered devices
function P.GetDevices(dbg)
  local session, err = P.GetValidSession(dbg)
  if not session then return nil, err end

  local headers = getAccHeaders(session, true)
  local code, resp = httpsGetJson(BASE_PATH_ACC .. "/device/group", headers, dbg)

  -- Handle token expiration retry
  if code == 401 then
    session = P.RefreshAccessToken(session, dbg)
    if session then
      headers = getAccHeaders(session, true)
      code, resp = httpsGetJson(BASE_PATH_ACC .. "/device/group", headers, dbg)
    end
  end

  if code == 200 and resp and resp.groupList then
    return resp.groupList
  end
  return nil, "Failed to get devices: HTTP " .. tostring(code)
end

-- Fetch and parse live status of a single AC GUID
function P.GetStatus(device_guid, dbg)
  -- Fallback to device_guid defined in user.secrets if not provided
  if not device_guid or #device_guid == 0 then
    local sec = loadSecrets()
    if sec and sec.device_guid then
      device_guid = sec.device_guid
    end
  end

  if not device_guid or #device_guid == 0 then
    return nil, "Device GUID is required"
  end

  local session, err = P.GetValidSession(dbg)
  if not session then return nil, err end

  local headers = getAccHeaders(session, true)
  local url = BASE_PATH_ACC .. "/deviceStatus/now/" .. tostring(device_guid)
  local code, resp = httpsGetJson(url, headers, dbg)

  if code == 401 then
    session = P.RefreshAccessToken(session, dbg)
    if session then
      headers = getAccHeaders(session, true)
      code, resp = httpsGetJson(url, headers, dbg)
    end
  end

  if code == 200 and resp and resp.parameters then
    local p = resp.parameters
    local parsed = {
      raw          = p,
      power        = p.operate == 1,
      target_temp  = sanitizeTemperature(p.temperatureSet),
      inside_temp  = sanitizeTemperature(p.insideTemperature),
      outside_temp = sanitizeTemperature(p.outTemperature),
      mode         = extractNumber(p.operationMode),
      mode_name    = getModeName(p.operationMode),
      fan_speed    = extractNumber(p.fanSpeed),
      fan_name     = getFanSpeedName(p.fanSpeed),
      eco_mode     = extractNumber(p.ecoMode),
      eco_name     = getEcoModeName(p.ecoMode),
      nanoe        = extractNumber(p.nanoe),
      air_swing_ud = extractNumber(p.airSwingUD),
      air_swing_lr = extractNumber(p.airSwingLR)
    }
    return parsed
  end

  return nil, "Status request failed: HTTP " .. tostring(code)
end

-- Send control parameters to an AC unit
function P.ControlDevice(device_guid, params, dbg)
  if not device_guid or #device_guid == 0 then
    local sec = loadSecrets()
    if sec and sec.device_guid then
      device_guid = sec.device_guid
    end
  end

  if not device_guid or #device_guid == 0 or not params or next(params) == nil then
    return false, "Missing GUID or parameters"
  end

  local session, err = P.GetValidSession(dbg)
  if not session then return false, err end

  local headers = getAccHeaders(session, true)
  local payload = {
    deviceGuid = device_guid,
    parameters = params
  }

  local url = BASE_PATH_ACC .. "/deviceStatus/control"
  local code, resp = httpsPostJson(url, payload, headers, dbg)

  if code == 401 then
    session = P.RefreshAccessToken(session, dbg)
    if session then
      headers = getAccHeaders(session, true)
      code, resp = httpsPostJson(url, payload, headers, dbg)
    end
  end

  if code == 200 then
    debuglog("Control command applied successfully: " .. json.encode(params), dbg)
    return true
  end

  log("PANASONIC: Control failed (HTTP " .. tostring(code) .. ")")
  return false, "Control failed: HTTP " .. tostring(code)
end


-- =============================================================================
-- 11. RESIDENT POLL & EVENT CONTROL ENTRY POINTS
-- =============================================================================

-- Debug alignment helper
local function printDebugTable(parsed)
  local lines = {
    "----------------------------------",
    "  PANASONIC COMFORT CLOUD STATUS  ",
    "----------------------------------"
  }
  lines[#lines + 1] = string.format("  %-20s %s", "Power:", parsed.power and "ON" or "OFF")
  lines[#lines + 1] = string.format("  %-20s %s °C", "Target Temp:", tostring(parsed.target_temp or "-"))
  lines[#lines + 1] = string.format("  %-20s %s °C", "Inside Temp:", tostring(parsed.inside_temp or "-"))
  lines[#lines + 1] = string.format("  %-20s %s °C", "Outside Temp:", tostring(parsed.outside_temp or "-"))
  lines[#lines + 1] = string.format("  %-20s %s (%s)", "Mode:", tostring(parsed.mode), parsed.mode_name)
  lines[#lines + 1] = string.format("  %-20s %s (%s)", "Fan Speed:", tostring(parsed.fan_speed), parsed.fan_name)
  lines[#lines + 1] = string.format("  %-20s %s (%s)", "Eco Mode:", tostring(parsed.eco_mode), parsed.eco_name)
  if parsed.nanoe ~= nil then
    lines[#lines + 1] = string.format("  %-20s %s", "Nanoe:", tostring(parsed.nanoe))
  end
  lines[#lines + 1] = "----------------------------------"
  log(table.concat(lines, "\n"))
end

-- Resident Poll entry point: Call from LogicMachine Resident Script (e.g. 60s interval)
function P.Resident_Poll(config)
  config = config or {}
  local guid = config.device_guid
  if not guid or #guid == 0 then
    local sec = loadSecrets()
    if sec and sec.device_guid then
      guid = sec.device_guid
    end
  end

  if not guid or #guid == 0 then
    log("PANASONIC: Resident_Poll called without device_guid (configure in script or user.secrets)")
    return
  end

  local dbg = isDebuggingEnabled()
  local status, err = P.GetStatus(guid, dbg)

  if not status then
    if err then log("PANASONIC Poll Error: " .. tostring(err)) end
    return
  end

  local objects = config.cbus_objects or {}

  -- 1. Sync Power (Boolean 01.001)
  if objects.power and status.power ~= nil then
    safeSetGroup(objects.power, status.power, dbg)
  end

  -- 2. Sync Temperatures (2-byte float 09.001)
  if objects.target_temp and status.target_temp ~= nil then
    safeSetGroup(objects.target_temp, status.target_temp, dbg)
  end
  if objects.inside_temp and status.inside_temp ~= nil then
    safeSetGroup(objects.inside_temp, status.inside_temp, dbg)
  end
  if objects.outside_temp and status.outside_temp ~= nil then
    safeSetGroup(objects.outside_temp, status.outside_temp, dbg)
  end

  -- 3. Sync Mode & Speeds (1-byte uint 05.010)
  if objects.mode and status.mode ~= nil then
    safeSetGroup(objects.mode, status.mode, dbg)
  end
  if objects.fan_speed and status.fan_speed ~= nil then
    safeSetGroup(objects.fan_speed, status.fan_speed, dbg)
  end
  if objects.eco_mode and status.eco_mode ~= nil then
    safeSetGroup(objects.eco_mode, status.eco_mode, dbg)
  end
  if objects.nanoe and status.nanoe ~= nil then
    safeSetGroup(objects.nanoe, status.nanoe, dbg)
  end

  -- 4. Sync UserParams (if configured)
  local params = config.cbus_params or {}
  if params.power then safeSetUserParam(CBUS_NETWORK, params.power, status.power and 1 or 0, dbg) end
  if params.target_temp then safeSetUserParam(CBUS_NETWORK, params.target_temp, status.target_temp, dbg) end
  if params.inside_temp then safeSetUserParam(CBUS_NETWORK, params.inside_temp, status.inside_temp, dbg) end
  if params.outside_temp then safeSetUserParam(CBUS_NETWORK, params.outside_temp, status.outside_temp, dbg) end
  if params.mode_name then safeSetUserParam(CBUS_NETWORK, params.mode_name, status.mode_name, dbg) end
  if params.fan_name then safeSetUserParam(CBUS_NETWORK, params.fan_name, status.fan_name, dbg) end
  if params.eco_name then safeSetUserParam(CBUS_NETWORK, params.eco_name, status.eco_name, dbg) end

  -- 5. Debug output
  if dbg then
    printDebugTable(status)
  end
end

-- Event Control entry point: Call from LogicMachine Event Script
function P.Event_Control(config, dst_addr, val)
  config = config or {}
  local guid = config.device_guid
  if not guid or #guid == 0 then
    local sec = loadSecrets()
    if sec and sec.device_guid then
      guid = sec.device_guid
    end
  end

  if not guid or #guid == 0 then
    log("PANASONIC: Event_Control called without device_guid (configure in script or user.secrets)")
    return
  end

  local dbg = isDebuggingEnabled()
  local objects = config.cbus_objects or {}
  local params = {}

  -- Power (Boolean or Level)
  if dst_addr == objects.power then
    params.operate = (val == true or val == 1 or val == 255) and 1 or 0

  -- Target Temperature (16.0 - 30.0)
  elseif dst_addr == objects.target_temp then
    local t = extractNumber(val)
    if t then
      params.temperatureSet = clamp(t, MIN_TARGET_TEMP, MAX_TARGET_TEMP)
    end

  -- Operation Mode (0-4)
  elseif dst_addr == objects.mode then
    local m = extractNumber(val)
    if m and m >= 0 and m <= 4 then
      params.operationMode = m
    end

  -- Fan Speed (0-5)
  elseif dst_addr == objects.fan_speed then
    local s = extractNumber(val)
    if s and s >= 0 and s <= 5 then
      params.fanSpeed = s
    end

  -- Eco / Preset Mode (0-2)
  elseif dst_addr == objects.eco_mode then
    local e = extractNumber(val)
    if e and e >= 0 and e <= 2 then
      params.ecoMode = e
    end

  -- Nanoe Mode (0-4)
  elseif dst_addr == objects.nanoe then
    local n = extractNumber(val)
    if n and n >= 0 and n <= 4 then
      params.nanoe = n
    end
  end

  -- Dispatch if matched
  if next(params) ~= nil then
    debuglog("Dispatching event change for " .. tostring(dst_addr) .. ": " .. json.encode(params), dbg)
    P.ControlDevice(guid, params, dbg)
  end
end

return P
