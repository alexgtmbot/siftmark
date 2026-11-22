<img src="art/Siftmark.png" width="112" height="112" alt="Siftmark icon">

# Siftmark

Siftmark shows which files and folders occupy space on your Mac. Choose a folder to compare allocated sizes, inspect a subfolder, or reveal an item in Finder. The native macOS window uses a Rust scanner that runs locally.

**Cleanup Review** finds installer files directly inside a chosen folder. Select an app to review its bundle and exact bundle-ID matches in your user Library’s Caches, Logs, and Preferences. Review each path before moving it to Trash. Shared files and APFS clones can make the space recovered differ from the size shown.

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
