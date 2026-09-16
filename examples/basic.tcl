#!/usr/bin/env tclsh
#
# A tour of the driver against a running engine.
#
#     tclsh examples/basic.tcl ?dsn?
#
# Start an engine first:
#
#     java -cp 'path/to/engine/lib/*' dev.frostlake.http.DatabaseHttpServer 18082

lappend auto_path [file dirname [file dirname [file normalize [info script]]]]
package require frostlake

set dsn frostlake://localhost:18082
if {[llength $argv]} { set dsn [lindex $argv 0] }

proc heading {text} { puts "\n=== $text" }

set conn [frostlake::connect $dsn]
puts "connected to [$conn baseurl]"

heading "a scope of our own"
$conn execute {CREATE OR REPLACE DATABASE example_db}
# The engine names a session on its first statement, not at connect time.
puts "session [$conn sessionid]"
$conn execute {USE DATABASE example_db}
$conn execute {CREATE OR REPLACE SCHEMA example_schema}
$conn execute {USE SCHEMA example_schema}
puts "now in [frostlake::result value [$conn execute {SELECT CURRENT_DATABASE()}]]"

heading "insert, with parameters"
$conn execute {CREATE TABLE people (id INTEGER, name VARCHAR, joined DATE)}
foreach {id name joined} {1 Ada 1843-01-01 2 {Grace O'Hara} 1959-06-01 3 Alan 1936-05-28} {
    set res [$conn execute {INSERT INTO people VALUES (?, ?, ?)} \
                 [list $id $name $joined] -types {number string date}]
    puts "inserted [frostlake::result updatecount $res] row for $name"
}

heading "reading a grid"
set res [$conn execute {SELECT id, name, joined FROM people ORDER BY id}]
puts "columns: [frostlake::result names $res]"
foreach row [dict get $res rows] {
    lassign $row id name joined
    puts [format {  %-3s %-14s %s} $id $name $joined]
}
puts "rows: [frostlake::result rowcount $res]"

heading "named parameters"
set res [$conn execute {SELECT name FROM people WHERE id = :who} {who 2}]
puts "id 2 is [frostlake::result value $res]"

heading "a row as a dict"
puts [lindex [frostlake::result dicts $res] 0]

heading "exact numbers, at any width"
set big [frostlake::result value [$conn execute {SELECT 12345678901234567890123456789}]]
puts "$big + 1 = [expr {$big + 1}]"

heading "NULL, and the stand-in for it"
set marked [frostlake::connect $dsn -nullvalue "(null)"]
puts "default:  <[frostlake::result value [$conn execute {SELECT NULL}]]>"
puts "sentinel: <[frostlake::result value [$marked execute {SELECT NULL}]]>"
$marked close

heading "a transaction that sticks"
$conn transaction {
    $conn execute {INSERT INTO people VALUES (?, ?, ?)} \
        [list 4 Katherine 1953-01-01] -types {number string date}
}
puts "people: [frostlake::result value [$conn execute {SELECT COUNT(*) FROM people}]]"

heading "and one that does not"
catch {
    $conn transaction {
        $conn execute {INSERT INTO people VALUES (?, ?, ?)} \
            [list 5 Nobody 1900-01-01] -types {number string date}
        error "changed my mind"
    }
} why
puts "rolled back after: $why"
puts "people: [frostlake::result value [$conn execute {SELECT COUNT(*) FROM people}]]"

heading "what a bind actually produced"
puts [$conn render {SELECT * FROM people WHERE name = ?} [list "O'Reilly"]]

heading "when the engine says no"
try {
    $conn execute {SELECT * FROM no_such_table}
} trap {FROSTLAKE QUERY} {message options} {
    puts "QUERY: [string map [list \n { }] $message]"
    puts "  statement: [dict get [frostlake::detail [dict get $options -errorcode]] statement]"
}

heading "when the driver refuses to send"
try {
    $conn execute {SELECT ?, ?} {only-one}
} trap {FROSTLAKE USAGE} {message} {
    puts "USAGE: $message"
}

$conn execute {DROP DATABASE IF EXISTS example_db}
$conn close
puts "\ndone."
