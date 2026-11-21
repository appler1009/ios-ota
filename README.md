# ios-ota

Install your own iOS apps on your own iPhone over the air, through Tailscale. Build on the Mac, then tap **Install** on the phone from anywhere on your tailnet. No cable, no Xcode connection, no TestFlight.

One server covers every project. Each app gets its own install page, and a page at the root lists all of them.

## Requirements

- A Mac with Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the menu bar app (and for projects that use a `project.yml`).
- A paid Apple developer account. The iPhone must be registered to your team, as it already is if you have run apps on it from Xcode.
- Tailscale on the Mac and the iPhone, with HTTPS certificates enabled for the tailnet.

## Setup

```sh
./ios-ota setup
```

This does three things:

- Builds the menu bar app **iOS OTA** and installs it in `~/Applications`. The app is the web server, and it starts at login.
- Shares the server on your tailnet at port 8444.
- Links the `ios-ota` command into `~/.local/bin`.

## Publish a build

From a project folder:

```sh
ios-ota publish                                   # the one project and scheme here
ios-ota publish --scheme MyApp                    # pick a scheme
ios-ota publish --scheme MyApp -- CURRENT_PROJECT_VERSION=42   # pass build settings to xcodebuild
ios-ota publish --ipa path/to/App.ipa             # an app file built some other way
```

`publish` does the following:

- Builds a fresh archive of what is checked out, uncommitted changes included. It never fetches or pulls.
- Exports the archive signed for development.
- Publishes it and prints the install page, with a QR code.
- Works out the app's name, bundle id, version and icon from the build, and the signing team from Xcode's build settings.

`ios-ota status` shows the server and what is published. `ios-ota uninstall` removes the app and the tailnet share; published builds stay on disk.

## On the iPhone

With Tailscale on, open `https://<mac>.<tailnet>.ts.net:8444/` in Safari. Pick an app and tap **Install**. Each app's page always offers its newest build, so a bookmark or Home Screen icon per app is enough.

## How it works

- **Where builds go:** `~/Library/Application Support/iOS-OTA/<app key>/<random id>/`. The app key is the first 12 hex digits of the SHA-256 of the bundle id, so no address shows it.
- **What each build holds:** `App.ipa`, the `manifest.plist` iOS installs from (it carries the bundle id, as iOS requires), the app's icon, and `build.json` with its details. The server does not hand out `build.json`.
- **How many are kept:** the newest five builds per app.
- **The pages:** `pages.py` writes them from the `build.json` files. There is one page per app, with the Install button and a details table, and the list of apps is sorted by when each app's code last changed.
- **The menu bar app (`MenuBar/`):**
  - Serves the builds folder on 127.0.0.1:8445. The Mac App Store Tailscale cannot serve a folder itself, so `tailscale serve` passes it on over HTTPS at 8444, to the tailnet only.
  - Watches for new builds and notifies.
  - Lists every app's builds, with install links, QR codes, Finder, and delete.
- **When installs stop:** installs work only while the menu bar app runs. `ios-ota publish` starts it if it is not running.
- **Build leftovers:** builds leave nothing behind on the Mac. Xcode's intermediate files go in a temporary folder that is deleted afterwards. Downloaded Swift packages are cached per project in `~/Library/Caches/ios-ota/packages/`.

## Limits

- **Registered devices only:** only devices registered to your team can install. This is for your own devices, not distribution.
- **Expiry:** development signing expires (typically after a year). Publish again for a fresh profile.
- **iOS only:** macOS apps would need Developer ID signing and notarization, and a download instead of an install.
