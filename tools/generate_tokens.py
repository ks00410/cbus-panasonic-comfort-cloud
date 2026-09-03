import asyncio
import aiohttp
import json
import os
import sys
import datetime
import hashlib
import time

# Ensure requirements
try:
    from aio_panasonic_comfort_cloud.panasonicsettings import PanasonicSettings
    from aio_panasonic_comfort_cloud.ccappversion import CCAppVersion
    from aio_panasonic_comfort_cloud.panasonicauthentication import PanasonicAuthentication
    from aio_panasonic_comfort_cloud.apiclient import ApiClient
    from aio_panasonic_comfort_cloud.exceptions import MFARequiredError
except ImportError:
    print("Error: Required dependency 'aio-panasonic-comfort-cloud' not found.")
    print("Please install it first by running:")
    print("    pip install aio-panasonic-comfort-cloud")
    sys.exit(1)


def generate_cfc_api_key(timestamp: str, access_token: str) -> str:
    date = datetime.datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S")
    timestamp_ms = str(int(date.replace(tzinfo=datetime.timezone.utc).timestamp() * 1000))
    components = [
        "Comfort Cloud".encode("utf-8"),
        "521325fb2dd486bf4831b47644317fca".encode("utf-8"),
        timestamp_ms.encode("utf-8"),
        "Bearer ".encode("utf-8"),
        access_token.encode("utf-8")
    ]
    input_buffer = b"".join(components)
    hex_hash = hashlib.sha256(input_buffer).hexdigest()
    return hex_hash[:9] + "cfc" + hex_hash[9:]


async def test_live_api_endpoints(session: aiohttp.ClientSession, settings: PanasonicSettings, app_version: str, device_guid: str):
    print("\n" + "=" * 60)
    print("TESTING LIVE PANASONIC API ENDPOINTS (AS EXECUTED BY LUA)")
    print("=" * 60)

    now = datetime.datetime.now()
    timestamp_str = now.strftime("%Y-%m-%d %H:%M:%S")
    api_key = generate_cfc_api_key(timestamp_str, settings.access_token)

    headers = {
        "accept": "application/json; charset=utf-8",
        "content-type": "application/json",
        "user-agent": "G-RAC",
        "x-app-name": "Comfort Cloud",
        "x-app-timestamp": timestamp_str,
        "x-app-type": "1",
        "x-app-version": app_version,
        "x-cfc-api-key": api_key,
        "x-user-authorization-v2": f"Bearer {settings.access_token}",
        "x-client-id": settings.clientId or ""
    }

    # 1. Test Device Status Endpoint
    status_url = f"https://accsmart.panasonic.com/deviceStatus/now/{device_guid}"
    print(f"\n1. GET {status_url} ...")
    try:
        async with session.get(status_url, headers=headers) as resp:
            print(f"   Response HTTP Status: {resp.status}")
            status_data = await resp.json()
            params = status_data.get("parameters", {})
            print("   --- Parsed Status Telemetry ---")
            print(f"   Power:        {'ON' if params.get('operate') == 1 else 'OFF'}")
            print(f"   Target Temp:  {params.get('temperatureSet')} °C")
            print(f"   Inside Temp:  {params.get('insideTemperature')} °C")
            print(f"   Outside Temp: {params.get('outTemperature')} °C")
            print(f"   Mode:         {params.get('operationMode')}")
            print(f"   Fan Speed:    {params.get('fanSpeed')}")
            print(f"   Eco Mode:     {params.get('ecoMode')}")
            print(f"   Nanoe:        {params.get('nanoe')}")
            if "zoneParameters" in params:
                print(f"   Zones Found:  {len(params['zoneParameters'])}")
                for z in params["zoneParameters"]:
                    print(f"     * Zone {z.get('zoneId')} ({z.get('zoneName')}): OnOff={z.get('zoneOnOff')}, Level={z.get('zoneLevel')}%, Temp={z.get('zoneTemperature')}")
    except Exception as e:
        print(f"   Status request failed: {e}")

    # 2. Test History / Energy Data Endpoint
    today_str = datetime.datetime.now().strftime("%Y%m%d")
    energy_url = "https://accsmart.panasonic.com/deviceHistoryData"
    energy_payload = {
        "deviceGuid": device_guid,
        "dataMode": 2,
        "date": today_str,
        "osTimezone": "+10:00"
    }
    print(f"\n2. POST {energy_url} (Energy Telemetry) ...")
    try:
        async with session.post(energy_url, headers=headers, json=energy_payload) as resp:
            print(f"   Response HTTP Status: {resp.status}")
            energy_data = await resp.json()
            items = energy_data.get("historyDataList", [])
            for item in items:
                if item.get("dataTime") == today_str:
                    print("   --- Today's Energy Readings ---")
                    print(f"   Total Daily Consumption: {item.get('consumption')} kWh")
                    print(f"   Heating Consumption:     {item.get('heatConsumptionRate')} kWh")
                    print(f"   Cooling Consumption:     {item.get('coolConsumptionRate')} kWh")
                    break
    except Exception as e:
        print(f"   Energy request failed: {e}")

    print("\n" + "=" * 60)
    print("LIVE API ENDPOINT TEST COMPLETE")
    print("=" * 60)


