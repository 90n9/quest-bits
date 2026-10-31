---
version: 1
name: QuestBit-cozy-rpg
description: QuestBit is a macOS quest-log todo app themed as a cozy RPG — a warm tavern quest board rendered in parchment and wood. Aged-paper surfaces ({colors.parchment}) carry bark-brown ink ({colors.ink}), trimmed with harvest gold ({colors.gold}) and herb green ({colors.herb}); ember rust ({colors.ember}) marks links and selection. Alegreya (a storybook serif) carries headings while Quicksand (soft rounded sans) keeps body text friendly and highly readable. Tasks read as quests, projects as quest logs.
colors:
  bark: "#4a3423"
  on-bark: "#f9f0dd"
  gold: "#d9a33c"
  gold-deep: "#c08c28"
  gold-light: "#f4e3b8"
  gold-dark: "#7a5a12"
  ember: "#c8622f"
  ember-pressed: "#a34d20"
  clay: "#d98d6a"
  clay-light: "#f3cdb7"
  clay-dark: "#8a3a12"
  blush: "#f6dfd0"
  herb: "#5c8f4a"
  herb-light: "#ddead0"
  moss-dark: "#3f6b2a"
  error-soft: "#eecdc0"
  error-border: "#d9b2a2"
  success-accent: "#6f9b3c"
  parchment: "#faf3e3"
  vellum: "#fdf9ec"
  parchment-aged: "#f1e5cc"
  parchment-soft: "#f6eedd"
  surface-gold: "#f7ebc9"
  selection-gold: "#f5e3b3"
  hairline: "#d9c4a0"
  hairline-soft: "#e7d9bb"
  hairline-strong: "#c2a87e"
  ink-deep: "#33241a"
  ink: "#4a3423"
  bark-pressed: "#5d4430"
  slate: "#6f583f"
  steel: "#8c745c"
  stone: "#a08a6e"
  muted: "#b5a289"
  on-dark: "#f9f0dd"
  on-dark-muted: "#cbb598"

typography:
  heading-2:
    fontFamily: Alegreya
    fontSize: 36px
    fontWeight: 700
    lineHeight: 1.20
  heading-3:
    fontFamily: Alegreya
    fontSize: 28px
    fontWeight: 700
    lineHeight: 1.25
  heading-4:
    fontFamily: Alegreya
    fontSize: 22px
    fontWeight: 700
    lineHeight: 1.30
  heading-5:
    fontFamily: Alegreya
    fontSize: 18px
    fontWeight: 700
    lineHeight: 1.40
  subtitle:
    fontFamily: Quicksand
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.50
  body-md:
    fontFamily: Quicksand
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.50
  body-md-medium:
    fontFamily: Quicksand
    fontSize: 16px
    fontWeight: 600
    lineHeight: 1.50
  body-sm:
    fontFamily: Quicksand
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.50
  body-sm-medium:
    fontFamily: Quicksand
    fontSize: 14px
    fontWeight: 600
    lineHeight: 1.50
  caption:
    fontFamily: Quicksand
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.40
  caption-bold:
    fontFamily: Quicksand
    fontSize: 13px
    fontWeight: 700
    lineHeight: 1.40
  micro:
    fontFamily: Quicksand
    fontSize: 12px
    fontWeight: 500
    lineHeight: 1.40
  micro-uppercase:
    fontFamily: Quicksand
    fontSize: 11px
    fontWeight: 700
    lineHeight: 1.40
    letterSpacing: 0.5px
  button-md:
    fontFamily: Quicksand
    fontSize: 14px
    fontWeight: 700
    lineHeight: 1.30
  code-badge:
    fontFamily: SF Mono
    fontSize: 11px
    fontWeight: 600
    lineHeight: 1.30

rounded:
  xs: 4px
  sm: 6px
  md: 8px
  lg: 12px
  xl: 16px
  xxl: 20px
  full: 9999px

spacing:
  xxs: 4px
  xs: 8px
  sm: 12px
  md: 16px
  lg: 20px
  xl: 24px
  xxl: 32px

