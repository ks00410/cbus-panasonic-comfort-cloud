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

  Features:
    - Full Climate Control: Power, Target Temp, Inside/Outside Temp, Mode, Fan Speed, Eco
    - Zone Damper Control: Multi-zone On/Off, Damper % (0-100), and Zone Temperatures
    - Energy & Power Telemetry: Daily Energy (kWh), Heating/Cooling Breakdown, Extrapolated Power (W)
    - Air Quality & Cleanliness: Nanoe air purification, Inside Cleaning mode
    - Louvre Swing: Vertical (UD) and Horizontal (LR) Swing modes
    - Advanced Eco: EcoNavi, iAuto-X / AI ECO
    - Diagnostics & Heartbeat: Online status, UTC timestamp, Error/Fault codes
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
local DEBUG_PARAM = "Debug"

-- Panasonic Client Constants (Public client configuration)
local APP_CLIENT_ID       = "Xmy6xIYIitMxngjB2rHvlm6HSDNnaMJx"
local AUTH0_CLIENT        = "eyJuYW1lIjoiQXV0aDAuQW5kcm9pZCIsImVudiI6eyJhbmRyb2lkIjoiMzAifSwidmVyc2lvbiI6IjIuOS4zIn0="
local AUTH_USER_AGENT     = "okhttp/4.10.0"
local BASE_PATH_AUTH      = "https://authglb.digital.panasonic.com"
local BASE_PATH_ACC       = "https://accsmart.panasonic.com"
local DEFAULT_APP_VERSION = "4.4.0"

-- Persistent storage keys in LogicMachine database
local STORAGE_KEY         = "panasonic_session"
local STORAGE_VERSION_KEY = "panasonic_app_version"

-- Target temperature boundaries (°C)
local MIN_TARGET_TEMP = 16.0
local MAX_TARGET_TEMP = 30.0


-- =============================================================================
-- 3. ID MAPS / LOOKUP TABLES
-- =============================================================================

-- Operation Modes (0: Auto, 1: Dry, 2: Cool, 3: Heat, 4: Fan)
P.OperationMode = { Auto = 0, Dry = 1, Cool = 2, Heat = 3, Fan = 4 }

-- Fan Speeds (0: Auto, 1: Low, 2: LowMid, 3: Mid, 4: HighMid, 5: High)
P.FanSpeed = { Auto = 0, Low = 1, LowMid = 2, Mid = 3, HighMid = 4, High = 5 }

-- Eco / Preset Modes (0: Auto, 1: Powerful, 2: Quiet)
P.EcoMode = { Auto = 0, Powerful = 1, Quiet = 2 }

-- Vertical Air Swing (UD)
P.AirSwingUD = { Auto = -1, Up = 0, UpMid = 3, Mid = 2, DownMid = 4, Down = 1, Swing = 5 }

-- Horizontal Air Swing (LR)
P.AirSwingLR = { Auto = -1, Left = 1, LeftMid = 5, Mid = 2, RightMid = 4, Right = 0 }

-- Nanoe Air Purification Modes
P.NanoeMode = { Unavailable = 0, Off = 1, On = 2, ModeG = 3, All = 4 }

-- EcoNavi / iAuto-X Modes
P.EcoNaviMode = { Unavailable = 0, Off = 1, On = 2 }
P.IAutoXMode  = { Unavailable = 0, Off = 1, On = 2 }
P.ZoneMode    = { Off = 0, On = 1 }

-- HVAC Action (Computed from setpoint, ambient temp, and operation mode)
-- 0 = Off, 1 = Idle, 2 = Heating, 3 = Cooling, 4 = Drying, 5 = Fan Only
P.HVACAction = { Off = 0, Idle = 1, Heating = 2, Cooling = 3, Drying = 4, FanOnly = 5 }

local OPERATION_MODE_NAMES = { [0] = "Auto", [1] = "Dry", [2] = "Cool", [3] = "Heat", [4] = "Fan" }
local FAN_SPEED_NAMES      = { [0] = "Auto", [1] = "Low", [2] = "LowMid", [3] = "Mid", [4] = "HighMid", [5] = "High" }
local ECO_MODE_NAMES       = { [0] = "Auto", [1] = "Powerful", [2] = "Quiet" }
local AIR_SWING_UD_NAMES   = { [-1] = "Auto", [0] = "Up", [3] = "UpMid", [2] = "Mid", [4] = "DownMid", [1] = "Down", [5] = "Swing" }
local AIR_SWING_LR_NAMES   = { [-1] = "Auto", [1] = "Left", [5] = "LeftMid", [2] = "Mid", [4] = "RightMid", [0] = "Right" }
local HVAC_ACTION_NAMES    = { [0] = "Off", [1] = "Idle", [2] = "Heating", [3] = "Cooling", [4] = "Drying", [5] = "Fan Only" }


-- =============================================================================
-- 4. MODULE STATE
-- =============================================================================

-- Tracks missing UserParams to log warning once per session and avoid flooding
local _missingParamWarned = {}

-- Cached in-memory token state
local _cachedSession = nil

-- Cached App Version
local _cachedAppVersion = nil

-- Energy extrapolation state: { last_consumption, last_time, power }
local _energyState = {}


-- =============================================================================
-- 5. LOGGING HELPERS
-- =============================================================================

-- Check if debug logging is enabled via C-Bus UserParam (matches Ecowitt / cbus-lua pattern)
local function isDebuggingEnabled(network, custom_debug_param)
  local net = network or CBUS_NETWORK
  local param_name = custom_debug_param or DEBUG_PARAM
  local ok, val = pcall(GetUserParam, net, param_name)
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

