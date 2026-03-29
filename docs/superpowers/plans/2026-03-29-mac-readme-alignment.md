# Mac README Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the macOS maintenance README with the Android maintenance README style while preserving the essential repair explanation and usage notes.

**Architecture:** Keep the README as a concise repository homepage. Shift technical depth into linked documentation, use a clearer visual hierarchy, and ensure all referenced local assets match the final structure.

**Tech Stack:** Markdown, Git, GitHub repository homepage conventions

---

### Task 1: Lock the README content structure

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Reorder the README into homepage-first sections**

Place the logo, title, positioning sentence, notice, screenshot preview, highlights, current status, downloads, repository structure, maintainer notes, and disclaimer in that order.

- [ ] **Step 2: Keep only essential technical explanation inline**

Retain a short explanation of the root cause, repair approach, known side effect, and the link to the detailed repair report.

### Task 2: Verify assets and links

**Files:**
- Verify: `README.md`
- Verify: `ic_launcher.png`
- Verify: `assets/readme/截图预览.png`
- Verify: `assets/readme/本地同步选项弹窗-移除后.png`
- Verify: `docs/HandShaker (Mac端) 连接卡死与内存泄漏修复报告.md`

- [ ] **Step 1: Confirm all README assets exist**

Run local file checks for the logo, main preview, note screenshot, and repair report.

- [ ] **Step 2: Read the final README content**

Review the top-to-bottom text flow and ensure the structure now reads closer to the Android maintained repository.

### Task 3: Publish the README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Review git status**

Run: `git status --short`
Expected: README and any intended new assets appear, unrelated changes are left untouched.

- [ ] **Step 2: Commit the README refresh**

Run: `git add README.md docs/superpowers/specs/2026-03-29-mac-readme-alignment-design.md docs/superpowers/plans/2026-03-29-mac-readme-alignment.md`
Expected: staged README alignment changes only

- [ ] **Step 3: Push to GitHub**

Run: `git push origin HEAD`
Expected: remote repository receives the README update
