# Mac Maintenance Repo Structure Design

## Goal

Align the macOS maintenance repository with the Android maintenance repository's public-facing structure so the project reads clearly as a repaired distribution/packaging repo rather than a source-code repo.

## Approved Structure

```text
.
├── App_Template/
├── assets/
│   ├── dmg/
│   └── readme/
├── build/
├── docs/
└── build.sh
```

## Decisions

1. Rename `Source_Template/` to `App_Template/` to reflect that it stores the repaired HandShaker app template.
2. Move DMG packaging assets into `assets/dmg/`.
3. Move README screenshots into `assets/readme/`.
4. Move the repair report into `docs/`.
5. Rename the output directory from `Release/` to `build/`.
6. Update `build.sh` so packaging still works against the new paths.

## Constraints

- The repository is a binary-maintenance and packaging repo, not a compilable source repo.
- The repaired app bundle contents must remain unchanged during the reorganization.
- The build script should preserve the existing packaging flow: assemble app, re-sign, generate DMG.

## Verification

- Confirm all moved files exist in their new locations.
- Confirm `build.sh` references only the new paths.
- Confirm the output DMG path now points into `build/`.
