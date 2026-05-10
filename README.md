# CodicLens

## Building & Running

### Development

Open `codiclens.xcodeproj` in Xcode and run with `Cmd+R`.

### Release Build

1. Open `codiclens.xcodeproj` in Xcode
2. Set destination to **Any Mac** (top toolbar)
3. **Product → Archive**
4. Organizer opens when build completes

## Signing & Notarizing for Distribution

### Prerequisites

- Apple Developer account
- App-specific password (generate at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords)
- Team ID (find at [developer.apple.com/account](https://developer.apple.com/account) → Membership Details)

### 1. Configure Signing in Xcode

1. Select project in navigator → **Signing & Capabilities** tab
2. Check **Automatically manage signing**
3. Select your **Team** (Apple Developer account)
4. Signing certificate should be **Developer ID Application**
5. Enable **Hardened Runtime** (+ Capability → Hardened Runtime)

### 2. Archive

1. Set destination to **Any Mac**
2. **Product → Archive**
3. Wait for build to complete — Organizer opens automatically

### 3. Export Signed App

1. In Organizer, select the archive → **Distribute App**
2. Choose **Direct Distribution**
3. Choose **Export**
4. Xcode signs with Developer ID automatically
5. Pick an export folder

### 4. Notarize

If Xcode didn't auto-notarize during export, use the command line:

```bash
# Store credentials (one-time setup)
xcrun notarytool store-credentials "codiclens-profile" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"

# Zip the app
ditto -c -k --keepParent path/to/codiclens.app codiclens.zip

# Submit for notarization
xcrun notarytool submit codiclens.zip \
  --keychain-profile "codiclens-profile" \
  --wait

# Staple the notarization ticket to the app
xcrun stapler staple path/to/codiclens.app
```

### 5. Package as DMG (Optional)

```bash
hdiutil create -volname "CodicLens" \
  -srcfolder path/to/codiclens.app \
  -ov -format UDZO codiclens.dmg

xcrun stapler staple codiclens.dmg
```

### 6. Distribute

After stapling, the `.app` or `.dmg` can be shared and will pass Gatekeeper on any Mac.
