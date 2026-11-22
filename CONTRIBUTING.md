# Contributing to Siftmark

Bug reports, documentation fixes, and pull requests are welcome. For a new cleanup rule, describe which files it would match and give an example of a similar file it should leave alone.

## Report a bug

[Open an issue](https://github.com/alexgtmbot/siftmark/issues/new) with your Siftmark version, macOS version, the steps to reproduce the problem, and what you expected to happen. For scan or Trash bugs, a small example folder with invented filenames helps others reproduce it. Remove personal paths from screenshots and logs.

## Make a change

1. Fork the repo, clone your fork, and create a branch. Follow the [build instructions](README.md#build-from-source) to run the app locally. The default build works without an Apple Developer account.
2. For disk measurement or cleanup matching, start in [src/main.rs](src/main.rs). For selection, review, Finder, or Trash behavior, start in [Window.swift](Window.swift).
3. Run the [development checks](README.md#development). Add a focused regression test for scanner changes. For UI changes, exercise the affected flow in the built app.
4. Open a pull request against `main`. Describe the user-visible change and how you tested it. A before-and-after screenshot helps reviewers assess visual changes.

When testing Trash, use disposable files. Verify that cancel preserves them, confirmation moves only the reviewed paths, and a file replaced between scan and confirmation stays in place.

Pull requests targeting `main` run the **macOS build and test** check. It checks Rust formatting, lint, and tests, builds the native app, then extracts the ZIP and exercises the bundled scanner. Release signing credentials stay on the maintainer’s Mac.
