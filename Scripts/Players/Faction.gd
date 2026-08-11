## A named grouping of UnitStats archetypes sharing a visual identity --
## Phase 11 roadmap's "team-color/material per faction, not just per team."
## Purely cosmetic/organizational: no gameplay behavior reads this at all.
## accent_color renders as a small ground-ring trim on every unit of this
## faction (Unit._build_faction_accent()), layered under the primary
## per-team body color so two units of the same team but different
## factions still read as visually distinct, and HUD._build_unit_panel()
## groups the build menu by faction instead of one flat button list.
class_name Faction
extends Resource

@export var faction_name: String = ""
@export var accent_color: Color = Color.WHITE
