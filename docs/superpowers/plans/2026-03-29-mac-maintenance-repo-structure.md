# Mac Maintenance Repo Structure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the repository so the repaired app template, packaging assets, documentation, and build output are clearly separated.

**Architecture:** Treat the repository as a repaired binary distribution project. Keep the app bundle template intact, move presentation and packaging assets into dedicated directories, and update the packaging script to consume the renamed paths.

**Tech Stack:** Shell script packaging, macOS app bundle layout, DMG asset packaging

---

### Task 1: Create the new repository layout

**Files:**
- Create: `docs/`
- Create: `docs/superpowers/specs/`
- Create: `docs/superpowers/plans/`
- Create: `assets/dmg/`
- Create: `assets/readme/`
- Create: `build/`

- [ ] **Step 1: Create the destination directories**

Run: `mkdir -p docs/superpowers/specs docs/superpowers/plans assets/dmg assets/readme build`
Expected: directories exist without changing app bundle contents

- [ ] **Step 2: Verify the directory skeleton**

Run: `find . -maxdepth 2 \\( -type d -o -type f \\) | sort`
Expected: new `assets/`, `build/`, and `docs/` paths are present

### Task 2: Move the existing files into the approved groups

**Files:**
- Modify: `App_Template/` (renamed from `Source_Template/`)
- Modify: `assets/dmg/backgroundImage@2x.jpg`
- Modify: `assets/dmg/Volume.icns`
- Modify: `assets/dmg/AppIcon.icns`
- Modify: `assets/readme/Snipaste_2026-03-29_13-21-46.png`
- Modify: `assets/readme/设置-本地同步选项.png`
- Modify: `assets/readme/设置-欢喜云备份.png`
- Modify: `assets/readme/设置-设备.png`
- Modify: `assets/readme/设置-通用.png`
- Modify: `assets/readme/设置-闪念胶囊.png`
- Modify: `docs/HandShaker (Mac端) 连接卡死与内存泄漏修复报告.md`
- Modify: `build/HandShaker.app`
- Modify: `build/HandShaker-Mac-Maintained-v2.5.6.dmg`

- [ ] **Step 1: Rename the repaired app template directory**

Run: `mv Source_Template App_Template`
Expected: the app bundle template now lives under `App_Template/`

- [ ] **Step 2: Move DMG assets and README screenshots**

Run: move the root-level packaging assets into `assets/dmg/` and move screenshots into `assets/readme/`
Expected: the repository root is reduced to top-level project entry points

- [ ] **Step 3: Move the repair report into docs**

Run: `mv 'HandShaker (Mac端) 连接卡死与内存泄漏修复报告.md' docs/`
Expected: the report becomes project documentation instead of a root-level loose file

- [ ] **Step 4: Rename the output directory**

Run: `mv Release build`
Expected: packaged outputs now live under `build/`

### Task 3: Update the packaging script

**Files:**
- Modify: `build.sh`

- [ ] **Step 1: Replace the old template and asset paths**

Edit `build.sh` so it reads from `App_Template/Contents`, `assets/dmg/backgroundImage@2x.jpg`, and `assets/dmg/Volume.icns`

- [ ] **Step 2: Replace the old output paths**

Edit `build.sh` so it writes the assembled app and DMG into `build/`

- [ ] **Step 3: Keep the packaging behavior unchanged**

Ensure the script still performs the same three operations: assemble app, re-sign app, generate DMG

### Task 4: Verify the reorganization

**Files:**
- Verify: `build.sh`
- Verify: `App_Template/`
- Verify: `assets/dmg/`
- Verify: `assets/readme/`
- Verify: `docs/`
- Verify: `build/`

- [ ] **Step 1: Check the top-level layout**

Run: `find . -maxdepth 2 \\( -type d -o -type f \\) | sort`
Expected: top-level entries match the approved structure

- [ ] **Step 2: Check script references**

Run: `rg 'Source_Template|Release/|backgroundImage@2x.jpg|Volume.icns' build.sh`
Expected: only the new path forms remain

- [ ] **Step 3: Sanity-check build script syntax**

Run: `bash -n build.sh`
Expected: no syntax errors
