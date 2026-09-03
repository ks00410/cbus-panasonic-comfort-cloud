--[[
================================================================================
  SECRETS CONFIGURATION TEMPLATE (user.secrets)
================================================================================
  Platform:    LogicMachine 5 / SE Wiser / NAC / SHAC (C-Bus)
  Instruction: Create a User Library named 'secrets' in LogicMachine and paste
               your credentials here.
  SECURITY:    NEVER commit your actual secrets.lua to git or share it.
================================================================================
--]]

local s = {}
secrets = s   -- Global registration

s.panasonic = {
  -- Tokens obtained from tools/generate_tokens.py
  refresh_token = "REPLACE_WITH_YOUR_REFRESH_TOKEN",
  access_token  = "REPLACE_WITH_YOUR_ACCESS_TOKEN",
  client_id     = "REPLACE_WITH_YOUR_CLIENT_ID",
  scope         = "openid offline_access comfortcloud.control a2w.control",

  -- Panasonic Device GUID (from Panasonic App or discovery)
  device_guid   = "REPLACE_WITH_YOUR_DEVICE_GUID"
}

return s
