--[[
  Panasonic Comfort Cloud Integration Library for LogicMachine (C-Bus)
  File: user.panasonic
  Description: Handles Auth0 token refreshes, dynamic SHA256 HMAC request signing,
               status polling, and AC unit control without requiring user interaction.
--]]

local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")

-- LogicMachine includes md5 / sha256 via 'crypto' or 'sha2'
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

local Panasonic = {}

Panasonic.APP_CLIENT_ID = "X3n9Xyc118pkd73PChweC4w87Wnc1ids"
Panasonic.AUTH0_CLIENT = "eyJuYW1lIjoiQXV0aDAuc3dpZnQiLCJlbnYiOnsiaU9TIjoiMTYuNSJ9LCJ2ZXJzaW9uIjoiMi41LjAifQ=="
Panasonic.AUTH_USER_AGENT = "Panasonic/2.18.0 CFNetwork/1408.0.4 Darwin/22.5.0"
Panasonic.BASE_PATH_AUTH = "https://authglb.digital.panasonic.com"
Panasonic.BASE_PATH_ACC = "https://accsmart.panasonic.com"
Panasonic.APP_VERSION = "1.20.0"

-- Persistent storage key on LogicMachine
Panasonic.STORAGE_KEY = "panasonic_session"

-- Operating Modes
Panasonic.OperationMode = {
  Auto = 0,
  Dry  = 1,
  Cool = 2,
  Heat = 3,
  Fan  = 4
}

-- Fan Speeds
Panasonic.FanSpeed = {
  Auto    = 0,
  Low     = 1,
  LowMid  = 2,
  Mid     = 3,
  HighMid = 4,
  High    = 5
}

-- Eco / Quiet / Powerful Modes
Panasonic.EcoMode = {
  Auto     = 0,
  Powerful = 1,
  Quiet    = 2
}

-- Vertical Air Swing (UD)
Panasonic.AirSwingUD = {
  Auto    = -1,
  Up      = 0,
  UpMid   = 3,
  Mid     = 2,
  DownMid = 4,
  Down    = 1,
  Swing   = 5
}

-- Horizontal Air Swing (LR)
Panasonic.AirSwingLR = {
  Auto     = -1,
  Left     = 1,
  LeftMid  = 5,
  Mid      = 2,
  RightMid = 4,
  Right    = 0
}

--------------------------------------------------------------------------------
-- Internal HTTP Helpers
--------------------------------------------------------------------------------