-- Safe write for C-Bus Group Address (e.g., Integer 0..255 or string "1/1/1")
local function safeSetGroup(addr, value, debugEnabled)
  if addr == nil or value == nil then return end

  -- Native C-Bus group helper
  if type(SetCBusLevel) == "function" and type(addr) == "number" then
    local lvl = value
    if type(value) == "boolean" then
      lvl = value and 255 or 0
    elseif type(value) == "number" then
      lvl = clamp(math.floor(value + 0.5), 0, 255)
    end
    pcall(SetCBusLevel, CBUS_NETWORK, 56, addr, lvl, 0)
    return
  end

  -- LogicMachine object helper
  if type(grp) == "table" and grp.checkupdate then
    local ok, err = pcall(grp.checkupdate, addr, value)
    if not ok and debugEnabled then
      debuglog("Failed grp.checkupdate on " .. tostring(addr) .. ": " .. tostring(err), debugEnabled)
    end
  end
end


-- =============================================================================
-- 7. UTILITY & SECRETS HELPERS
-- =============================================================================

-- Load secrets from the 'secrets' user library
local function loadSecrets()
  local ok, mod = pcall(require, "user.secrets")
  if ok and mod and mod.panasonic then
    return mod.panasonic
  end
  return secrets and secrets.panasonic or nil
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

-- Format local timezone offset as "+HH:MM" or "-HH:MM"
local function getLocalTimezoneOffset()
  local now = os.time()
  local utc_sec = os.time(os.date("!*t", now))
  local diff_sec = os.difftime(now, utc_sec)
  local sign = (diff_sec >= 0) and "+" or "-"
  diff_sec = math.abs(diff_sec)
  return string.format("%s%02d:%02d", sign, math.floor(diff_sec / 3600), math.floor((diff_sec % 3600) / 60))
end