async def main():
    print("=" * 60)
    print("Panasonic Comfort Cloud - Token Generator & API Tester")
    print("For C-Bus / LogicMachine Integration")
    print("=" * 60)
    print("Note: Ensure your Panasonic account has 2FA enabled (SMS option).\n")

    username = input("Panasonic ID (Email): ").strip()
    password = input("Panasonic Password: ").strip()

    if not username or not password:
        print("Error: Username and password cannot be empty.")
        return

    settings_file = "/tmp/panasonic_bootstrap_settings.json"
    if os.path.exists(settings_file):
        os.remove(settings_file)

    settings = PanasonicSettings(settings_file)
    await settings.is_ready()

    async with aiohttp.ClientSession() as session:
        app_ver = CCAppVersion(session, settings)
        auth = PanasonicAuthentication(session, settings, app_ver)

        try:
            print("\nAuthenticating with Panasonic Comfort Cloud...")
            await auth.authenticate(username, password)
        except MFARequiredError:
            otp = input("\n2FA Required! Enter the 6-digit SMS / OTP verification code: ").strip()
            await auth.verify_mfa(otp)
        except Exception as e:
            print(f"\nAuthentication failed: {e}")
            return

        refresh_token = settings.refresh_token
        access_token = settings.access_token
        client_id = settings.clientId
        scope = settings.scope or "openid offline_access comfortcloud.control a2w.control"
        app_ver_str = await app_ver.get() or "4.4.0"

        if not refresh_token:
            print("\nError: Failed to obtain a refresh token.")
            return

        print("\nAuthentication successful!")

        # Build helper for signed requests
        def get_auth_headers():
            now = datetime.datetime.now()
            timestamp_str = now.strftime("%Y-%m-%d %H:%M:%S")
            api_key = generate_cfc_api_key(timestamp_str, settings.access_token)
            headers = {
                "accept": "application/json; charset=utf-8",
                "content-type": "application/json",
                "user-agent": "G-RAC",
                "x-app-name": "Comfort Cloud",
                "x-app-timestamp": timestamp_str,
                "x-app-type": "1",
                "x-app-version": app_ver_str,
                "x-cfc-api-key": api_key,
                "x-user-authorization-v2": f"Bearer {settings.access_token}"
            }
            if settings.clientId:
                headers["x-client-id"] = settings.clientId
            return headers

        # Handle 412/41201 Terms & Agreements acceptance automatically
        async def auto_accept_agreements():
            try:
                headers = get_auth_headers()
                # 1. Fetch latest agreement documents
                doc_url = "https://accsmart.panasonic.com/auth/v2/agreement/documents?language=0"
                async with session.get(doc_url, headers=headers) as resp:
                    if resp.status != 200:
                        return
                    docs_resp = await resp.json()
                    documents = docs_resp.get("agreementList", [])

                # 2. Fetch currently accepted agreements
                status_url = "https://accsmart.panasonic.com/auth/v2/agreement/status"
                async with session.get(status_url, headers=headers) as resp:
                    if resp.status != 200:
                        return
                    status_resp = await resp.json()
                    accepted = status_resp.get("agreementList", [])

                accepted_versions = {item.get("type"): item.get("version") for item in accepted}
                auto_accept_types = {1, 2, 4} # 1: Terms, 2: Privacy, 4: Cookie Policy

                to_accept = []
                for doc in documents:
                    try:
                        dtype = int(doc.get("type"))
                    except (TypeError, ValueError):
                        continue
                    if dtype in auto_accept_types:
                        latest_ver = doc.get("version")
                        if latest_ver and accepted_versions.get(dtype) != latest_ver:
                            to_accept.append({"type": dtype, "version": latest_ver})

                if to_accept:
                    print(f"\nAuto-accepting updated Panasonic Terms & Privacy Agreements: {to_accept} ...")
                    async with session.put(status_url, headers=get_auth_headers(), json={"agreementList": to_accept}) as put_resp:
                        if put_resp.status == 200:
                            print("Agreements accepted successfully!")
            except Exception as e:
                print(f"Agreement auto-acceptance note: {e}")

        # Check agreements
        await auto_accept_agreements()

        # Query discovered devices using direct API headers
        devices_info = []
        try:
            headers = get_auth_headers()
            async with session.get("https://accsmart.panasonic.com/device/group", headers=headers) as resp:
                if resp.status == 412:
                    # Retry once after explicit agreement acceptance
                    await auto_accept_agreements()
                    async with session.get("https://accsmart.panasonic.com/device/group", headers=get_auth_headers()) as retry_resp:
                        resp = retry_resp

                if resp.status == 200:
                    group_data = await resp.json()
                    for group in group_data.get("groupList", []):
                        gname = group.get("groupName", "Default Group")
                        dev_list = group.get("deviceList", []) or group.get("deviceIdList", [])
                        for d in dev_list:
                            if d and isinstance(d, dict) and "deviceGuid" in d:
                                devices_info.append({
                                    "name": d.get("deviceName", "Panasonic AC"),
                                    "guid": d.get("deviceGuid"),
                                    "model": d.get("deviceModuleNumber", ""),
                                    "group": gname
                                })
                else:
                    err_body = await resp.text()
                    print(f"Warning: Device discovery returned HTTP {resp.status}: {err_body}")
        except Exception as e:
            print(f"Warning: Could not fetch device list: {e}")

        # Display discovered devices
        selected_guid = ""
        if devices_info:
            print("\n--- Discovered Panasonic Devices ---")
            for idx, dev in enumerate(devices_info, 1):
                print(f"[{idx}] Name: {dev['name']} | Model: {dev['model']} | GUID: {dev['guid']}")
            selected_guid = devices_info[0]["guid"]
        else:
            selected_guid = input("\nEnter your Panasonic Device GUID: ").strip()

        # Output template for secrets.lua
        print("\n" + "=" * 60)
        print("COPY AND PASTE THIS INTO YOUR LOGICMACHINE 'secrets' USER LIBRARY:")
        print("=" * 60)

        secrets_lua_content = f"""local s = {{}}
secrets = s   -- Global registration

s.panasonic = {{
  refresh_token = "{refresh_token}",
  access_token  = "{access_token}",
  client_id     = "{client_id}",
  scope         = "{scope}",
  device_guid   = "{selected_guid}"
}}

return s"""
        print(secrets_lua_content)

        # Run live API test
        if selected_guid:
            await test_live_api_endpoints(session, settings, app_ver_str, selected_guid)


if __name__ == "__main__":
    asyncio.run(main())
