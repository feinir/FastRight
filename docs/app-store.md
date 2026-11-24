# Mac App Store build

The App Store build uses separate sandbox entitlements and an App Group for settings and Finder requests. In General settings, grant access to the folders where FastRight should work. The Finder extension monitors those folders, and the app uses security-scoped bookmarks for file operations.

After FastRight creates an item, it selects the item in Finder. Press Return to edit the name. Cut and Paste are available in the context menu. For a name conflict, choose Keep Both, Replace, or Cancel. Finder’s ⌘X integration is available in the Developer ID build.

## Build and sign

`./build-app-store.sh preview` builds an isolated preview with a separate bundle ID and temporary output directory. A Developer ID Application identity is required to test the shared App Group on a Mac. The preview is for local testing.

For distribution, use `make app-store` with these settings:

| Setting | Value |
| --- | --- |
| `FASTRIGHT_STORE_APP_GROUP` | Registered App Group, defaults to `group.com.ynpe.fastright` |
| `FASTRIGHT_STORE_APP_PROFILE` | Mac App Store provisioning profile for `com.ynpe.fastright` |
| `FASTRIGHT_STORE_FINDER_PROFILE` | Mac App Store provisioning profile for `com.ynpe.fastright.findersync` |
| `FASTRIGHT_STORE_SIGN_IDENTITY` | Apple Distribution or Mac App Distribution certificate identity |
| `FASTRIGHT_STORE_INSTALLER_IDENTITY` | Mac Installer Distribution certificate identity |
| `FASTRIGHT_OUTPUT_DIR` | Output directory for the signed package, defaults to `dist` |

Both profiles must authorize the same App Group. The main app requests a Finder-only Apple Events exception so it can change the directory of the current Finder window. Explain that use in App Store Connect’s App Sandbox information when submitting for review.
