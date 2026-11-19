# False color LUTs

The app's own false color LUT is `Packages/CameraKit/Sources/CameraCore/Resources/TW False Color SLog3.cube`, made
by `scripts/make-false-color-lut.py`.

Tiles finds a camera's false color LUT by its name: "False Color" in it, or FC as its own word. The tests and docs use
the names of **George Kamenov's GK SLog3 False Color LUTs** (`GK_SLOG3_Log_FC`, `GK_SLOG3_Rec709_FC`) as examples,
since they're the ones on our cameras. The LUTs themselves are his and aren't in this repository: get them, and thank
him, at https://buymeacoffee.com/georgekamenov/e/248021.
