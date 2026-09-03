# Panasonic Comfort Cloud Integration for C-Bus & LogicMachine (LM5 / SE Wiser / NAC / SHAC)

Integrate **Panasonic Comfort Cloud** air conditioners and heat pumps into Clipsal C-Bus via a **LogicMachine** (Wiser for KNX / NAC / SHAC / LM5) automation controller using Lua.

---

## 🌟 Features
- **Strict Secrets Isolation**: All credentials, tokens, and device GUIDs live in a local `user.secrets` module (`secrets.lua`), keeping integration code completely clean of private data.
- **Headless & Automated**: Zero user interaction required after initial setup. Automatically refreshes OAuth2 access tokens in the background.
- **Full Climate & Zone Damper Control**:
  - **Core Climate**: Power, Setpoint (16–30°C), Operating Mode (Auto/Cool/Heat/Dry/Fan), Fan Speeds (Auto/1–5), Preset (Quiet/Powerful).
  - **Zone Controls**: Multi-zone Damper aperture (0–100%), individual Zone On/Off, and Zone Room Temperatures.
  - **Advanced Features**: Horizontal/Vertical Louvres (AirSwing), Nanoe Air Purification, EcoNavi, iAuto-X, and Inside Clean.
- **Energy & Power Telemetry**: Today's Total Energy (kWh), Heating/Cooling Breakdown (kWh), and Real-Time Extrapolated Power (Watts).
- **Dynamic API Signing & Version Fallback**: Native HMAC/SHA-256 signature generator and automated error 4106 app version rotation.
- **Safe C-Bus I/O**: Error-suppressed parameter and group writes wrapped in `pcall` with missing parameter alerts to prevent script crashes.

---

## 📁 Repository Structure

