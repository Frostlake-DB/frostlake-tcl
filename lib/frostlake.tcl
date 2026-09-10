# A Tcl driver for Frostlake, speaking the engine's HTTP protocol against a
# running DatabaseHttpServer.
#
#     lappend auto_path /path/to/frostlake-tcl/lib
#     package require frostlake
#
#     set conn [frostlake::connect frostlake://localhost:18082/MY_DB?schema=PUBLIC]
#     $conn execute {CREATE TABLE people (id INTEGER, name VARCHAR)}
#     $conn execute {INSERT INTO people VALUES (?, ?)} {1 Ada}
#     set res [$conn execute {SELECT name FROM people WHERE id = ?} {1}]
#     frostlake::result value $res            ;# Ada
#     $conn close
#
# Nothing outside the Tcl core is needed: the JSON reader, the DSN parser, the
# SQL scanner and the HTTP client are all in this directory. TclTLS is required
# only for an `https://` DSN.
#
# The pieces, in dependency order:
#
#   errors      the three failure kinds, and the -errorcode they carry
#   json        a JSON reader that keeps every number's digits and every
#               value's type
#   dsn         frostlake://host:port/DB?params -> a config dict
#   sql         the scanner both binding and scope-tracking read
#   values      Tcl values -> SQL literals, and the engine's text back again
#   binding     ? and :name placeholders, inlined client-side
#   result      what a statement answered with, as a plain dict
#   http        one keep-alive socket, with the caller's deadline on it
#   connection  the object that owns a socket and an engine session

package require Tcl 8.6
package require TclOO

namespace eval ::frostlake {
    variable VERSION 0.1.0

    # `connect` is the only name worth importing; everything else is reached
    # through its own namespace, so `namespace import ::frostlake::*` cannot
    # quietly take over a script's own `result` or `value`.
    namespace export connect
}

apply {{directory} {
    foreach part {errors json dsn sql values binding result http connection} {
        source [file join $directory $part.tcl]
    }
}} [file dirname [file normalize [info script]]]

package provide frostlake $::frostlake::VERSION
