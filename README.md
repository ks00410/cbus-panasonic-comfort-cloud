# Panasonic Comfort Cloud Integration for C-Bus & LogicMachine (LM5 / SE Wiser / NAC / SHAC)

Integrate **Panasonic Comfort Cloud** air conditioners and heat pumps into Clipsal C-Bus via a **LogicMachine** (Wiser for KNX / NAC / SHAC / LM5) automation controller using Lua.

---

## 🌟 Features
- **Strict Secrets Isolation**: All credentials, tokens, and device GUIDs live in a local `user.secrets` module (`secrets.lua`), keeping integration code completely clean of private data.
- **Headless & Automated**: Zero user interaction required after initial setup. Automatically refreshes OAuth2 access tokens in the background.
- **Bi-Directional Sync**:
  - **Status Polling**: Reads Power, Indoor/Outdoor Temperatures, Setpoint, Operating Mode, Fan Speed, and Eco Mode into C-Bus Group Objects.
  - **C-Bus Control**: Dispatches changes from C-Bus wall switches, touchscreens, or thermostats directly to the Panasonic Comfort Cloud.
- **Dynamic API Signing**: Implements Panasonic's dynamic HMAC/SHA-256 request signature algorithm natively in Lua.
- **Safe C-Bus I/O**: Error-suppressed parameter and group writes wrapped in `pcall` with missing parameter alerts to prevent script crashes.

---

## 📁 Repository Structure

```
cbus-panasonic-comfort-cloud/
├── logicmachine/
│   ├── user_library_panasonic.lua   # Core driver module (user.panasonic)
│   ├── secrets.example.lua          # Template for user.secrets module (DO NOT COMMIT SECRETS)
│   ├── script_resident_poll.lua     # Resident polling script (syncs AC -> C-Bus)
│   └── script_event_control.lua     # Event script (syncs C-Bus -> AC)
├── tools/
│   └── generate_tokens.py           # One-time bootstrap CLI tool to get refresh_token
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

#### Step A: Create User Library `user.secrets`
1. Go to **LogicMachine** $\rightarrow$ **Scripting** $\rightarrow$ **User Libraries**.
2. Click **Add New** $\rightarrow$ Name: `secrets`.
3. Copy [`logicmachine/secrets.example.lua`](logicmachine/secrets.example.lua) and replace the placeholders with your generated tokens and device GUID.
4. Save.

#### Step B: Create User Library `user.panasonic`
1. Go to **LogicMachine** $\rightarrow$ **Scripting** $\rightarrow$ **User Libraries**.
2. Click **Add New** $\rightarrow$ Name: `panasonic`.
3. Paste the contents of [`logicmachine/user_library_panasonic.lua`](logicmachine/user_library_panasonic.lua).
4. Save.

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

*(Optional)* Create a C-Bus UserParam named `Panasonic_Debug` (Boolean) to toggle detailed logs on/off directly from C-Bus.

#### Step D: Create Resident Status Polling Script
1. Go to **Scripting** $\rightarrow$ **Scripts** $\rightarrow$ **Add New Script**.
2. Type: **Resident script** (Sleep interval: `60` seconds).
3. Name: `Panasonic AC - Poll Status`.
4. Paste the contents of [`logicmachine/script_resident_poll.lua`](logicmachine/script_resident_poll.lua).
5. Enable the script.

#### Step E: Create Event Control Script
1. Go to **Scripting** $\rightarrow$ **Scripts** $\rightarrow$ **Add New Script**.
2. Type: **Event script**.
3. Attach to the C-Bus group objects created in Step C (e.g. `1/1/1`, `1/1/2`, `1/1/5`, `1/1/6`, `1/1/7`).
4. Paste the contents of [`logicmachine/script_event_control.lua`](logicmachine/script_event_control.lua).
5. Enable the script.

---

## 🔒 Security Note
- The `secrets.lua` user library remains strictly on your local LogicMachine device.
- Never commit active tokens, passwords, or personal account identifiers to GitHub.