components:
  button-primary:
    backgroundColor: "{colors.bark}"
    textColor: "{colors.on-bark}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: "12px 24px"
  button-primary-pressed:
    backgroundColor: "{colors.bark-pressed}"
    textColor: "{colors.on-bark}"
  button-primary-disabled:
    backgroundColor: "{colors.hairline}"
    textColor: "{colors.muted}"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: "12px 24px"
    border: "1px solid {colors.hairline-strong}"
  button-on-dark:
    backgroundColor: "{colors.on-dark}"
    textColor: "{colors.bark}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: "12px 24px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.button-md}"
    rounded: "{rounded.md}"
    padding: "8px 12px"
  button-link:
    backgroundColor: "transparent"
    textColor: "{colors.ember}"
    typography: "{typography.body-sm-medium}"
    padding: "0"
  button-icon-circular:
    backgroundColor: "{colors.parchment}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
    size: 36px
    border: "1px solid {colors.hairline}"
  card-base:
    backgroundColor: "{colors.parchment}"
    rounded: "{rounded.xl}"
    padding: "{spacing.xl}"
    border: "1px solid {colors.hairline-soft}"
  quest-row:
    backgroundColor: "{colors.parchment}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sm} {spacing.md}"
    border: "1px solid {colors.hairline}"
  quest-row-selected:
    backgroundColor: "{colors.selection-gold}"
    rounded: "{rounded.lg}"
    border: "1px solid {colors.ember}"
  nav-item-active:
    backgroundColor: "{colors.selection-gold}"
    textColor: "{colors.ember}"
    typography: "{typography.body-sm-medium}"
    rounded: "{rounded.md}"
  badge-gold:
    backgroundColor: "{colors.surface-gold}"
    textColor: "{colors.gold-dark}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-clay:
    backgroundColor: "{colors.clay-light}"
    textColor: "{colors.clay-dark}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-herb:
    backgroundColor: "{colors.herb-light}"
    textColor: "{colors.moss-dark}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  badge-success:
    backgroundColor: "{colors.success-accent}"
    textColor: "{colors.on-bark}"
    typography: "{typography.caption-bold}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  code-badge:
    backgroundColor: "{colors.parchment-aged}"
    textColor: "{colors.steel}"
    typography: "{typography.code-badge}"
    rounded: "{rounded.sm}"
    padding: "2px 6px"
  text-input:
    backgroundColor: "{colors.vellum}"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: "{spacing.sm} {spacing.md}"
    border: "1px solid {colors.hairline-strong}"
  text-input-focused:
    backgroundColor: "{colors.parchment}"
    textColor: "{colors.ink}"
    border: "2px solid {colors.ember}"
  toast:
    backgroundColor: "{colors.bark}"
    textColor: "{colors.on-dark}"
    typography: "{typography.body-sm-medium}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sm} {spacing.md}"
  update-banner:
    backgroundColor: "{colors.bark}"
    textColor: "{colors.on-dark}"
    typography: "{typography.body-sm-medium}"
    padding: "{spacing.sm} {spacing.md}"
---

## Overview

QuestBit renders a todo app as a **cozy RPG quest board** — the mood of a Stardew Valley
tavern: warm parchment, wood-brown ink, gold trim, herb-green success. Calm and friendly,
built for long working sessions; the game feel comes from warmth, texture, and quest-log
language, never from noise.

**Key characteristics:**
- Parchment surfaces ({colors.parchment} / {colors.parchment-aged}) instead of white/grey
- All text in warm browns — {colors.ink} (bark) down to {colors.muted}; no pure black or cool grey
- Harvest gold ({colors.gold}) is the brand accent: badges, XP/progress, active states
- Ember rust ({colors.ember}) replaces "action blue": links, selection strokes, focus rings
- Herb green ({colors.success-accent}) for done/success
- Alegreya bold serif headings; Quicksand rounded-sans body — readability first
- Dark bark ({colors.bark}) reserved for toasts, banners, and primary buttons
- Pills everywhere buttons appear ({rounded.full}); cards and rows use {rounded.lg}–{rounded.xl}

## Colors

### Brand & Accent
- **Gold** ({colors.gold}): harvest gold — brand accent, progress fills, "in-progress" markers. Deep variant {colors.gold-deep} for emphasis/hover; chip pair {colors.gold-light} fill + {colors.gold-dark} text.
- **Ember** ({colors.ember}): rust orange — the "interactive" color: links, selected-row strokes, focus rings, active filters. Pressed variant {colors.ember-pressed}.
- **Clay** ({colors.clay}): warm terracotta callouts; chip pair {colors.clay-light} / {colors.clay-dark}.
- **Herb** ({colors.herb}): supporting green accent; chip pair {colors.herb-light} / {colors.moss-dark}.
- **Blush** ({colors.blush}): soft warm tint for gentle emphasis surfaces.

### Surface
- **Parchment** ({colors.parchment}): main background and card fill.
- **Vellum** ({colors.vellum}): brightest cream — input-field fill only, so fields read as inset against border-less raised cards.
- **Parchment Aged** ({colors.parchment-aged}): sidebar/panels, pressed fills, quiet chips.
- **Parchment Soft** ({colors.parchment-soft}): quieter section divisions.
- **Surface Gold** ({colors.surface-gold}): gold-tinted chip/tag surface.
- **Selection Gold** ({colors.selection-gold}): selected rows and active nav items — replaces any system-blue selection.
- **Hairlines**: {colors.hairline} default, {colors.hairline-soft} quiet dividers, {colors.hairline-strong} inputs.

