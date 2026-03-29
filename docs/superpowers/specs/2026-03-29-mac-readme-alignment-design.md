# Mac README Alignment Design

## Goal

Refresh the macOS maintenance repository README so it visually and structurally aligns with the Android maintenance repository while preserving macOS-specific repair details, warnings, and usage notes.

## Direction

Adopt the Android README's lightweight repository-homepage structure:

1. Logo first
2. Title and one-line positioning
3. Important non-official notice
4. Screenshot preview
5. Project highlights
6. Current status
7. Download and usage
8. Repository structure
9. Maintainer notes
10. Copyright and disclaimer

## macOS-Specific Content To Preserve

- The project repairs the original HandShaker macOS client rather than compiling a new source build.
- The repaired flow was validated on macOS 15, Apple Silicon, via Rosetta 2.
- The old local sync options dialog is the key trigger for the freeze/memory issue.
- The repair skips the broken UI initialization path, which leaves a title-only window as a known side effect.
- The detailed reverse-engineering report should remain linked from the README.

## Content Changes

- Add the root `ic_launcher.png` logo at the top to mirror the Android README feel.
- Use `assets/readme/截图预览.png` as the main screenshot preview image.
- Keep `assets/readme/本地同步选项弹窗-移除后.png` in a usage note section instead of as the main preview.
- Tighten the sections so the page reads more like a release landing page than a full technical report.
