# Interactive Organization Planner

A visual, interactive organization planner for organizing and modeling teams. Built entirely in freestanding Zig, rendering directly to a high-performance WebAssembly pixel buffer using a custom glassmorphic aesthetic.

## Features & Simulation Sandbox

- **Instant Scenario Forking**: Compare structure models in real-time. Switch between **Original**, **Plan A**, **Plan B**, and **Plan C** tabs at the top. Clicking an empty plan tab automatically forks the currently active team.
- **Interactive Tree Hierarchy**: Automatically centers parent nodes above their direct reports using a dynamic horizontal segment-splitting layout.
- **Orthogonal Connections**: Renders clean, routing-optimized manager-to-report connecting lines. Connection lines are dynamically greyed out if any reporting lines are broken by a termination.
- **Smart Manager Reassignments**: Click **Reassign Manager** in the command sidebar and click any other worker in the tree to move them. Includes automatic cycle-prevention (e.g. you cannot assign a manager to report to their own direct report).
- **Interactive Inplace Editing**: Click the **Name** or **Role / Title** text input box in the command sidebar to immediately start typing with live keyboard feedback and a blinking caret. Press `Enter` to commit, or `Esc` to cancel.
- **Fire & Rehire Simulators**: Toggle **Fire Worker** to instantly grey out their node and connection lines, drawing a striking red cross over them to model staffing changes. Toggle **Rehire** to bring them back.
- **Hire & Delete Cleaners**: Click **+ Hire Report** to add a new worker reporting to the selected person. Click **Delete Worker** to permanently prune them, automatically promoting their direct reports to report to their manager (preventing orphaned branches).
- **Accent Branding**: Customize each employee's outline branding using 5 glowing theme circles (electric violet, vibrant blue, mint emerald, glow orange, and neon pink).

<qip-play>
  <source src="/gui/org_planner.wasm" type="application/wasm" />
</qip-play>

---

## Interactive Controls Guide

- **Selection**: Click on any node in the tree to view their detail card in the **Command Portal** sidebar. Click on empty space in the tree area to deselect.
- **Tabs**: Click any active scenario tab at the top to switch to that version. Click any `+ FORK PLAN` tab to copy your current active layout into a new sandbox branch.
- **Text Editing**: Click the Name or Title text box in the sidebar to focus. Type any letter, number, or symbol. Press `Backspace` to delete, `Enter` to save, or `Escape` to discard.
- **Reassigning**: Click the Reassign button, then click on the new manager in the tree. To cancel, press `Escape` or click the button again.
