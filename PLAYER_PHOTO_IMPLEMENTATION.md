# Improve Player Hero Card

The current implementation is good, but the player image still feels like a rectangular photo placed on top of the card.

I want it to look premium and App Store quality.

## Overall style

Think:

- Apple Sports
- EA FC Ultimate Team
- Apple Wallet hero cards
- iOS 26 Liquid Glass

The player should feel integrated into the card, not pasted onto it.

---

## 1. Remove the rectangular image completely

The white/transparent rectangle around the player must disappear.

Instead:

- use a PNG cut-out with transparency
- crop around the player's shoulders/head
- no visible square edges whatsoever

The player should naturally blend into the background.

---

## 2. Circular spotlight

Behind the player create a large circular spotlight.

Requirements:

- centred behind the head
- diameter roughly 70% of card height
- very subtle blue radial gradient
- thin electric-blue outline
- 10-15% opacity glow

This becomes the visual focal point.

---

## 3. Hero crop

Do NOT display the full portrait.

Instead crop from approximately:

- mid chest
- upwards

Scale the player larger.

The head should almost reach the top padding of the card.

Shoulders should extend slightly beyond the bottom edge.

Think magazine cover rather than passport photo.

---

## 4. Soft edge lighting

Apply a very subtle glow around the outside silhouette.

Not a neon outline.

Instead:

- faint blue rim light
- slight bloom
- soft shadow behind player

This helps separate the player from the background.

---

## 5. Layering

Background

↓

Circular spotlight

↓

Player cut-out

↓

Very soft foreground shadow

This gives genuine depth.

---

## 6. Background improvements

Current background is too flat.

Instead use:

- dark navy gradient
- large abstract circular shapes
- subtle arcs
- blurred rings
- barely-visible geometric pattern

Very low contrast.

Nothing should distract from the player.

---

## 7. Better positioning

Move the player further right.

Current layout wastes space.

Aim for:

40% text

60% player

The player should almost touch the right edge.

---

## 8. Better typography spacing

Increase vertical spacing between:

POSITION

↓

Player Name

↓

Club

Use more breathing room.

---

## 9. Club row

Instead of just text:

[Club Badge]   Paris SG

Use a monochrome badge if coloured assets are unavailable.

Smaller.

More refined.

---

## 10. Position label

Current label is fine but could improve.

Make it:

- uppercase
- slightly smaller
- tighter tracking
- brighter blue

Think premium sports broadcast graphics.

---

## 11. Card depth

Increase depth using:

- stronger top highlight
- subtle bottom shadow
- inner border
- glass-style reflections

Do NOT increase opacity.

Keep it elegant.

---

## 12. Animation (optional)

On presentation:

- player fades in
- scales from 0.96 → 1.0
- spotlight fades in
- slight parallax when scrolling

Duration ~0.35s.

---

## Overall goal

The first thing the eye should notice is the player.

Currently the eye notices the card.

The player should become the hero.

The finished result should resemble an Apple keynote screenshot rather than a standard football app.