-- URL encoding helper for device GUIDs containing '+' or other symbols
local function urlEncode(str)
  if str == nil then return "" end
  return tostring(str):gsub("([^%w%-%_%.%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
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
  return string.sub(hex_hash, 1, 9) .. "cfc" .. string.sub(hex_hash, 10)
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

-- Dynamically fetch the latest published version of Panasonic Comfort Cloud
-- Primary: Official Apple App Store lookup API (clean JSON, no HTML scraping)
-- Secondary: Google Play Store regex match
local function fetchLatestAppVersionOnline(dbg)
  debuglog("Querying online App Store for latest Comfort Cloud app version...", dbg)

  -- 1. Query Apple App Store Lookup API (App ID: 1348640525)
  local resp_body = {}
  local res, code = https.request({
    url = "https://itunes.apple.com/lookup?id=1348640525",
    method = "GET",
    headers = {
      ["accept"] = "application/json",
      ["user-agent"] = "Mozilla/5.0"
    },
    sink = ltn12.sink.table(resp_body)
  })

  if code == 200 then
    local raw = table.concat(resp_body)
    local ok, parsed = pcall(function() return json.pdecode(raw) or json.decode(raw) end)
    if ok and parsed and parsed.results and parsed.results[1] and parsed.results[1].version then
      local latest_ver = tostring(parsed.results[1].version):gsub("%s+", "")
      debuglog("Discovered latest App Store version: " .. latest_ver, dbg)
      setAppVersion(latest_ver)
      return latest_ver
    end
  end

  -- 2. Fallback: Google Play Store
  resp_body = {}
  res, code = https.request({
    url = "https://play.google.com/store/apps/details?id=com.panasonic.ACCsmart",
    method = "GET",
    headers = { ["user-agent"] = "Mozilla/5.0" },
    sink = ltn12.sink.table(resp_body)
  })

  if code == 200 then
    local raw = table.concat(resp_body)
    local match = raw:match('%["(%d+%.%d+%.%d+)"%]')
    if match then
      debuglog("Discovered latest Play Store version: " .. match, dbg)
      setAppVersion(match)
      return match
    end
  end

  -- 3. Fallback: Increment minor version if online lookup failed
  local curr = getAppVersion()
  local maj, min, pat = curr:match("^(%d+)%.(%d+)%.?(%d*)$")
  if maj and min then
    local bumped = string.format("%s.%d.0", maj, tonumber(min) + 1)
    debuglog("Online lookup failed; automatically bumped version to: " .. bumped, dbg)
    setAppVersion(bumped)
    return bumped
  end

  return curr
end


-- =============================================================================
-- 8. DERIVED VALUE FUNCTIONS
-- =============================================================================

-- Format temperature values, ignoring Panasonic sentinel unplugged values (126, 255, -255)
local function sanitizeTemperature(raw_val)
  local t = extractNumber(raw_val)
  if t == nil or t == 126 or t == 255 or t == -255 or t < -40 or t > 70 then
    return nil
  end
  return t
end

-- Calculate HVAC Action state:
-- 0 = Off, 1 = Idle, 2 = Heating, 3 = Cooling, 4 = Drying, 5 = Fan Only
local function calculateHVACAction(operate, mode, target_temp, inside_temp)
  if operate ~= 1 then return 0 end -- Off
  if mode == 1 then return 4 end    -- Drying
  if mode == 4 then return 5 end    -- Fan Only

  if not target_temp or not inside_temp then
    if mode == 3 then return 2 end -- Heat
    if mode == 2 then return 3 end -- Cool
    return 1 -- Idle
  end

  if mode == 3 then -- Heat
    return (target_temp > inside_temp) and 2 or 1
  elseif mode == 2 then -- Cool
    return (target_temp < inside_temp) and 3 or 1
  elseif mode == 0 then -- Auto
    local diff = target_temp - inside_temp
    if diff >= 1.0 then return 2 end
    if diff <= -1.0 then return 3 end
    return 1
  end

  return 1 -- Idle
end

-- Calculate instantaneous power (Watts) extrapolated from energy reading diffs
local function calculateExtrapolatedPower(guid, current_energy_kwh)
  if current_energy_kwh == nil or current_energy_kwh < 0 then return nil end

  local now_sec = os.time()
  local state = _energyState[guid]

  if not state then
    _energyState[guid] = { last_consumption = current_energy_kwh, last_time = now_sec, power = 0 }
    return 0
  end

  local time_diff_hr = (now_sec - state.last_time) / 3600.0
  local energy_diff_kwh = current_energy_kwh - state.last_consumption

  -- If meter reset at midnight or daily turnover, reset baseline
  if energy_diff_kwh < 0 then
    energy_diff_kwh = current_energy_kwh
  end

  if time_diff_hr > 0.001 and energy_diff_kwh > 0 then
    local power_watts = (energy_diff_kwh / time_diff_hr) * 1000.0
    state.power = math.floor(power_watts + 0.5)
    state.last_consumption = current_energy_kwh
    state.last_time = now_sec
  elseif time_diff_hr > (25 * 60) then
    state.power = 0
  end

  return state.power
end


-- =============================================================================
-- 9. HTTP FETCH & AUTHENTICATION
-- =============================================================================

-- Unified HTTPS JSON request engine
local function httpRequest(method, url, payload_table, extra_headers, dbg)
  local req_body = payload_table and json.encode(payload_table) or nil
  local resp_body = {}

  local headers = {
    ["accept"]     = "application/json; charset=utf-8",
    ["user-agent"] = "G-RAC"
  }
  if req_body then
    headers["content-type"] = "application/json"
    headers["content-length"] = tostring(#req_body)
  end
  if extra_headers then
    for k, v in pairs(extra_headers) do headers[k] = v end
  end

  debuglog(method .. " " .. url .. (req_body and ("\n  payload: " .. req_body) or ""), dbg)

  local req = {
    url     = url,
    method  = method,
    headers = headers,
    sink    = ltn12.sink.table(resp_body)
  }
  if req_body then
    req.source = ltn12.source.string(req_body)
  end

  local res, code, response_headers, status = https.request(req)
  local body_str = table.concat(resp_body)
  debuglog(method .. " response [" .. tostring(code) .. "]: " .. body_str, dbg)

  local data = nil
  if body_str and #body_str > 0 then
    pcall(function() data = json.pdecode(body_str) or json.decode(body_str) end)
  end

  return code, data, body_str
end

-- Build Comfort Cloud signed headers
local function getAccHeaders(session, include_client_id)
  local now_sec = os.time()
  -- Local time representation matching Panasonic app convention
  local timestamp_str = os.date("%Y-%m-%d %H:%M:%S", now_sec)
  -- Convert formatted local timestamp string components into naive UTC epoch milliseconds
  local utc_sec = os.time(os.date("!*t", now_sec))
  local offset_sec = os.difftime(now_sec, utc_sec)
  local timestamp_ms = string.format("%.0f", (now_sec + offset_sec) * 1000)

  local api_key = generateCfcApiKey(timestamp_ms, session.access_token)

  local headers = {
    ["x-app-name"]             = "Comfort Cloud",
    ["x-app-timestamp"]        = timestamp_str,
    ["x-app-type"]             = "1",
    ["x-app-version"]          = getAppVersion(),
    ["x-cfc-api-key"]          = api_key,
    ["x-user-authorization-v2"] = "Bearer " .. session.access_token
  }

  if include_client_id and session.client_id and #session.client_id > 0 then
    headers["x-client-id"] = session.client_id
  end

  return headers
end

-- Auto-accept Panasonic Terms & Privacy Agreements (resolves Error 412)
function P.AcceptAgreements(session, dbg)
  debuglog("Auto-accepting updated Panasonic Terms & Privacy Agreements...", dbg)
  local headers = getAccHeaders(session, false)

  -- 1. Fetch available agreement documents (requires language=0&includeContent=0)
  local doc_code, doc_resp = httpRequest("GET", BASE_PATH_ACC .. "/auth/v2/agreement/documents?language=0&includeContent=0", nil, headers, dbg)
  local to_accept = {}
  local auto_types = { [1] = true, [2] = true, [4] = true }

  if doc_code == 200 and doc_resp and doc_resp.agreementList then
    -- 2. Fetch currently accepted agreements
    local stat_code, stat_resp = httpRequest("GET", BASE_PATH_ACC .. "/auth/v2/agreement/status", nil, headers, dbg)
    local accepted_map = {}
    if stat_code == 200 and stat_resp and stat_resp.agreementList then
      for _, item in ipairs(stat_resp.agreementList) do
        if item.type and item.version then
          accepted_map[tonumber(item.type)] = tostring(item.version)
        end
      end
    end

    for _, doc in ipairs(doc_resp.agreementList) do
      local dtype = tonumber(doc.type)
      if dtype and auto_types[dtype] then
        local latest_ver = tostring(doc.version or "")
        if #latest_ver > 0 and accepted_map[dtype] ~= latest_ver then
          table.insert(to_accept, { type = dtype, version = latest_ver })
        end
      end
    end
  end

  -- Fallback: If document lookup failed or returned empty, submit latest known standard agreements for types 1, 2, 4
  if #to_accept == 0 then
    for dtype, _ in pairs(auto_types) do
      table.insert(to_accept, { type = dtype, version = "" })
    end
  end

  local put_headers = getAccHeaders(session, false)
  local put_code, put_resp, put_raw = httpRequest("PUT", BASE_PATH_ACC .. "/auth/v2/agreement/status", { agreementList = to_accept }, put_headers, dbg)
  if put_code == 200 then
    log("PANASONIC: Terms & Agreements accepted successfully (HTTP 200).")
    return true
  else
    debuglog("Agreement acceptance response (" .. tostring(put_code) .. "): " .. tostring(put_raw), dbg)
    return false
  end
end

-- Refresh OAuth2 Access Token using Refresh Token
function P.RefreshAccessToken(session, dbg)
  if not session or not session.refresh_token then
    log("PANASONIC: Cannot refresh token — missing refresh_token")
    return nil, "Missing refresh token"
  end

  debuglog("Refreshing OAuth2 access token...", dbg)

  local payload = {
    scope         = session.scope or "openid offline_access comfortcloud.control a2w.control",
    client_id     = APP_CLIENT_ID,
    refresh_token = session.refresh_token,
    grant_type    = "refresh_token"
  }

  local extra_headers = {
    ["Auth0-Client"] = AUTH0_CLIENT,
    ["user-agent"]   = AUTH_USER_AGENT
  }

  local code, resp = httpRequest("POST", BASE_PATH_AUTH .. "/oauth/token", payload, extra_headers, dbg)
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
  local acc_code, acc_resp, acc_raw = httpRequest("POST", BASE_PATH_ACC .. "/auth/v2/login", { language = 0 }, login_headers, dbg)

  -- Error 4106 indicates app version is outdated — dynamically discover latest version
  if acc_code == 401 and acc_raw and acc_raw:find("4106") then
    log("PANASONIC: App version rejected (code 4106), dynamically discovering latest version...")
    fetchLatestAppVersionOnline(dbg)
    login_headers = getAccHeaders(session, false)
    acc_code, acc_resp, acc_raw = httpRequest("POST", BASE_PATH_ACC .. "/auth/v2/login", { language = 0 }, login_headers, dbg)
  end

  -- Auto-accept agreements if HTTP 412 returned on login
  if acc_code == 412 then
    P.AcceptAgreements(session, dbg)
    login_headers = getAccHeaders(session, false)
    acc_code, acc_resp = httpRequest("POST", BASE_PATH_ACC .. "/auth/v2/login", { language = 0 }, login_headers, dbg)
  end

  if acc_code == 200 and acc_resp and acc_resp.clientId then
    session.client_id = acc_resp.clientId
    debuglog("Acquired fresh ACC client_id: " .. tostring(session.client_id), dbg)
  else
    log("PANASONIC: ACC Login returned HTTP " .. tostring(acc_code) .. " (clientId not acquired)")
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

-- Centralized ACC request wrapper with automatic 401 token refresh & retry
local function executeAccRequest(method, path, payload, dbg)
  local session, err = P.GetValidSession(dbg)
  if not session then return nil, err end

  local url = BASE_PATH_ACC .. path
  local headers = getAccHeaders(session, true)
  local code, resp, raw = httpRequest(method, url, payload, headers, dbg)

  -- If 401 Unauthorized, check for outdated app version (4106) or expired access token
  if code == 401 then
    if raw and raw:find("4106") then
      log("PANASONIC: App version rejected (code 4106), dynamically discovering latest version...")
      fetchLatestAppVersionOnline(dbg)
    end
    session = P.RefreshAccessToken(session, dbg)
    if session then
      headers = getAccHeaders(session, true)
      code, resp, raw = httpRequest(method, url, payload, headers, dbg)
    end
  -- If 412 Precondition Failed, accept agreements and re-authenticate to refresh client_id
  elseif code == 412 then
    log("PANASONIC: Received HTTP 412. Accepting agreements and refreshing session...")
    P.AcceptAgreements(session, dbg)
    session = P.RefreshAccessToken(session, dbg)
    if session then
      headers = getAccHeaders(session, true)
      code, resp, raw = httpRequest(method, url, payload, headers, dbg)
    end
  end

  return code, resp, raw
end


-- =============================================================================
-- 10. PAYLOAD PARSER & STATUS / ENERGY GETTERS
-- =============================================================================

-- Fetch all registered devices
function P.GetDevices(dbg)
  local code, resp = executeAccRequest("GET", "/device/group", nil, dbg)
  if code == 200 and resp and resp.groupList then
    return resp.groupList
  end
  return nil, "Failed to get devices: HTTP " .. tostring(code)
end

-- Fetch today's energy consumption data for a device
function P.GetEnergy(device_guid, dbg)
  local guid = device_guid
  if not guid or #guid == 0 then
    local sec = loadSecrets()
    guid = sec and sec.device_guid
  end
  if not guid or #guid == 0 then return nil, "Device GUID is required" end

  local today_str = os.date("%Y%m%d")
  local payload = {
    deviceGuid = guid,
    dataMode   = 2, -- Month data mode contains daily items
    date       = today_str,
    osTimezone = getLocalTimezoneOffset()
  }

  local code, resp = executeAccRequest("POST", "/deviceHistoryData", payload, dbg)
  if code == 200 and resp and resp.historyDataList then
    local energy_result = {
      consumption     = 0.0,
      heating_rate    = 0.0,
      cooling_rate    = 0.0,
      current_power_w = 0
    }

    for _, item in ipairs(resp.historyDataList) do
      if item.dataTime == today_str then
        local cons = extractNumber(item.consumption)
        local heat = extractNumber(item.heatConsumptionRate)
        local cool = extractNumber(item.coolConsumptionRate)
        if cons and cons >= 0 then energy_result.consumption = cons end
        if heat and heat >= 0 then energy_result.heating_rate = heat end
        if cool and cool >= 0 then energy_result.cooling_rate = cool end
        break
      end
    end

    energy_result.current_power_w = calculateExtrapolatedPower(guid, energy_result.consumption)
    return energy_result
  end

  return nil, "Energy fetch failed: HTTP " .. tostring(code)
end

-- Fetch and parse live status of a single AC GUID (including zones & telemetry)
function P.GetStatus(device_guid, dbg)
  local guid = device_guid
  if not guid or #guid == 0 then
    local sec = loadSecrets()
    guid = sec and sec.device_guid
  end
  if not guid or #guid == 0 then return nil, "Device GUID is required" end

  local code, resp = executeAccRequest("GET", "/deviceStatus/now/" .. urlEncode(guid), nil, dbg)
  if code == 200 and resp and resp.parameters then
    local p = resp.parameters
    local parsed = {
      raw               = p,
      power             = p.operate == 1,
      target_temp       = sanitizeTemperature(p.temperatureSet),
      inside_temp       = sanitizeTemperature(p.insideTemperature),
      outside_temp      = sanitizeTemperature(p.outTemperature),
      mode              = extractNumber(p.operationMode),
      mode_name         = OPERATION_MODE_NAMES[extractNumber(p.operationMode)] or "Unknown",
      fan_speed         = extractNumber(p.fanSpeed),
      fan_name          = FAN_SPEED_NAMES[extractNumber(p.fanSpeed)] or "Unknown",
      eco_mode          = extractNumber(p.ecoMode),
      eco_name          = ECO_MODE_NAMES[extractNumber(p.ecoMode)] or "Unknown",
      air_swing_ud      = extractNumber(p.airSwingUD),
      air_swing_ud_name = AIR_SWING_UD_NAMES[extractNumber(p.airSwingUD)] or "Unknown",
      air_swing_lr      = extractNumber(p.airSwingLR),
      air_swing_lr_name = AIR_SWING_LR_NAMES[extractNumber(p.airSwingLR)] or "Unknown",
      fan_auto_mode     = extractNumber(p.fanAutoMode),
      nanoe             = extractNumber(p.nanoe),
      eco_navi          = extractNumber(p.ecoNavi),
      iauto_x           = extractNumber(p.iAutoX) or extractNumber(p.iauto),
      inside_cleaning   = extractNumber(p.insideCleaning),
      air_quality       = extractNumber(p.airQuality),
      error_status      = extractNumber(p.errorStatus) or 0,
      hvac_action       = 0,
      hvac_action_name  = "Off",
      active_zones_count = 0,
      timestamp         = resp.timestamp or os.time(),
      zones             = {}
    }

    -- Calculate derived HVAC Action
    parsed.hvac_action = calculateHVACAction(p.operate, parsed.mode, parsed.target_temp, parsed.inside_temp)
    parsed.hvac_action_name = HVAC_ACTION_NAMES[parsed.hvac_action] or "Unknown"

    -- Parse Zone Parameters if ducted zoning is present
    if p.zoneParameters and type(p.zoneParameters) == "table" then
      for _, z in ipairs(p.zoneParameters) do
        local zid = extractNumber(z.zoneId)
        if zid then
          local is_on = (z.zoneOnOff == 1)
          if is_on then
            parsed.active_zones_count = parsed.active_zones_count + 1
          end
          parsed.zones[zid] = {
            id          = zid,
            name        = z.zoneName or ("Zone " .. tostring(zid)),
            power       = is_on,
            damper      = extractNumber(z.zoneLevel) or 0,
            temperature = sanitizeTemperature(z.zoneTemperature),
            spill       = extractNumber(z.zoneSpill) or 0
          }
        end
      end
    end

    return parsed
  end

  return nil, "Status request failed: HTTP " .. tostring(code)
end

-- Send control parameters to an AC unit or individual zones
function P.ControlDevice(device_guid, params, dbg)
  local guid = device_guid
  if not guid or #guid == 0 then
    local sec = loadSecrets()
    guid = sec and sec.device_guid
  end
  if not guid or #guid == 0 or not params or next(params) == nil then
    return false, "Missing GUID or parameters"
  end

  local payload = {
    deviceGuid = guid,
    parameters = params
  }

  local code, resp = executeAccRequest("POST", "/deviceStatus/control", payload, dbg)
  if code == 200 then
    debuglog("Control command applied successfully: " .. json.encode(params), dbg)
    return true
  end

  log("PANASONIC: Control failed (HTTP " .. tostring(code) .. ")")
  return false, "Control failed: HTTP " .. tostring(code)
end

-- Dedicated helper to control an individual zone
function P.ControlZone(device_guid, zone_id, zone_on_off, zone_level_percent, dbg)
  local zone_entry = { zoneId = tonumber(zone_id) }
  if zone_on_off ~= nil then
    zone_entry.zoneOnOff = (zone_on_off == true or zone_on_off == 1 or zone_on_off == 255) and 1 or 0
  end
  if zone_level_percent ~= nil then
    zone_entry.zoneLevel = clamp(math.floor(tonumber(zone_level_percent) + 0.5), 0, 100)
  end

  return P.ControlDevice(device_guid, { zoneParameters = { zone_entry } }, dbg)
end


-- =============================================================================
-- 11. RESIDENT POLL & EVENT CONTROL ENTRY POINTS
-- =============================================================================

-- Debug alignment helper
local function printDebugTable(parsed, energy)
  local lines = {
    "--------------------------------------------------",
    "         PANASONIC COMFORT CLOUD TELEMETRY        ",
    "--------------------------------------------------"
  }
  lines[#lines + 1] = string.format("  %-22s %s", "Power:", parsed.power and "ON" or "OFF")
  lines[#lines + 1] = string.format("  %-22s %s °C", "Target Temp:", tostring(parsed.target_temp or "-"))
  lines[#lines + 1] = string.format("  %-22s %s °C", "Inside Temp:", tostring(parsed.inside_temp or "-"))
  lines[#lines + 1] = string.format("  %-22s %s °C", "Outside Temp:", tostring(parsed.outside_temp or "-"))
  lines[#lines + 1] = string.format("  %-22s %s (%s)", "Mode:", tostring(parsed.mode), parsed.mode_name)
  lines[#lines + 1] = string.format("  %-22s %s (%s)", "Fan Speed:", tostring(parsed.fan_speed), parsed.fan_name)
  lines[#lines + 1] = string.format("  %-22s %s (%s)", "Eco Mode:", tostring(parsed.eco_mode), parsed.eco_name)
  lines[#lines + 1] = string.format("  %-22s %s (%s)", "Vertical Swing (UD):", tostring(parsed.air_swing_ud), parsed.air_swing_ud_name)
  lines[#lines + 1] = string.format("  %-22s %s (%s)", "Horizontal Swing (LR):", tostring(parsed.air_swing_lr), parsed.air_swing_lr_name)
  
  lines[#lines + 1] = string.format("  %-22s %s (%s)", "HVAC Action:", tostring(parsed.hvac_action), parsed.hvac_action_name)
  lines[#lines + 1] = string.format("  %-22s %d", "Active Zones Count:", parsed.active_zones_count or 0)
  
  if parsed.nanoe ~= nil then lines[#lines + 1] = string.format("  %-22s %s", "Nanoe:", tostring(parsed.nanoe)) end
  if parsed.eco_navi ~= nil then lines[#lines + 1] = string.format("  %-22s %s", "EcoNavi:", tostring(parsed.eco_navi)) end
  if parsed.iauto_x ~= nil then lines[#lines + 1] = string.format("  %-22s %s", "iAuto-X / AI ECO:", tostring(parsed.iauto_x)) end
  if parsed.inside_cleaning ~= nil then lines[#lines + 1] = string.format("  %-22s %s", "Inside Cleaning:", tostring(parsed.inside_cleaning)) end

  -- Zones
  if next(parsed.zones) ~= nil then
    lines[#lines + 1] = "  -- Zones --"
    for zid, z in pairs(parsed.zones) do
      lines[#lines + 1] = string.format("  Zone %d (%-12s): %s | Damper: %3d%% | Temp: %s °C",
        zid, z.name, z.power and "ON " or "OFF", z.damper, tostring(z.temperature or "-"))
    end
  end

  -- Energy
  if energy then
    lines[#lines + 1] = "  -- Energy & Power --"
    lines[#lines + 1] = string.format("  %-22s %.2f kWh", "Today's Consumption:", energy.consumption)
    lines[#lines + 1] = string.format("  %-22s %.2f kWh", "Heating Consumption:", energy.heating_rate)
    lines[#lines + 1] = string.format("  %-22s %.2f kWh", "Cooling Consumption:", energy.cooling_rate)
    lines[#lines + 1] = string.format("  %-22s %d W", "Extrapolated Power:", energy.current_power_w or 0)
  end

  lines[#lines + 1] = "--------------------------------------------------"
  log(table.concat(lines, "\n"))
end

-- Resident Poll entry point: Call from LogicMachine Resident Script (e.g. 60s interval)
function P.Resident_Poll(config)
  config = config or {}
  local guid = config.device_guid
  if not guid or #guid == 0 then
    local sec = loadSecrets()
    guid = sec and sec.device_guid
  end

  if not guid or #guid == 0 then
    log("PANASONIC: Resident_Poll called without device_guid (configure in script or user.secrets)")
    return
  end

  local net = config.cbus_network or CBUS_NETWORK
  local dbg = isDebuggingEnabled(net, config.debug_param)
  local status, err = P.GetStatus(guid, dbg)
  if not status then
    if err then log("PANASONIC Poll Error: " .. tostring(err)) end
    return
  end

  -- Optional Energy Fetch
  local energy = nil
  if config.enable_energy ~= false and (config.cbus_energy or config.cbus_params) then
    energy = P.GetEnergy(guid, dbg)
  end

  local objects = config.cbus_objects or {}

  -- 1. Sync Core Climate
  if objects.power and status.power ~= nil then safeSetGroup(objects.power, status.power, dbg) end
  if objects.target_temp and status.target_temp ~= nil then safeSetGroup(objects.target_temp, status.target_temp, dbg) end
  if objects.inside_temp and status.inside_temp ~= nil then safeSetGroup(objects.inside_temp, status.inside_temp, dbg) end
  if objects.outside_temp and status.outside_temp ~= nil then safeSetGroup(objects.outside_temp, status.outside_temp, dbg) end
  if objects.mode and status.mode ~= nil then safeSetGroup(objects.mode, status.mode, dbg) end
  if objects.fan_speed and status.fan_speed ~= nil then safeSetGroup(objects.fan_speed, status.fan_speed, dbg) end
  if objects.eco_mode and status.eco_mode ~= nil then safeSetGroup(objects.eco_mode, status.eco_mode, dbg) end
  if objects.air_swing_ud and status.air_swing_ud ~= nil then safeSetGroup(objects.air_swing_ud, status.air_swing_ud, dbg) end
  if objects.air_swing_lr and status.air_swing_lr ~= nil then safeSetGroup(objects.air_swing_lr, status.air_swing_lr, dbg) end
  if objects.nanoe and status.nanoe ~= nil then safeSetGroup(objects.nanoe, status.nanoe, dbg) end
  if objects.eco_navi and status.eco_navi ~= nil then safeSetGroup(objects.eco_navi, status.eco_navi, dbg) end
  if objects.iauto_x and status.iauto_x ~= nil then safeSetGroup(objects.iauto_x, status.iauto_x, dbg) end
  if objects.inside_cleaning and status.inside_cleaning ~= nil then safeSetGroup(objects.inside_cleaning, status.inside_cleaning, dbg) end
  if (objects.hvac_action or objects.action) and status.hvac_action ~= nil then
    safeSetGroup(objects.hvac_action or objects.action, status.hvac_action, dbg)
  end
  if (objects.active_zones_count or objects.active_zones) and status.active_zones_count ~= nil then
    safeSetGroup(objects.active_zones_count or objects.active_zones, status.active_zones_count, dbg)
  end

  -- 2. Sync Zones
  local zone_map = config.cbus_zones or {}
  for zid, zconf in pairs(zone_map) do
    local zdata = status.zones[tonumber(zid)]
    if zdata then
      if zconf.power and zdata.power ~= nil then safeSetGroup(zconf.power, zdata.power, dbg) end
      if zconf.damper and zdata.damper ~= nil then safeSetGroup(zconf.damper, zdata.damper, dbg) end
      if zconf.temp and zdata.temperature ~= nil then safeSetGroup(zconf.temp, zdata.temperature, dbg) end
    end
  end

  -- 3. Sync Energy Objects
  local energy_objects = config.cbus_energy or {}
  if energy then
    if energy_objects.daily_kwh and energy.consumption ~= nil then safeSetGroup(energy_objects.daily_kwh, energy.consumption, dbg) end
    if energy_objects.heating_kwh and energy.heating_rate ~= nil then safeSetGroup(energy_objects.heating_kwh, energy.heating_rate, dbg) end
    if energy_objects.cooling_kwh and energy.cooling_rate ~= nil then safeSetGroup(energy_objects.cooling_kwh, energy.cooling_rate, dbg) end
    if energy_objects.current_power_w and energy.current_power_w ~= nil then safeSetGroup(energy_objects.current_power_w, energy.current_power_w, dbg) end
  end

  -- 4. Sync UserParams (C-Bus parameters pattern)
  local pfx = config.param_prefix or "AC_"
  local net = config.cbus_network or CBUS_NETWORK

  -- Core climate UserParams
  safeSetUserParam(net, pfx .. "Power", status.power and 1 or 0, dbg)
  safeSetUserParam(net, pfx .. "TargetTemp", status.target_temp, dbg)
  safeSetUserParam(net, pfx .. "InsideTemp", status.inside_temp, dbg)
  safeSetUserParam(net, pfx .. "OutsideTemp", status.outside_temp, dbg)
  safeSetUserParam(net, pfx .. "Mode", status.mode, dbg)
  safeSetUserParam(net, pfx .. "Mode_Text", status.mode_name, dbg)
  safeSetUserParam(net, pfx .. "FanSpeed", status.fan_speed, dbg)
  safeSetUserParam(net, pfx .. "FanSpeed_Text", status.fan_name, dbg)
  safeSetUserParam(net, pfx .. "EcoMode", status.eco_mode, dbg)
  safeSetUserParam(net, pfx .. "EcoMode_Text", status.eco_name, dbg)
  safeSetUserParam(net, pfx .. "SwingUD", status.air_swing_ud, dbg)
  safeSetUserParam(net, pfx .. "SwingUD_Text", status.air_swing_ud_name, dbg)
  safeSetUserParam(net, pfx .. "SwingLR", status.air_swing_lr, dbg)
  safeSetUserParam(net, pfx .. "SwingLR_Text", status.air_swing_lr_name, dbg)
  safeSetUserParam(net, pfx .. "Nanoe", status.nanoe, dbg)
  safeSetUserParam(net, pfx .. "HVACAction", status.hvac_action, dbg)
  safeSetUserParam(net, pfx .. "HVACAction_Text", status.hvac_action_name, dbg)
  safeSetUserParam(net, pfx .. "ActiveZones", status.active_zones_count, dbg)
  safeSetUserParam(net, pfx .. "LastUpdated", os.date("%d %b %Y, %H:%M"), dbg)

  -- Zone UserParams
  for zid, zdata in pairs(status.zones) do
    safeSetUserParam(net, string.format("%sZone%d_Power", pfx, zid), zdata.power and 1 or 0, dbg)
    safeSetUserParam(net, string.format("%sZone%d_Damper", pfx, zid), zdata.damper, dbg)
    if zdata.temperature then
      safeSetUserParam(net, string.format("%sZone%d_Temp", pfx, zid), zdata.temperature, dbg)
    end
  end

  -- Energy UserParams
  if energy then
    safeSetUserParam(net, pfx .. "Daily_kWh", energy.consumption, dbg)
    safeSetUserParam(net, pfx .. "Heating_kWh", energy.heating_rate, dbg)
    safeSetUserParam(net, pfx .. "Cooling_kWh", energy.cooling_rate, dbg)
    safeSetUserParam(net, pfx .. "CurrentPower_W", energy.current_power_w, dbg)
  end

  -- Explicit custom UserParam mappings (if supplied)
  local params = config.cbus_params or {}
  if params.power then safeSetUserParam(net, params.power, status.power and 1 or 0, dbg) end
  if params.target_temp then safeSetUserParam(net, params.target_temp, status.target_temp, dbg) end
  if params.inside_temp then safeSetUserParam(net, params.inside_temp, status.inside_temp, dbg) end
  if params.outside_temp then safeSetUserParam(net, params.outside_temp, status.outside_temp, dbg) end
  if params.mode_name then safeSetUserParam(net, params.mode_name, status.mode_name, dbg) end
  if params.fan_name then safeSetUserParam(net, params.fan_name, status.fan_name, dbg) end
  if params.eco_name then safeSetUserParam(net, params.eco_name, status.eco_name, dbg) end
  if params.hvac_action_name then safeSetUserParam(net, params.hvac_action_name, status.hvac_action_name, dbg) end
  if energy and params.daily_kwh then safeSetUserParam(net, params.daily_kwh, energy.consumption, dbg) end
  if energy and params.current_power_w then safeSetUserParam(net, params.current_power_w, energy.current_power_w, dbg) end

  -- 5. Debug output
  if dbg then
    printDebugTable(status, energy)
  end
end

-- Event Control entry point: Call from LogicMachine Event Script
-- Supports C-Bus Group Addresses (integers 0..255 or strings), UserParam names, or event table
function P.Event_Control(config, dst_target, val)
  config = config or {}
  local guid = config.device_guid
  if not guid or #guid == 0 then
    local sec = loadSecrets()
    guid = sec and sec.device_guid
  end

  if not guid or #guid == 0 then
    log("PANASONIC: Event_Control called without device_guid (configure in script or user.secrets)")
    return
  end

  -- Support calling with event object directly: P.Event_Control(config, event)
  local target = dst_target
  local raw_val = val
  if type(target) == "table" and target.dst then
    raw_val = target.getvalue and target.getvalue() or target.value
    target = target.dst
  end

  local net = config.cbus_network or CBUS_NETWORK
  local dbg = isDebuggingEnabled(net, config.debug_param)
  local objects = config.cbus_objects or {}
  local zone_map = config.cbus_zones or {}
  local pfx = config.param_prefix or "AC_"
  local params = {}

  -- 1. Check Core Climate Controls (Group Addresses or UserParam names)
  if target == objects.power or target == (pfx .. "Power") then
    params.operate = (raw_val == true or raw_val == 1 or raw_val == 255) and 1 or 0
  elseif target == objects.target_temp or target == (pfx .. "TargetTemp") then
    local t = extractNumber(raw_val)
    if t then params.temperatureSet = clamp(t, MIN_TARGET_TEMP, MAX_TARGET_TEMP) end
  elseif target == objects.mode or target == (pfx .. "Mode") then
    local m = extractNumber(raw_val)
    if m and m >= 0 and m <= 4 then params.operationMode = m end
  elseif target == objects.fan_speed or target == (pfx .. "FanSpeed") then
    local s = extractNumber(raw_val)
    if s and s >= 0 and s <= 5 then params.fanSpeed = s end
  elseif target == objects.eco_mode or target == (pfx .. "EcoMode") then
    local e = extractNumber(raw_val)
    if e and e >= 0 and e <= 2 then params.ecoMode = e end
  elseif target == objects.air_swing_ud or target == (pfx .. "SwingUD") then
    local u = extractNumber(raw_val)
    if u and u >= -1 and u <= 5 then
      params.airSwingUD = u
      params.fanAutoMode = (u == -1) and 2 or 1
    end
  elseif target == objects.air_swing_lr or target == (pfx .. "SwingLR") then
    local l = extractNumber(raw_val)
    if l and l >= -1 and l <= 5 then
      params.airSwingLR = l
      params.fanAutoMode = (l == -1) and 3 or 1
    end
  elseif target == objects.nanoe or target == (pfx .. "Nanoe") then
    local n = extractNumber(raw_val)
    if n and n >= 0 and n <= 4 then params.nanoe = n end
  elseif target == objects.eco_navi or target == (pfx .. "EcoNavi") then
    local en = extractNumber(raw_val)
    if en and en >= 0 and en <= 2 then params.ecoNavi = en end
  elseif target == objects.iauto_x or target == (pfx .. "IAutoX") then
    local ia = extractNumber(raw_val)
    if ia and ia >= 0 and ia <= 2 then params.iAutoX = ia end
  elseif target == objects.inside_cleaning or target == (pfx .. "InsideCleaning") then
    local ic = extractNumber(raw_val)
    if ic and ic >= 0 and ic <= 1 then params.insideCleaning = ic end
  end

  -- 2. Check Zone Controls
  -- 2a. Dynamic pattern matching for any Zone UserParam: AC_Zone<N>_Power or AC_Zone<N>_Damper
  if type(target) == "string" then
    local zid_power = target:match("^" .. pfx .. "Zone(%d+)_Power$")
    if zid_power then
      local z_power = (raw_val == true or raw_val == 1 or raw_val == 255) and 1 or 0
      debuglog(string.format("Dispatching Zone %s Power change: %d", zid_power, z_power), dbg)
      P.ControlZone(guid, tonumber(zid_power), z_power, nil, dbg)
      return
    end

    local zid_damper = target:match("^" .. pfx .. "Zone(%d+)_Damper$")
    if zid_damper then
      local z_damper = extractNumber(raw_val)
      if z_damper then
        debuglog(string.format("Dispatching Zone %s Damper change: %d%%", zid_damper, z_damper), dbg)
        P.ControlZone(guid, tonumber(zid_damper), nil, z_damper, dbg)
        return
      end
    end
  end

  -- 2b. Mapped C-Bus Group Addresses in config.cbus_zones
  for zid, zconf in pairs(zone_map) do
    if target == zconf.power then
      local z_power = (raw_val == true or raw_val == 1 or raw_val == 255) and 1 or 0
      debuglog(string.format("Dispatching Zone %d Power change: %d", zid, z_power), dbg)
      P.ControlZone(guid, zid, z_power, nil, dbg)
      return
    elseif target == zconf.damper then
      local z_damper = extractNumber(raw_val)
      if z_damper then
        debuglog(string.format("Dispatching Zone %d Damper change: %d%%", zid, z_damper), dbg)
        P.ControlZone(guid, zid, nil, z_damper, dbg)
        return
      end
    end
  end

  -- 3. Dispatch Core Climate if matched
  if next(params) ~= nil then
    debuglog("Dispatching event change for " .. tostring(target) .. ": " .. json.encode(params), dbg)
    P.ControlDevice(guid, params, dbg)
  end
end

return P
