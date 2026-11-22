<img src="art/Siftmark.png" width="112" height="112" alt="Siftmark icon">

# Siftmark

Siftmark shows which files and folders occupy space on your Mac. Choose a folder to compare allocated sizes, inspect a subfolder, or reveal an item in Finder. The native macOS window uses a Rust scanner that runs locally.

**Cleanup Review** finds installer files directly inside a chosen folder. Select an app to review its bundle and exact bundle-ID matches in your user Library’s Caches, Logs, and Preferences. Review each path before moving it to Trash. Shared files and APFS clones can make the space recovered differ from the size shown.

## Using Siftmark

- Press **⌘O** to choose a folder. Click a column header to sort, or select a folder and choose **Inspect**. Press **⌘R** to rescan.
- **⌘-click** selects individual rows, **Shift-click** selects a range, and **⌘A** selects all rows in the focused table.
- **Reveal in Finder** sends the selected paths to Finder. **⌘Delete** opens a list of paths for review. **Move to Trash** acts on that list. Recover an item from the Trash using Finder’s **Put Back** command.
- If a file is replaced after scanning, Siftmark skips it. Successful moves disappear from the table. Failed items stay selected. Refresh to review changed files before retrying.
- Installer review checks the immediate folder for regular DMG, PKG, MPKG, XIP, and ISO files. App review checks exact bundle identifiers in Caches, Logs, and Preferences. A matching identifier alone does not establish exclusive ownership.
- A **partial** size means the scanner encountered unreadable entries or a volume boundary. Symbolic links are measured without following them.

## Build and run

Install Rust with Cargo and the Xcode Command Line Tools on your Mac. From the repository root, run:

```sh
cargo test --locked
./build.sh
open dist/Siftmark.app
```

The build targets macOS 14 or later on the build machine’s architecture. The app has been exercised on Apple Silicon with macOS 26. The default build uses a local ad-hoc signature.

## Package a public download

On a Mac with a Developer ID Application certificate and matching private key, configure a notarytool keychain profile for the same developer team. Set `DEVELOPER_ID_APPLICATION` to the signing identity and `NOTARY_PROFILE` to the profile name. Run `./build.sh --release` to sign both executables with hardened runtime, submit the app for notarization, staple the ticket, and assess it with Gatekeeper. The versioned ZIP appears in `dist/` after these checks pass.

## License

[MIT](LICENSE)
