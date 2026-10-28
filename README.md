# Scout

A native macOS clone of Finder, built with AppKit, that adds two things Finder doesn't have:

- **Split view.** Press **⌘S** to show two independent file listings side by side, and press it again to go back to one. The active pane has a thin accent line along its top. **⌥⇥** switches panes, and **F5** / **F6** copy or move the selection to the other pane.
- **SSH servers in the sidebar.** Every host in `~/.ssh/config` (including `Include`d files) appears under **SSH** and in **Network**. Click one to browse it like a disk. Connections go through the system `ssh`, so your keys, the agent, `ProxyJump`, `known_hosts` and so on all work just as they do in Terminal. **⌘K** (Connect to Server) also takes `user@host` or `ssh://user@host:port/path`.

## Finder features

- Icon, List, Column and Gallery views (⌘1–⌘4), remembered per folder
- Sidebar with Favourites (drag folders in, drag them out to remove), Locations, SSH hosts and Tags
- Back/forward history, enclosing folder (⌘↑), Go menu shortcuts
- Sortable list columns with disclosure triangles (choose columns by right-clicking the header)
- Rename (Return), New Folder (⇧⌘N), Duplicate (⌘D), Make Alias, Compress, Move to Bin (⌘⌫) with undo
- Copy/paste files (⌘C / ⌘V / ⌥⌘V to move), and drag and drop between panes, windows and other apps
- Quick Look (Space), Get Info (⌘I), Open With, Share, Tags, Copy as Pathname, Open in Terminal
- Tabs (⌘T), path bar (⌥⌘P), status bar (⌘/), hidden files (⇧⌘.)
- Light and dark mode, using the system's own controls and Finder's symbols

## Search

Search (⌘F) works like Finder's and uses Spotlight, with results arriving as they're found and updating live. A scope bar under the toolbar chooses where to look: **This Mac**, the **disk** the folder is on, or the **current folder**. On the right you choose between **Name & Contents** (Finder's default, matching words in names, contents and metadata) and **Name Only**. Which scope a new search starts with follows the "When performing a search" setting in Scout › Settings, initialised from Finder's.

In an SSH folder, the scopes are the **server** and the **current folder**. Scout runs `find` (names) and `grep` (contents) on the server, limited to 30 seconds and 3,000 results.

## Go to Folder

**⌘L** (or Finder's ⇧⌘G) opens Go to Folder over the window, at a fixed spot that doesn't move as matches come and go, with the current folder's absolute path selected, like a browser's address bar. Type to replace it, or press → to keep it and continue typing. It behaves like a shell:

- Paths can be absolute, relative to the current folder, or use `~`, `..`, `$HOME`-style variables, `-` (the previous folder) or `host:/path` for an SSH host. In a remote folder, paths resolve on the server.
- Names complete inline as you type. **→**, **Tab** or **/** accepts the completion, and **Esc** dismisses it.
- **Tab** completes the part all matches share, then cycles through the matches (**⇧Tab** goes back). **↑/↓** choose a match and **Return** goes there.
- **⌥⌫** or **⌃W** deletes the last path component, and **⌃U** clears the field.
- Pasted paths with quotes, backslash escapes or `file://` are cleaned up. A path to a file opens its folder and selects the file.

## SSH details

- Listing, creating folders, renaming, duplicating and deleting all run on the server. Remote deletes are permanent, and Scout asks before deleting.
- Copying between the Mac and a server, or between two servers, streams `tar` over SSH, so folders, permissions and odd file names come through intact.
- Opening or Quick Looking a remote file downloads it to `~/Library/Caches/io.matej.Scout/Remote`. Dragging a remote file to the Desktop or into another app downloads it there.
- Each host keeps one multiplexed connection (`ControlMaster`). Use the eject button in the sidebar to disconnect.
- Passphrases, passwords and host-key confirmations appear as native dialogs through a small `SSH_ASKPASS` helper.

## Install

Download the latest `Scout-<version>-arm64.dmg` from [Releases](https://github.com/matej-io/scout/releases), open it and drag Scout to Applications. Builds are for Apple silicon, need macOS 15 or later, and are signed with Developer ID and notarized by Apple.

## Releasing

```sh
scripts/release.sh 1.0.1            # archive (arm64), sign with Developer ID, notarize, build the DMG
scripts/release.sh 1.0.1 --publish  # …and create the GitHub release with the DMG attached
```

Signing and notarization use the Xcode account for the ZEN PLUS LTD team (automatic signing with `-allowProvisioningUpdates`). On CI, set `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` to use an App Store Connect API key instead. The output goes to `build/release/`.

## Building

Open `Scout.xcodeproj` in Xcode 26 or later and run, or build from the command line:

```sh
xcodebuild -project Scout.xcodeproj -scheme Scout -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Scout.app
```

The app isn't sandboxed, because it needs `~/.ssh` and `/usr/bin/ssh`. On first launch, before it opens a window, Scout offers to set up Full Disk Access, which lets it browse protected folders such as the Bin and stops macOS asking separately about Desktop, Documents, Downloads and each external disk. You can set it up later in Scout › Settings.

The app icon is `Scout/AppIcon.icon` (Icon Composer format), generated by `swift design/icons/make-app-icon.swift Scout/AppIcon.icon`.

## Development helpers

- `SCOUT_SELFTEST=<ssh-host>` runs file operations end to end, locally and over SSH, in temporary folders, then quits.
- `SCOUT_SNAPSHOT=/tmp/out.png` renders the window to a PNG. You can combine it with `SCOUT_START`, `SCOUT_VIEW`, `SCOUT_SPLIT=1`, `SCOUT_APPEARANCE=dark|light` and `SCOUT_SNAPSHOT_QUIT=1`. With `SCOUT_FDA=1` it renders the Full Disk Access window instead.
