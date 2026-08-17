# Team Details Screen Redesign (Top Scores)

Please redesign the **Team Details** screen to match the attached reference mock-up while maintaining the existing Top Scores design language (dark theme, premium sports broadcast aesthetic, rounded cards, subtle gradients and glass effects).

The goal is **not** to copy the mock-up exactly, but to recreate the same overall feel and level of polish.

## Overall Design Goals

- Make the screen feel like a premium football broadcast app (FotMob, OneFootball, LiveScore quality).
- Use depth through gradients, soft glows and subtle lighting rather than heavy borders.
- Maintain generous spacing and consistent corner radii.
- Improve hierarchy so the hero section immediately draws the eye.
- Use smooth animations where appropriate (parallax, fade, subtle scaling).

---

# Hero Section

Replace the existing flat blue card with a dramatic full-width hero.

## Background

- Use a blurred stadium photograph that fills the entire hero.
- Prefer floodlights and crowd for evening matches.
- Apply:
  - dark gradient overlay from top
  - stronger black overlay at the bottom to improve text readability
  - subtle vignette around edges
  - optional club colour tint (very subtle)

The stadium should feel immersive without distracting from the content.

---

## Team Crest

The crest should become the focal point.

- Increase size significantly
- Remove the white rounded square background
- Use the transparent PNG crest directly
- Add:
  - soft drop shadow
  - faint coloured glow
  - optional light bloom behind the crest

The crest should appear to float above the stadium.

---

## Team Name

Large bold title.

Below:

Competition

Include competition logo if available.

Example:

Premier League lion logo + "Premier League"

---

## Optional Polish

If performance allows:

- slow moving floodlight beams
- subtle animated crowd lighting
- gentle parallax while scrolling
- hero collapses slightly into navigation bar during scroll

---

# Current Season Card

This should become a premium stats dashboard rather than a simple grid.

Keep it as one card.

Use a dark blue/navy gradient background.

Very subtle gloss effect.

No heavy borders.

---

## Card Header

Left:

Competition logo

Competition name

Right:

"View Table >"

Blue accent.

---

## Stats Layout

Retain the existing grid but improve presentation.

Each stat should contain:

Large number

Small uppercase label underneath

For example:

0

PLAYED

NOT:

(icon)

PLAYED

The number should always be the primary focus.

The icon is secondary.

---

## Icons

Use small monochrome line icons positioned above or beside the number.

Examples:

Position → trophy

Played → football pitch

Won → green circle/check

Drawn → yellow circle

Lost → red circle

Goals For → goal

Goals Against → goal

Goal Difference → balance scales

Points → star

Icons should be approximately 16–18pt.

Never replace the numeric value.

The value (0, 24, 71 etc.) must always be displayed.

---

## Position Tile

Make Position slightly more prominent.

Use:

- subtle club-colour gradient
- slightly larger tile
- faint glow

Example:

🏆

1st

POSITION

This becomes the primary stat.

---

## Tile Styling

Avoid individual floating rounded cards.

Instead:

- use invisible columns
- thin separators
- plenty of spacing

This feels cleaner and more premium.

---

## Typography

Primary value:

large

bold

white

Secondary label:

small

uppercase

semi-transparent white

consistent spacing

---

## Background Details

Inside the card add extremely subtle decorative elements:

- faint geometric shapes
- abstract diagonal lines
- almost invisible football pitch lines

These should only become visible when looking closely.

---

# Colours

Primary background:

Near black

Cards:

Deep navy gradients

Accent:

Top Scores blue

Club colours:

Use only as subtle highlights.

Do not overpower the interface.

---

# Motion

When data loads:

- numbers fade in
- crest gently scales
- card slides upwards
- hero background subtly fades

Keep animations under 300ms.

---

# Constraints

- Maintain existing data model.
- Keep all current statistics.
- Do not remove any functionality.
- Preserve Dynamic Type support.
- Support Dark Mode.
- Layout must work on all iPhone sizes.

---

# Most Important Requirements

1. Dramatic full-width stadium hero.
2. Large floating club crest.
3. Premium typography.
4. Broadcast-quality visual style.
5. Current Season card redesigned as a modern statistics dashboard.
6. Every statistic **must display its numeric value** (e.g. 0, 14, 72).
7. Icons are decorative only and **must never replace the numbers**.
8. Match the attached mock-up's visual quality while remaining faithful to the existing Top Scores design language.