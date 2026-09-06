# TinyTrust S1-D -- metal density fill over the whole die.
#
# WHY THIS EXISTS
# The signoff DRC deck reported 22 violations on the first routed chip, and
# every one was a *minimum* density rule -- 19 windows where Metal2 plus its
# filler covers less than 25% of an 800 x 800 um area, plus global Metal2,
# GatPoly and Activ density. Foundries require a density floor as well as a
# ceiling: chemical-mechanical polishing dishes out large empty regions and
# ruins planarity across the wafer.
#
# The cause is in ORFS's own density_fill step, which calls
#
#     density_fill -rules $::env(FILL_CONFIG)
#
# with no -area argument. OpenROAD then defaults to the *core* area. On this
# chip the core box is inset 351 um from the die edge on every side to make
# room for the pad ring, so that moat -- roughly a third of the die -- gets no
# fill at all. Hence the empty windows.
#
# This hook runs the same fill again across the full die area. It is additive:
# the shapes already placed inside the core stay, and the moat gets the same
# treatment.
#
# Wired in through POST_DENSITY_FILL_TCL, so ORFS runs it straight after its
# own fill step with the routed design already loaded.

set block [ord::get_db_block]
set die   [$block getDieArea]

set dbu [[$block getDataBase] getDbUnitsPerMicron]

set llx [expr {[$die xMin] * 1.0 / $dbu}]
set lly [expr {[$die yMin] * 1.0 / $dbu}]
set urx [expr {[$die xMax] * 1.0 / $dbu}]
set ury [expr {[$die yMax] * 1.0 / $dbu}]

puts "TinyTrust: filling the full die area $llx $lly $urx $ury (ORFS filled the core box only)"

density_fill -rules $::env(FILL_CONFIG) -area [list $llx $lly $urx $ury]