### Text
- **Ink Deep** ({colors.ink-deep}): espresso — largest headings.
- **Ink** ({colors.ink}): primary text; same value as {colors.bark}.
- **Slate / Steel / Stone / Muted**: warm-brown secondary→disabled ramp. Never cool greys.
- **On Dark** ({colors.on-dark}) and {colors.on-dark-muted}: cream text on bark surfaces.

### Semantic
- **Success** ({colors.success-accent}): quest complete, checkmarks, positive stats.
- **Error** ({colors.error-soft} background, {colors.error-border} border, {colors.clay-dark} text).

## Typography

### Font Families
- **Alegreya** (headings): storybook serif, bold (700). Variable TTF bundled at `Resources/Fonts/Alegreya.ttf` (OFL).
- **Quicksand** (body, buttons, badges): soft geometric rounded sans. Variable TTF bundled at `Resources/Fonts/Quicksand.ttf` (OFL).
- **SF Mono** (system monospaced): task/project code badges only (`GEN-3`).

Both fonts are registered at launch via `ATSApplicationFontsPath` (Info.plist, written by `Scripts/build-app.sh`). Readability rule: **display serif is confined to headings — task titles, lists, and controls always use Quicksand.**

### Hierarchy

| Token | Font | Size | Weight | Use |
|---|---|---|---|---|
| `{typography.heading-2}` | Alegreya | 36px | 700 | Dashboard title |
| `{typography.heading-3}` | Alegreya | 28px | 700 | Page headlines |
| `{typography.heading-4}` | Alegreya | 22px | 700 | Sheet titles |
| `{typography.heading-5}` | Alegreya | 18px | 700 | Card/section titles |
| `{typography.subtitle}` | Quicksand | 18px | 400 | Subtitles |
| `{typography.body-md}` | Quicksand | 16px | 400 | Primary body |
| `{typography.body-md-medium}` | Quicksand | 16px | 600 | Emphasized body |
| `{typography.body-sm}` | Quicksand | 14px | 400 | Secondary body, rows |
| `{typography.body-sm-medium}` | Quicksand | 14px | 600 | Nav items, links |
| `{typography.caption}` | Quicksand | 13px | 400 | Helper text |
| `{typography.caption-bold}` | Quicksand | 13px | 700 | Badges, chips |
| `{typography.micro}` | Quicksand | 12px | 500 | Microcopy |
| `{typography.micro-uppercase}` | Quicksand | 11px | 700 | Section labels (0.5px tracking) |
| `{typography.button-md}` | Quicksand | 14px | 700 | Button labels |
| `{typography.code-badge}` | SF Mono | 11px | 600 | `GEN-3` code chips |

### Swift token mapping

`Sources/TodoApp/Theme.swift` keeps its original identifiers for source stability. Mapping:

| DESIGN.md | Theme.swift |
|---|---|
| `{colors.bark}` | `Colors.primary` / `Colors.ink` |
| `{colors.on-bark}` | `Colors.onPrimary` |
| `{colors.gold}` / `{colors.gold-deep}` | `Colors.brandYellow` / `Colors.brandYellowDeep` |
| `{colors.gold-light}` / `{colors.gold-dark}` | `Colors.yellowLight` / `Colors.yellowDark` |
| `{colors.ember}` / `{colors.ember-pressed}` | `Colors.brandBlue` / `Colors.bluePressed` |
| `{colors.clay}` (+light/dark) | `Colors.brandCoral` / `coralLight` / `coralDark` |
| `{colors.blush}` | `Colors.roseLight` |
| `{colors.herb}` (+light) / `{colors.moss-dark}` | `Colors.brandTeal` / `tealLight` / `mossDark` |
| `{colors.error-soft}` / `{colors.error-border}` | `Colors.brandRed` / `brandRedDark` |
| `{colors.parchment}` | `Colors.canvas` |
| `{colors.vellum}` | `Colors.vellum` |
| `{colors.parchment-aged}` | `Colors.surface` |
| `{colors.parchment-soft}` | `Colors.surfaceSoft` |
| `{colors.surface-gold}` | `Colors.surfaceYellow` |
| `{colors.selection-gold}` | `Colors.surfacePricingFeatured` |
| `{colors.bark-pressed}` | `Colors.charcoal` |

## Layout

