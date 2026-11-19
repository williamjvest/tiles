# Contributing

Issues and pull requests are welcome: a camera that misbehaves, a control Tiles is missing, a fix.

- **Build and test.** `cd Packages/CameraKit && swift test` runs the package's tests against simulated cameras
  (no hardware needed). The app builds from `App/project.yml` with XcodeGen (see the README).
- **Say what you tested on.** A camera model and its firmware, over which link, or "fake camera only".
- **Never add a way to format, erase or initialize a camera's media.** `NoMediaFormattingTests` reads every source
  file and fails on anything that looks like one.
- **Protocol facts come from what a camera does, or from public documentation.** Don't paste text from a maker's
  licensed SDK or reference documents, and don't cite them.
- **Comments say what the code does and why**, not who asked for it or when.
- Contributions are under the MIT license (`LICENSE`).

Report a security problem privately, as `SECURITY.md` says, not in an issue.
