# Fantasy Premier League (FPL) Live Scoring Engine
Version: 2026/27
Purpose: Replicate official FPL player scoring in real time for Top Scores.

---

# Overview

Each player has a live score that is recalculated whenever a match event occurs.

The score is the sum of:

- Appearance points
- Goals
- Assists
- Clean sheet points
- Goals conceded deductions
- Goalkeeper save points
- Penalty save points
- Defensive Contribution points
- Bonus points (provisional)
- Minus deductions
- Captain multiplier (outside player score)

Only events occurring during Premier League matches count.

---

# Appearance

Minutes Played | Points
---------------|-------
1–59           | +1
60+            | +2

Important:

- 60 minutes means 60:00 excluding stoppage time.
- Once 60 minutes is reached, replace the +1 with +2.
- Never award both.

Pseudo:

if minutes == 0:
    appearance = 0
else if minutes < 60:
    appearance = 1
else:
    appearance = 2

---

# Goals

Position | Points
---------|-------
Goalkeeper | +10
Defender | +6
Midfielder | +5
Forward | +4

Each goal is scored independently.

---

# Assists

Every assist:

+3

Awarded according to official FPL assist rules.

---

# Clean Sheets

Eligible only after:

- Player has played 60+ minutes
- Team has conceded ZERO goals while player is on the pitch

Position | Points
---------|-------
Goalkeeper | +4
Defender | +4
Midfielder | +1
Forward | 0

Important behaviour:

If substituted after 65 minutes while score is still 0-0:

→ Clean sheet LOCKED.

If opponent scores afterwards:

→ Player keeps clean sheet.

If player is on pitch when opponent scores before reaching 60:

→ No clean sheet.

---

# Goals Conceded

Only goalkeepers and defenders.

Every 2 goals conceded:

Goals Conceded | Points
---------------|-------
0-1 | 0
2-3 | -1
4-5 | -2
6-7 | -3

Formula

floor(goalsConceded / 2) * -1

Only goals conceded while player is on the field count.

---

# Goalkeeper Saves

Every 3 saves:

+1

Formula:

floor(saves / 3)

Examples

Saves | Points
------|-------
0-2 | 0
3-5 | +1
6-8 | +2
9-11 | +3

---

# Penalty Saves

Each penalty saved:

+5

Does not replace normal save counting.

Penalty save also contributes towards 3-save bonus.

---

# Defensive Contributions

Defenders

10 defensive contributions

+2

Midfielders

12 defensive contributions

+2

Forwards

12 defensive contributions

+2

Goalkeepers

None.

Contribution definition follows official Opta/FPL rules.

Award once only.

---

# Penalty Miss

Each missed penalty

-2

---

# Yellow Card

Each yellow

-1

Two yellows resulting in red:

Yellow = -1

Red = -3

Total = -4

---

# Straight Red Card

-3

Can also retain yellow deduction if second yellow.

---

# Own Goal

Each own goal

-2

---

# Bonus Points

Award after match using BPS.

Highest BPS

+3

Second

+2

Third

+1

During live matches these should be marked PROVISIONAL.

Example:

⭐ +3
⭐ +2
⭐ +1

Update continuously as BPS changes.

---

# Captain

Captain score

playerPoints × 2

Triple Captain

playerPoints × 3

Vice captain only replaces absent captain after deadline.

---

# Live Match Logic

Every event triggers recalculation.

Examples:

Goal
Assist
Booking
Red card
Penalty save
Goal conceded
Substitution
Full time

Never increment score manually.

Instead:

calculatePlayerScore(player)

This guarantees consistency.

---

# Clean Sheet State Machine

Initial

No clean sheet

↓

Player reaches 60 minutes

↓

If team still has clean sheet

Award clean sheet

↓

If player remains on pitch

Opponent scores

↓

Remove clean sheet

↓

If player substituted AFTER earning clean sheet

↓

Lock clean sheet forever

---

# Defender Example

Played 90

Goal

Clean sheet

Yellow

Score

Appearance      +2
Goal            +6
Clean Sheet     +4
Yellow          -1

Total = 11

---

# Goalkeeper Example

Played 90

6 saves

Penalty save

Clean sheet

Appearance      +2
Clean sheet     +4
Saves           +2
Penalty save    +5

Total = 13

---

# Midfielder Example

Played 74

Goal

Assist

Clean sheet

Appearance      +2
Goal            +5
Assist          +3
Clean sheet     +1

Total = 11

---

# Forward Example

Played 90

2 goals

Yellow

Appearance      +2
Goals           +8
Yellow          -1

Total = 9

---

# Data Required

Each player should track:

minutesPlayed

goals

assists

goalsConcededWhileOnPitch

saves

penaltySaves

yellowCards

redCards

ownGoals

penaltiesMissed

defensiveContributions

substitutedOn

substitutedOff

currentlyOnPitch

cleanSheetLocked

provisionalBonus

position

---

# Recommended Swift Model

struct LiveFPLScore {

    var appearance:Int

    var goals:Int

    var assists:Int

    var cleanSheet:Int

    var goalsConceded:Int

    var saves:Int

    var penaltySaves:Int

    var defensiveContribution:Int

    var yellow:Int

    var red:Int

    var ownGoals:Int

    var penaltiesMissed:Int

    var bonus:Int

    var total:Int

}

---

# Important Notes

The official FPL API's event_points are NOT live.

Top Scores should instead calculate scores locally from live Opta events.

Only after FPL finalises the match should local totals be reconciled against official event_points to catch rare corrections (assist changes, own-goal reviews, bonus recalculation).