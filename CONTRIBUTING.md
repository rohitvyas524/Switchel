# Contributing to Switchel

Thanks for helping out. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with:

- Your macOS version and Mac model
- The file type you used, and which wheel and slice you dropped it on
- What you expected and what happened instead (any error shown in the toast helps)
- Whether ffmpeg is installed (**Settings › Engines** shows this)

Please don't attach files that contain private information.

## Setting up

You need macOS 14+ on Apple silicon and Xcode 15+. For the audio and video tests, also install ffmpeg (`brew install ffmpeg`).

```sh
git clone https://github.com/rohitvyas524/Switchel.git
cd Switchel
swift test                  # run the test suite
./scripts/build-app.sh      # → build/Switchel.app
open build/Switchel.app
```

Quit any other copy of Switchel first, so two wheels don't open at once.

The **Layout** section of the [README](README.md#layout) shows where things live. In short: converters go in `Convert`, tool engines (no UI) go in `Tools`, and their SwiftUI windows go in `Editors`.

## Making a change

1. For anything bigger than a small fix, open an issue first so we can agree on the approach.
2. Fork the repo and create a branch from `main`.
3. Match the style of the code around your change: naming, comment density and structure.
4. Add or update tests in `Tests/SwitchelKitTests` for new converters and tools, and make sure `swift test` passes.
5. Keep everything local: Switchel never uploads files, and changes that send data off the Mac won't be accepted.
6. Open a pull request that explains what changed and why. Include a screenshot or short clip for UI changes.

## Good first contributions

- Intel and universal builds (the app is Apple silicon only right now)
- New formats or tools for an existing file family
- Better error messages when a conversion fails
- README and documentation fixes

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
