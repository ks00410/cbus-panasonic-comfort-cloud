import asyncio
import aiohttp
import json
import os
import sys

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


async def main():
    print("=" * 60)
    print("Panasonic Comfort Cloud - One-Time Token Generator")
    print("For C-Bus / LogicMachine Integration")
    print("=" * 60)
    print("Note: Ensure your Panasonic Comfort Cloud account has 2FA enabled")
    print("      with the SMS / OTP option selected in the Panasonic App.\n")

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

        if not refresh_token:
            print("\nError: Failed to obtain a refresh token.")
            return

        print("\nAuthentication successful!")

        # Query discovered devices
        api_client = ApiClient(settings, session, raw=True)
        devices_info = []
        try:
            devices = await api_client.get_devices()
            if devices:
                for d in devices:
                    devices_info.append({
                        "name": d.name,
                        "guid": d.guid,
                        "model": d.model,
                        "group": d.group
                    })
        except Exception as e:
            print(f"Warning: Could not fetch device list: {e}")

        # Output LM config payload
        print("\n" + "=" * 60)
        print("COPY AND PASTE THE FOLLOWING INTO LOGICMACHINE SETUP SCRIPT:")
        print("=" * 60)
        
        lm_storage_payload = {
            "refresh_token": refresh_token,
            "access_token": access_token,
            "client_id": client_id,
            "scope": scope
        }
        
        print("\n--- JSON Payload ---")
        print(json.dumps(lm_storage_payload, indent=2))

        print("\n--- Discovered Panasonic Devices ---")
        if devices_info:
            for idx, dev in enumerate(devices_info, 1):
                print(f"[{idx}] Name: {dev['name']}")
                print(f"    GUID:  {dev['guid']}")
                print(f"    Model: {dev['model']}")
                print(f"    Group: {dev['group']}\n")
        else:
            print("No devices found or discovery skipped. You can check your GUID in the app or group listing.\n")

        print("=" * 60)
        print("Setup complete! Copy the tokens to LogicMachine storage (see README.md).")
        print("=" * 60)


if __name__ == "__main__":
    asyncio.run(main())