local function https_post_json(url, payload_table, extra_headers)
  local req_body = json.encode(payload_table)
  local resp_body = {}

  local headers = {
    ["content-type"] = "application/json",
    ["content-length"] = tostring(#req_body),
    ["user-agent"] = "G-RAC"
  }

  if extra_headers then
    for k, v in pairs(extra_headers) do
      headers[k] = v
    end
  end

  local res, code, response_headers, status = https.request{
    url = url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(req_body),
    sink = ltn12.sink.table(resp_body)
  }

  local body_str = table.concat(resp_body)
  local data = nil
  if body_str and #body_str > 0 then
    pcall(function() data = json.pdecode(body_str) or json.decode(body_str) end)
  end

  return code, data, body_str
end

local function https_get_json(url, extra_headers)
  local resp_body = {}
  local headers = {
    ["accept"] = "application/json",
    ["user-agent"] = "G-RAC"
  }

  if extra_headers then
    for k, v in pairs(extra_headers) do
      headers[k] = v
    end
  end

  local res, code, response_headers, status = https.request{
    url = url,
    method = "GET",
    headers = headers,
    sink = ltn12.sink.table(resp_body)
  }

  local body_str = table.concat(resp_body)
  local data = nil
  if body_str and #body_str > 0 then
    pcall(function() data = json.pdecode(body_str) or json.decode(body_str) end)
  end

  return code, data, body_str
end

-- Generate dynamic signature key for Panasonic API requests
local function generate_cfc_api_key(timestamp_ms, access_token)
  local raw_str = "Comfort Cloud" .. "521325fb2dd486bf4831b47644317fca" .. tostring(timestamp_ms) .. "Bearer " .. access_token
  local hex_hash = ""
  
  if sha2 and sha2.sha256hex then
    hex_hash = sha2.sha256hex(raw_str)
  else
    -- Fallback via io.popen if sha2 library missing
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

-- Build standard Comfort Cloud headers
local function get_acc_headers(session, include_client_id)
  local now_sec = os.time()
  local timestamp_str = os.date("!%Y-%m-%d %H:%M:%S", now_sec)
  local timestamp_ms = now_sec * 1000

  local api_key = generate_cfc_api_key(timestamp_ms, session.access_token)

  local headers = {
    ["accept"] = "application/json; charset=utf-8",
    ["content-type"] = "application/json",
    ["user-agent"] = "G-RAC",
    ["x-app-name"] = "Comfort Cloud",
    ["x-app-timestamp"] = timestamp_str,
    ["x-app-type"] = "1",
    ["x-app-version"] = Panasonic.APP_VERSION,
    ["x-cfc-api-key"] = api_key,
    ["x-user-authorization-v2"] = "Bearer " .. session.access_token
  }

  if include_client_id and session.client_id and #session.client_id > 0 then
    headers["x-client-id"] = session.client_id
  end

  return headers
end

--------------------------------------------------------------------------------
-- Public API Methods
--------------------------------------------------------------------------------

-- Refresh access token using refresh token
function Panasonic.refresh_access_token(session)
  if not session or not session.refresh_token then
    log("Panasonic: Missing refresh token")
    return nil, "Missing refresh token"
  end

  local payload = {
    scope = session.scope or "openid offline_access comfortcloud.control a2w.control",
    client_id = Panasonic.APP_CLIENT_ID,
    refresh_token = session.refresh_token,
    grant_type = "refresh_token"
  }

  local extra_headers = {
    ["Auth0-Client"] = Panasonic.AUTH0_CLIENT,
    ["user-agent"] = Panasonic.AUTH_USER_AGENT
  }

  local code, resp = https_post_json(Panasonic.BASE_PATH_AUTH .. "/oauth/token", payload, extra_headers)
  if code ~= 200 or not resp or not resp.access_token then
    log("Panasonic token refresh failed (HTTP " .. tostring(code) .. ")")
    return nil, "Token refresh failed: " .. tostring(code)
  end

  session.access_token = resp.access_token
  if resp.refresh_token then
    session.refresh_token = resp.refresh_token
  end
  session.expires_at = os.time() + (resp.expires_in or 3600)

  -- Fetch fresh ACC client ID
  local login_headers = get_acc_headers(session, false)
  local acc_code, acc_resp = https_post_json(Panasonic.BASE_PATH_ACC .. "/auth/v2/login", { language = 0 }, login_headers)
  if acc_code == 200 and acc_resp and acc_resp.clientId then
    session.client_id = acc_resp.clientId
  end

  storage.set(Panasonic.STORAGE_KEY, session)
  return session
end

-- Retrieve valid session, refreshing if expired
function Panasonic.get_valid_session()
  local session = storage.get(Panasonic.STORAGE_KEY)
  if not session or not session.refresh_token then
    log("Panasonic: No saved session or refresh_token found in storage.")
    return nil, "No credentials in storage"
  end

  local now = os.time()
  if not session.access_token or not session.expires_at or (now >= session.expires_at - 120) or not session.client_id then
    return Panasonic.refresh_access_token(session)
  end

  return session
end

-- Get all registered Panasonic devices
function Panasonic.get_devices()
  local session, err = Panasonic.get_valid_session()
  if not session then return nil, err end

  local headers = get_acc_headers(session, true)
  local code, resp = https_get_json(Panasonic.BASE_PATH_ACC .. "/device/group", headers)

  if code == 401 then
    session = Panasonic.refresh_access_token(session)
    if session then
      headers = get_acc_headers(session, true)
      code, resp = https_get_json(Panasonic.BASE_PATH_ACC .. "/device/group", headers)
    end
  end

  if code == 200 and resp and resp.groupList then
    return resp.groupList
  end
  return nil, "Failed to get devices: HTTP " .. tostring(code)
end

-- Get Live Status for a specific AC unit GUID
function Panasonic.get_device_status(device_guid)
  local session, err = Panasonic.get_valid_session()
  if not session then return nil, err end

  local headers = get_acc_headers(session, true)
  local url = Panasonic.BASE_PATH_ACC .. "/deviceStatus/now/" .. tostring(device_guid)
  local code, resp = https_get_json(url, headers)

  if code == 401 then
    session = Panasonic.refresh_access_token(session)
    if session then
      headers = get_acc_headers(session, true)
      code, resp = https_get_json(url, headers)
    end
  end

  if code == 200 and resp and resp.parameters then
    return resp.parameters
  end
  return nil, "Status request failed: HTTP " .. tostring(code)
end

-- Send control parameters to an AC unit
-- params table example: { operate = 1, temperatureSet = 22.5, operationMode = 2, fanSpeed = 0 }
function Panasonic.control_device(device_guid, params)
  local session, err = Panasonic.get_valid_session()
  if not session then return nil, err end

  local headers = get_acc_headers(session, true)
  local payload = {
    deviceGuid = device_guid,
    parameters = params
  }

  local url = Panasonic.BASE_PATH_ACC .. "/deviceStatus/control"
  local code, resp = https_post_json(url, payload, headers)

  if code == 401 then
    session = Panasonic.refresh_access_token(session)
    if session then
      headers = get_acc_headers(session, true)
      code, resp = https_post_json(url, payload, headers)
    end
  end

  if code == 200 then
    return true
  end
  return false, "Control failed: HTTP " .. tostring(code)
end

return Panasonic