### Spacing System
- **Base unit**: 4px. Tokens: `{spacing.xxs}` 4 · `{spacing.xs}` 8 · `{spacing.sm}` 12 · `{spacing.md}` 16 · `{spacing.lg}` 20 · `{spacing.xl}` 24 · `{spacing.xxl}` 32.
- Keep the current generous list/row spacing — readability is a hard requirement carried over from the previous design.

### App Structure
- Sidebar (quest logs / projects) on {colors.parchment-aged}, main content on {colors.parchment}.
- Dark bark ({colors.bark}) in the main window is kept to the update banner and toasts; the window has no bottom bar.

## Shapes

| Token | Value | Use |
|---|---|---|
| `{rounded.xs}` | 4px | Micro chips |
| `{rounded.sm}` | 6px | Code badges |
| `{rounded.md}` | 8px | Inputs, ghost buttons, nav rows |
| `{rounded.lg}` | 12px | Quest rows |
| `{rounded.xl}` | 16px | Cards, sheets |
| `{rounded.xxl}` | 20px | Large panels |
| `{rounded.full}` | 9999px | All pill buttons and badges |

Elevation stays flat-with-hairlines. Depth cue is a warm 2px drop edge (`0 2px 0 rgba(138,106,72,.18)`) on cards/rows instead of blurred shadows — reads as stacked paper.

### Decorative art (bundled, `Contents/Resources/`)
- **Icons/** — Lucide (ISC) + Tabler (MIT) SVGs, template-tinted via `QBIcon`. Sidebar views (map, swords, castle, backpack, door-open).
- **Frames/panel-border.png** — Kenney Fantasy UI Borders (CC0), white line-art 9-slice, template-tinted. Applied around the task-detail pane via `.qbQuestFrame()` (default {colors.hairline-strong}). Decorative only, never intercepts clicks.
- **Textures/paper.jpg** — ambientCG Paper001 (CC0), tiled at 12% opacity over {colors.parchment} via `.qbParchment()` — every former flat-canvas pane.
- **Textures/planks.jpg** — ambientCG Planks037A (CC0), tiled under a `{colors.bark}` 85% scrim via `.qbHearth()` — update banner.
- License texts ship in the same bundle folders (`LICENSE-lucide.txt`, `LICENSE-tabler.txt`, `LICENSE-kenney.txt`, `LICENSE-ambientcg.txt`).

## Components

**`button-primary`** — bark pill, cream text; pressed → {colors.bark-pressed}; disabled → {colors.hairline} + {colors.muted}.

**`button-secondary`** — outlined pill, {colors.hairline-strong} border, ink text.

**`button-on-dark`** — cream pill on bark surfaces (update banner).

**`button-ghost`** — quiet rectangular, pressed fill {colors.parchment-aged}.

**`button-link`** — inline ember text link.

**`quest-row`** — task row: parchment fill, {colors.hairline} border, {rounded.lg}, 2px paper-edge shadow. Selected → `quest-row-selected` ({colors.selection-gold} fill + {colors.ember} stroke). Done rows strike through at 45% opacity.

**`nav-item-active`** — sidebar selection: {colors.selection-gold} fill, ember text.

**Badges** — `badge-gold` (medium priority / in-progress), `badge-clay` (high priority / overdue), `badge-herb` (tags), `badge-success` (done). All full pills, `{typography.caption-bold}`.

**`code-badge`** — `GEN-3` chips: SF Mono on {colors.parchment-aged}, {rounded.sm}.

**`toast` / `update-banner`** — bark background, cream text, `button-on-dark` actions.

## Do's and Don'ts

### Do
- Keep every background warm — parchment family only; no white, no grey
- Use {colors.ember} wherever "action blue" would appear (links, focus, selection strokes)
- Reserve Alegreya for headings; Quicksand for everything interactive
- Reserve {colors.bark} fills for primary buttons, toasts, banners
- Keep pills ({rounded.full}) for all buttons and badges
- Use quest-log language in UI copy where natural (quests, quest logs, streaks)

### Don't
- Don't introduce cool colors (blue/purple/cyan) anywhere
- Don't set body text or task titles in Alegreya — readability rule
- Don't use pure black (#000) or pure white (#fff); warmest ends are {colors.ink-deep} and {colors.parchment}
- Don't add blurred drop shadows — flat hairlines + 2px paper edge only
- Don't let game flavor reduce information density or legibility

## Known Gaps

- No dark-mode tokens — app remains locked to light appearance (TodoApp.swift)
- Menu-bar item (MenuBarExtra) uses a system template icon and font by OS constraint — out of scope
- Decorative assets integrated (Lucide/Tabler icons, Kenney frame, ambientCG textures — see "Decorative art"); remaining candidates for later: Kenney dividers as section separators, frame variants on sheets/dashboard tiles
