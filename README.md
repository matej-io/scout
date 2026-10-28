# Scout

A native macOS clone of Finder, built with AppKit, that adds two things Finder doesn't have:

- **Split view.** Press **⌘S** to show two independent file listings side by side, and press it again to go back to one. The active pane has a thin accent line along its top. **⌥⇥** switches panes, and **F5** / **F6** copy or move the selection to the other pane.
- **SSH servers in the sidebar.** Every host in `~/.ssh/config` (including `Include`d files) appears under **SSH** and in **Network**. Click one to browse it like a disk. Connections go through the system `ssh`, so your keys, the agent, `ProxyJump`, `known_hosts` and so on all work just as they do in Terminal. **⌘K** (Connect to Server) also takes `user@host` or `ssh://user@host:port/path`.

## Finder features

- Icon, List, Column and Gallery views (⌘1–⌘4), remembered per folder
- Sidebar with Favourites (drag folders in, drag them out to remove), Locations, SSH hosts and Tags
- Back/forward history, enclosing folder (⌘↑), Go menu shortcuts, Go to Folder (⇧⌘G, also accepts `host:/path`)
- Sortable list columns with disclosure triangles (choose columns by right-clicking the header)
- Rename (Return), New Folder (⇧⌘N), Duplicate (⌘D), Make Alias, Compress, Move to Bin (⌘⌫) with undo
- Copy/paste files (⌘C / ⌘V / ⌥⌘V to move), and drag and drop between panes, windows and other apps
- Quick Look (Space), Get Info (⌘I), Open With, Share, Tags, Copy as Pathname, Open in Terminal
- Tabs (⌘T), path bar (⌥⌘P), status bar (⌘/), hidden files (⇧⌘.), search in the current folder (⌘F)
- Light and dark mode, using the system's own controls and Finder's symbols

## SSH details

- Listing, creating folders, renaming, duplicating and deleting all run on the server. Remote deletes are permanent, and Scout asks before deleting.
- Copying between the Mac and a server, or between two servers, streams `tar` over SSH, so folders, permissions and odd file names come through intact.
- Opening or Quick Looking a remote file downloads it to `~/Library/Caches/io.matej.Scout/Remote`. Dragging a remote file to the Desktop or into another app downloads it there.
- Each host keeps one multiplexed connection (`ControlMaster`). Use the eject button in the sidebar to disconnect.
- Passphrases, passwords and host-key confirmations appear as native dialogs through a small `SSH_ASKPASS` helper.

## Building

Open `Scout.xcodeproj` in Xcode 26 or later and run, or build from the command line:

```sh
xcodebuild -project Scout.xcodeproj -scheme Scout -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Scout.app
```

The app isn't sandboxed, because it needs `~/.ssh` and `/usr/bin/ssh`. To browse protected folders such as the Bin, grant it Full Disk Access.

## Development helpers

- `SCOUT_SELFTEST=<ssh-host>` runs file operations end to end, locally and over SSH, in temporary folders, then quits.
- `SCOUT_SNAPSHOT=/tmp/out.png` renders the window to a PNG. You can combine it with `SCOUT_START`, `SCOUT_VIEW`, `SCOUT_SPLIT=1`, `SCOUT_APPEARANCE=dark|light` and `SCOUT_SNAPSHOT_QUIT=1`.
