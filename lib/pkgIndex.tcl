# Tcl package index for frostlake, and for tdbc::frostlake, the TDBC driver
# built on it.
#
#     lappend auto_path /path/to/frostlake-tcl/lib
#     package require frostlake          ;# the native API
#     package require tdbc::frostlake    ;# TDBC; needs the tdbc package too

if {![package vsatisfies [package provide Tcl] 8.6-]} { return }
package ifneeded frostlake 0.1.0 [list source [file join $dir frostlake.tcl]]
package ifneeded tdbc::frostlake 0.1.0 [list source [file join $dir tdbcfrostlake.tcl]]
