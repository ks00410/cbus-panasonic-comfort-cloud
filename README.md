# Panasonic Comfort Cloud Integration for C-Bus & LogicMachine (LM5 / SE Wiser / NAC / SHAC)

Integrate **Panasonic Comfort Cloud** air conditioners and heat pumps into Clipsal C-Bus via a **LogicMachine** (Wiser for KNX / NAC / SHAC / LM5) automation controller using Lua.

---

## 🌟 Features
- **Headless & Automated**: Zero user interaction required after initial setup. Automatically refreshes OAuth2 access tokens in the background.
- **Bi-Directional Sync**:
  - **Status Polling**: Reads Power, Indoor/Outdoor Temperatures, Setpoint, Operating Mode, Fan Speed, and Eco Mode into C-Bus Group Objects.
  - **C-Bus Control**: Dispatches changes from C-Bus wall switches, touchscreens, or thermostats directly to the Panasonic Comfort Cloud.
- **Dynamic API Signing**: Implements Panasonic's dynamic HMAC/SHA-256 request signature algorithm natively in Lua.

---

## 📁 Repository Structure

```
cbus-panasonic-comfort-cloud/
├── logicmachine/
│   ├── user_library_panasonic.lua   # User library module (user.panasonic)
│   ├── script_init_storage.lua      # Run-once setup script to store initial credentials
│   ├── script_resident_poll.lua     # Resident polling script (syncs AC -> C-Bus)
│   └── script_event_control.lua     # Event script (syncs C-Bus -> AC)
├── tools/
│   └── generate_tokens.py           # One-time bootstrap script to get refresh_token
├── README.md
└── .gitignore
```

---

## 🚀 Step-by-Step Setup Guide

### 1. Prerequisites (Panasonic App)
1. Open the **Panasonic Comfort Cloud** app on your phone.
2. Ensure **Two-Factor Authentication (2FA)** is turned on with the **SMS** option enabled.
3. *(Recommended)* Create a dedicated Panasonic account for home automation integration.

---

### 2. Generate Initial Tokens (Run Once on PC/Mac)
Since LogicMachine runs headless without a terminal interface for interactive 2FA prompts, use the provided Python bootstrap tool once:

1. Install requirements:
   ```bash
   pip install aio-panasonic-comfort-cloud
   ```
2. Run the token generator:
   ```bash
   python tools/generate_tokens.py
   ```
3. Enter your Panasonic ID (email), password, and the 6-digit SMS code when prompted.
4. The tool will output your:
   - `refresh_token`
   - `access_token`
   - `client_id`
   - Discovered **Device GUID(s)**

---

### 3. LogicMachine Configuration

#### Step A: Create User Library `user.panasonic`
1. Go to **LogicMachine** $\rightarrow$ **Scripting** $\rightarrow$ **User Libraries**.
2. Click **Add New** $\rightarrow$ Name: `panasonic`.
3. Paste the contents of [`logicmachine/user_library_panasonic.lua`](logicmachine/user_library_panasonic.lua).
4. Save.

#### Step B: Initialize Persistent Storage
1. Go to **Scripting** $\rightarrow$ **Scripts** $\rightarrow$ **Add New Script** (Event or Normal script).
2. Paste the contents of [`logicmachine/script_init_storage.lua`](logicmachine/script_init_storage.lua).
3. Replace the placeholder strings with the tokens and client ID generated in Step 2.
4. Click **Run Now / Execute Once** and check the **Logs** tab to verify the connection.

#### Step C: Create C-Bus Group Addresses
Create group addresses in your LogicMachine (e.g. under application `56` Lighting or HVAC):

| Function | C-Bus Group Example | Data Type (DPT) | Description |
| :--- | :--- | :--- | :--- |
| **Power** | `1/1/1` | `01.001 Switch` | `0` = Off, `1` = On |
| **Target Temp** | `1/1/2` | `09.001 2-byte float` | Target setpoint (16.0 – 30.0 °C) |
| **Inside Temp** | `1/1/3` | `09.001 2-byte float` | Current indoor temperature |
| **Outside Temp**| `1/1/4` | `09.001 2-byte float` | Outdoor temperature (if supported) |
| **Mode** | `1/1/5` | `05.010 1-byte uint` | `0`=Auto, `1`=Dry, `2`=Cool, `3`=Heat, `4`=Fan |
| **Fan Speed** | `1/1/6` | `05.010 1-byte uint` | `0`=Auto, `1`=Low, `2`=LowMid, `3`=Mid, `4`=HighMid, `5`=High |
| **Eco Mode** | `1/1/7` | `05.010 1-byte uint` | `0`=Auto, `1`=Powerful, `2`=Quiet |

#### Step D: Create Resident Status Polling Script
1. Go to **Scripting** $\rightarrow$ **Scripts** $\rightarrow$ **Add New Script**.
2. Type: **Resident script** (Sleep interval: `60` seconds).
3. Name: `Panasonic AC - Poll Status`.
4. Paste the contents of [`logicmachine/script_resident_poll.lua`](logicmachine/script_resident_poll.lua).
5. Update `DEVICE_GUID` and `CBUS_OBJECTS` addresses.
6. Enable the script.

#### Step E: Create Event Control Script
1. Go to **Scripting** $\rightarrow$ **Scripts** $\rightarrow$ **Add New Script**.
2. Type: **Event script**.
3. Attach to the C-Bus group objects or tag created in Step C (e.g. `1/1/1`, `1/1/2`, `1/1/5`, `1/1/6`, `1/1/7`).
4. Paste the contents of [`logicmachine/script_event_control.lua`](logicmachine/script_event_control.lua).
5. Update `DEVICE_GUID` and `CBUS_OBJECTS` addresses.
6. Enable the script.

---

## 🔒 Security Note
- Never commit your `refresh_token`, `access_token`, or Panasonic password to public repositories.
- Keep your LogicMachine storage backup secure.
