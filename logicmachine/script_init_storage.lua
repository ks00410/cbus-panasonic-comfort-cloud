--[[
  LogicMachine Setup Script (Run Once)
  Script Type: Scripting -> Scripts -> Add New Script (Execute Once)
  Description: Saves the initial Refresh Token and Auth credentials into LM persistent storage.
--]]

local panasonic = require("user.panasonic")

-- 1. Paste your tokens obtained from the python bootstrap script here:
local initial_credentials = {
  refresh_token = "PASTE_YOUR_REFRESH_TOKEN_HERE",
  access_token  = "PASTE_YOUR_ACCESS_TOKEN_HERE",
  client_id     = "PASTE_YOUR_CLIENT_ID_HERE",
  scope         = "openid offline_access comfortcloud.control a2w.control"
}

-- 2. Save credentials to LM storage
storage.set(panasonic.STORAGE_KEY, initial_credentials)
log("Panasonic initial credentials saved to storage.")

-- 3. Test token validity & connection
local session, err = panasonic.get_valid_session()
if session then
  log("Panasonic session validated successfully! Client ID: " .. tostring(session.client_id))
  
  -- Query devices to verify communication
  local groups = panasonic.get_devices()
  if groups then
    log("Discovered Panasonic Device Groups:")
    log(groups)
  end
else
  log("Panasonic initialization failed: " .. tostring(err))
end