```
cbus-panasonic-comfort-cloud/
├── cbus/
│   ├── user_library_panasonic.lua   # Core driver module (user.panasonic)
│   ├── secrets.example.lua          # Template for user.secrets module (DO NOT COMMIT SECRETS)
│   ├── script_resident_poll.lua     # Resident polling script (syncs AC + Zones + Energy -> C-Bus)
│   └── script_event_control.lua     # Event script (syncs C-Bus -> AC & Zones)
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
3. Copy [`cbus/secrets.example.lua`](cbus/secrets.example.lua) and replace the placeholders with your generated tokens and device GUID.
4. Save.

#### Step B: Create User Library `user.panasonic`
1. Go to **LogicMachine** $\rightarrow$ **Scripting** $\rightarrow$ **User Libraries**.
2. Click **Add New** $\rightarrow$ Name: `panasonic`.
3. Paste the contents of [`cbus/user_library_panasonic.lua`](cbus/user_library_panasonic.lua).
4. Save.

#### Step C: Create C-Bus User Parameters in LogicMachine / C-Bus
Create the **User Parameters** you wish to use in your C-Bus project (under C-Bus Network 0). The script matches them by name (prefixed by `AC_`). You do not need to create all of them—only create the parameters you want to monitor or display on touchscreens:

> **Note on Dynamic Zones & Parameter Creation:**
> - C-Bus User Parameters **cannot** be created automatically at runtime; they must be added to your C-Bus project / LogicMachine before values will populate.
> - The integration is **fully dynamic**: it handles systems with **0 zones** (single-split), **2 zones**, **3 zones**, **4 zones**, **8 zones**, or any other count returned by the Panasonic API.
> - For multi-zone systems, create parameters following the `AC_Zone<N>_Power`, `AC_Zone<N>_Damper`, and `AC_Zone<N>_Temp` naming scheme for each zone number present on your AC.
> - Any parameter that is not created in C-Bus is safely and silently ignored without raising errors.

##### 1. Core Climate UserParams
| UserParam Name | Data Type | Description |
| :--- | :--- | :--- |
| `AC_Power` | Integer / Boolean | `0` = Off, `1` = On |
| `AC_TargetTemp` | Float (°C) | Target setpoint (16.0 – 30.0 °C) |
| `AC_InsideTemp` | Float (°C) | Current indoor room temperature |
| `AC_OutsideTemp`| Float (°C) | Outdoor ambient temperature |
| `AC_Mode` | Integer | `0`=Auto, `1`=Dry, `2`=Cool, `3`=Heat, `4`=Fan |
| `AC_Mode_Text` | String | `"Auto"`, `"Dry"`, `"Cool"`, `"Heat"`, `"Fan"` |
| `AC_HVACAction` | Integer | `0`=Off, `1`=Idle, `2`=Heating, `3`=Cooling, `4`=Drying, `5`=Fan |
| `AC_HVACAction_Text` | String | `"Off"`, `"Idle"`, `"Heating"`, `"Cooling"`, `"Drying"`, `"Fan Only"` |
| `AC_FanSpeed` | Integer | `0`=Auto, `1`=Low, `2`=LowMid, `3`=Mid, `4`=HighMid, `5`=High |
| `AC_FanSpeed_Text` | String | `"Auto"`, `"Low"`, `"Mid"`, `"High"`, etc. |
| `AC_EcoMode` | Integer | `0`=Auto, `1`=Powerful, `2`=Quiet |
| `AC_SwingUD` | Integer | `-1`=Auto, `0`=Up, `1`=Down, `2`=Mid, `5`=Swing |
| `AC_SwingLR` | Integer | `-1`=Auto, `0`=Right, `1`=Left, `2`=Mid |
| `AC_Nanoe` | Integer | `0`=Off, `2`=On, `3`=ModeG, `4`=All |
| `AC_ActiveZones`| Integer | Count of currently open zones (e.g. `0`..`N`) |
| `AC_LastUpdated`| String | Timestamp formatted as `"DD Mon YYYY, HH:MM"` |

##### 2. Zone Damper UserParams (Dynamic Naming: Zone 1 to N)
| UserParam Name | Data Type | Description |
| :--- | :--- | :--- |
| `AC_Zone1_Power` | Integer | Zone 1 Damper Open (`1`) / Closed (`0`) |
| `AC_Zone1_Damper`| Integer (%) | Zone 1 Damper aperture (`0` – `100%`) |
| `AC_Zone1_Temp` | Float (°C) | Zone 1 Room Temp (if sensor installed) |
| `AC_Zone2_Power` | Integer | Zone 2 Damper Open (`1`) / Closed (`0`) |
| `AC_Zone2_Damper`| Integer (%) | Zone 2 Damper aperture (`0` – `100%`) |
| `AC_Zone2_Temp` | Float (°C) | Zone 2 Room Temp (if sensor installed) |
| `AC_Zone3_Power` | Integer | Zone 3 Damper Open (`1`) / Closed (`0`) |
| `AC_Zone3_Damper`| Integer (%) | Zone 3 Damper aperture (`0` – `100%`) |
| `AC_Zone3_Temp` | Float (°C) | Zone 3 Room Temp (if sensor installed) |
| `AC_Zone<N>_Power` | Integer | Zone *N* Damper Open (`1`) / Closed (`0`) (for 4+ zones) |
| `AC_Zone<N>_Damper`| Integer (%) | Zone *N* Damper aperture (`0` – `100%`) (for 4+ zones) |
| `AC_Zone<N>_Temp` | Float (°C) | Zone *N* Room Temp (if sensor installed) |

##### 3. Energy & Power Monitoring UserParams
| UserParam Name | Data Type | Description |
| :--- | :--- | :--- |
| `AC_Daily_kWh` | Float (kWh) | Total daily energy consumption (kWh) |
| `AC_Heating_kWh` | Float (kWh) | Today's heating energy (kWh) |
| `AC_Cooling_kWh` | Float (kWh) | Today's cooling energy (kWh) |
| `AC_CurrentPower_W` | Integer (Watts) | Instantaneous extrapolated power (Watts) |

*(Optional)* Create a C-Bus UserParam named `Debug` (Boolean: `true`/`false` or `1`/`0`) to toggle detailed logs on/off directly from C-Bus, matching the Ecowitt integration convention.
*(Optional)* You can also map native C-Bus group addresses (integers 0..255 on App 56) in `cbus_objects` if you want physical C-Bus buttons to track status.

#### Step D: Create Resident Status Polling Script
1. Go to **Scripting** $\rightarrow$ **Scripts** $\rightarrow$ **Add New Script**.
2. Type: **Resident script** (Sleep interval: `60` seconds).
3. Name: `Panasonic AC - Poll Status`.
4. Paste the contents of [`cbus/script_resident_poll.lua`](cbus/script_resident_poll.lua).
5. Enable the script.

#### Step E: Create Event Control Script
1. Go to **Scripting** $\rightarrow$ **Scripts** $\rightarrow$ **Add New Script**.
2. Type: **Event script**.
3. Attach to the C-Bus group objects created in Step C.
4. Paste the contents of [`cbus/script_event_control.lua`](cbus/script_event_control.lua).
5. Enable the script.

---

## 🔒 Security Note
- The `secrets.lua` user library remains strictly on your local LogicMachine device.
- Never commit active tokens, passwords, or personal account identifiers to GitHub.
