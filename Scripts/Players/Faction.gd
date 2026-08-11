## A named grouping of UnitStats archetypes sharing a visual identity --
## Phase 11 roadmap's "team-color/material per faction, not just per team."
## Also now the basis for race selection (Player.faction): the lobby lets
## a human player pick one of FactionRegistry.ALL, or leave it to
## FactionRegistry.random_pick(); HUD.refresh_unit_panel_for_faction()
## then gates the build menu to only that faction's units. accent_color
## renders as a small ground-ring trim on every unit of this faction
## (Unit._build_faction_accent()), layered under the primary per-team
## body color so two units of the same team but different factions still
## read as visually distinct, and HUD._build_unit_panel() groups the
## build menu by faction instead of one flat button list.
##
## The registry of every concrete Faction .tres (FactionRegistry.gd)
## deliberately does NOT live as a const on this class -- a script's own
## top-level preload() of .tres resources that are themselves instances
## of that same script creates a circular load (this class isn't done
## registering by the time a HumanFaction.tres claiming
## script_class="Faction" needs to be validated against it), which
## silently degraded every preloaded entry to plain Resource instead of
## Faction at runtime -- confirmed the hard way ("Invalid assignment of
## property... value of type 'Resource'" on Player.faction, and
## "Invalid access to property... faction_name on a base object of type
## 'Resource'" reading what should have been a Faction). See
## FactionRegistry.gd's own doc comment.
class_name Faction
extends Resource

@export var faction_name: String = ""
@export var accent_color: Color = Color.WHITE
