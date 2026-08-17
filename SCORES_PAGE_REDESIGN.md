# Top Scores – Scores Screen Redesign (v2)

## Objective

Redesign the **Scores** screen to match the new premium visual language introduced in the **Team Details** redesign.

The Team Details screen should now be considered the primary design reference for the application. The Scores screen should feel like it belongs to exactly the same product, using the same colours, spacing, depth, typography, gradients, and overall design philosophy.

Do **not** invent a new design language.

Instead, reuse the styling established by Team Details throughout.

---

# Primary Design Reference

Use the newly redesigned **Team Details** screen as the visual benchmark.

Specifically reuse:

- Stadium hero treatment
- Dark navy gradients
- Glassmorphism effects
- Blue accent colours
- Typography hierarchy
- Rounded cards
- Soft lighting
- Premium broadcast aesthetic
- Subtle depth rather than heavy borders

Everything should feel like the same design system.

---

# Overall Style

The application should resemble a modern football broadcast app.

Think:

- Apple Sports
- FotMob
- OneFootball
- LiveScore

Characteristics:

- cinematic
- premium
- understated
- elegant
- spacious
- broadcast graphics

Avoid:

- flat grey panels
- harsh borders
- cramped spacing
- oversized shadows
- excessive neon

---

# Background

Replace the current plain black background.

Use the same treatment as Team Details.

Requirements:

- heavily blurred football stadium
- floodlights visible
- extremely dark
- subtle crowd texture
- black gradient overlays
- vignette around edges

The stadium should provide atmosphere without competing with the content.

---

# Header

Current:

Fixtures: Saturday, August 22nd

Redesign to match Team Details typography.

Example:

Fixtures

Saturday, August 22nd

Large bold title.

Smaller muted subtitle underneath.

Generous spacing.

---

# Header Buttons

Reuse the Team Details button styling.

Buttons should be:

- floating
- glass
- rounded
- subtle blur
- thin border
- blue glow

Left:

Back

Right:

Calendar

Animations should match Team Details.

---

# Date Carousel

Keep the existing UX.

Visually modernise it.

Requirements:

Selected date:

- bright white text
- blue underline
- subtle glow

Unselected:

- muted grey

Increase spacing slightly.

Scrolling should feel smooth.

---

# Competition Sections

## Important

The grouped competition card concept introduced in the previous prototype should remain.

Each competition should become a single rounded container.

Inside it:

Competition Header

Fixture rows

This matches the grouped information architecture used elsewhere in the app.

---

# Competition Header

Follow the same spacing rules as Team Details cards.

Layout:

League logo

League name

Small coloured accent

No unnecessary divider.

Use the same typography hierarchy used in Team Details.

---

# Alignment (Very Important)

One issue identified in the previous mock-up was the left alignment.

Please ensure:

- competition card
- competition header
- fixture rows

all align perfectly.

There should **not** be a second inset border.

Instead the entire section should feel like one unified card.

Visual example:

GOOD

╭────────────────────────────╮
│ PREMIER LEAGUE             │
│                            │
│ Everton v Palace           │
│ Arsenal v Chelsea          │
╰────────────────────────────╯

NOT

╭────────────────────────────╮
│ PREMIER LEAGUE             │
│  ╭──────────────────────╮  │
│  │ Everton v Palace     │  │
│  ╰──────────────────────╯  │
╰────────────────────────────╯

Avoid the "double left border" effect.

---

# Fixture Cards

Reuse the styling from Team Details cards.

Requirements:

Dark navy gradient.

Very subtle gloss.

Large radius.

Soft shadow.

Thin border.

Do not use flat grey.

---

# Team Logos

Increase slightly.

Soft shadow.

No white boxes.

---

# Team Names

Medium weight.

White.

Readable.

---

# Kickoff Time

Muted grey.

Secondary information.

---

# Prediction Badge

Keep the existing prediction concept.

Update styling to match the Team Details cards.

Requirements:

Rounded pill

Blue-purple gradient

Soft glow

Semi-bold text

Small sparkle icon

---

# TV Information

Keep existing behaviour.

Improve spacing.

Muted icon.

Less visual weight than prediction.

---

# Competition Colours

Use restrained colour accents.

Examples:

Premier League

Purple

La Liga

Red

Bundesliga

Red

Serie A

Blue

Champions League

Royal blue

Europa League

Orange

Conference League

Green

These colours should appear only in:

- league icon
- tiny accent
- subtle glow

Never fill entire cards.

---

# League Filter Bar

Keep functionality.

Redesign visually.

Requirements:

Floating glass container.

Blur.

Rounded pill.

Soft lighting.

Icons:

Larger.

Better spacing.

Selected league:

Blue glow.

Slight enlargement.

Smooth animation.

---

# Bottom Navigation

Reuse the navigation styling from the Team Details redesign.

Selected tab:

Large blue pill.

Soft glow.

Glass appearance.

Consistent spacing.

---

# Motion

Reuse Team Details animations.

Examples:

Cards:

Fade + slide upward.

Buttons:

Spring animation.

Date changes:

Crossfade.

Keep all animations under approximately 300ms.

---

# Typography

Use exactly the same typography scale as Team Details.

Headers

Bold

Competition

Semibold

Fixture

Medium

Metadata

Regular

Muted grey

Prediction

Semibold

---

# Spacing

Follow the same spacing system as Team Details.

Use consistent spacing values throughout.

Avoid arbitrary padding.

Prefer:

- 8pt
- 12pt
- 16pt
- 24pt

---

# Colours

Exactly match Team Details.

Background:

Near black.

Cards:

Dark navy gradients.

Accent:

Top Scores blue.

Prediction:

Purple-blue.

Text:

White.

Secondary:

Muted grey.

---

# Constraints

Do not change:

- existing navigation
- fixture grouping
- prediction functionality
- TV channel support
- scrolling behaviour
- Dynamic Type support
- iPhone compatibility

The redesign should be almost entirely visual.

---

# Success Criteria

When comparing the finished Scores screen to the redesigned Team Details screen:

- They should clearly belong to the same design system.
- Cards should share the same gradients, corner radii, shadows and spacing.
- Typography should feel identical.
- Blue accents should be used consistently.
- The stadium background should create atmosphere without reducing readability.
- Competition sections should read as elegant grouped cards rather than independent floating elements.
- All left-hand alignment issues should be resolved so the layout sits on a single, consistent grid.
- The finished result should feel polished enough for a premium App Store football application.