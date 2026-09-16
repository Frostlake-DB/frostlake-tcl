# What a statement answered with.
#
# A result is a plain Tcl dict, not an object. Nothing about a result needs a
# lifetime -- it is a value -- and a value can be stored in a variable, passed
# to a proc, put in a list and compared without anyone remembering to destroy
# it. `dict get` is the whole reading API:
#
#     set res [$conn execute {SELECT id, name FROM people}]
#     dict get $res rows        ;# {{1 Ada} {2 Grace}}
#     dict get $res columns     ;# a list of column dicts
#
# | key           | what it holds                                             |
# | ------------- | --------------------------------------------------------- |
# | `columns`     | one dict per column: name, datatype, nullable, precision, scale, length |
# | `rows`        | a list of rows, each a list of cells aligned with `columns` |
# | `updatecount` | rows affected by DML, or -1 when the statement returned data |
# | `counters`    | the raw `number of rows ...` counters behind `updatecount` |
#
# The `frostlake::result` ensemble below covers what `dict get` cannot: the
# first cell, rows keyed by column name, looking a column up by name.

namespace eval ::frostlake::result {
    namespace export new value rows names columns column columnindex \
        cell dicts rowcount updatecount isupdate counters
    namespace ensemble create
}

proc ::frostlake::result::new {columns rows {updatecount -1} {counters {}}} {
    return [dict create columns $columns rows $rows \
                        updatecount $updatecount counters $counters]
}

# The first cell of the first row, or the empty string when there is none --
# what a single-value query (`SELECT COUNT(*)`, `SELECT CURRENT_VERSION()`) is
# after.
proc ::frostlake::result::value {result} {
    set rows [dict get $result rows]
    if {![llength $rows]} { return "" }
    return [lindex $rows 0 0]
}

# Every row, each a list of cells positionally aligned with the columns.
proc ::frostlake::result::rows {result} {
    return [dict get $result rows]
}

# The column names, in order.
proc ::frostlake::result::names {result} {
    set out {}
    foreach column [dict get $result columns] { lappend out [dict get $column name] }
    return $out
}

# One dict per column: name, datatype, nullable, precision, scale, length.
#
# `length` is the declared width of a text or binary column -- characters for
# VARCHAR, bytes for BINARY -- and "" for every other type, which has none.
proc ::frostlake::result::columns {result} {
    return [dict get $result columns]
}

# One column's metadata, found by name or by position.
proc ::frostlake::result::column {result which} {
    set i [columnindex $result $which]
    if {$i < 0} {
        ::frostlake::UsageError "this result has no column \"$which\""
    }
    return [lindex [dict get $result columns] $i]
}

# The position of a column, matched exactly first and case-insensitively after,
# or -1 when the result has no such column. An integer that indexes a column is
# taken as the position it is.
proc ::frostlake::result::columnindex {result which} {
    set columns [dict get $result columns]
    if {[string is integer -strict $which]} {
        if {$which >= 0 && $which < [llength $columns]} { return $which }
        return -1
    }
    set i 0
    foreach column $columns {
        if {[dict get $column name] eq $which} { return $i }
        incr i
    }
    set folded [string toupper $which]
    set i 0
    foreach column $columns {
        if {[string toupper [dict get $column name]] eq $folded} { return $i }
        incr i
    }
    return -1
}

# One cell, by row number and column name or position.
proc ::frostlake::result::cell {result row which} {
    set i [columnindex $result $which]
    if {$i < 0} {
        ::frostlake::UsageError "this result has no column \"$which\""
    }
    return [lindex [dict get $result rows] $row $i]
}

# Each row keyed by column name, ready for `dict get $row NAME`.
#
# `rows` stays the lossless view: a dict cannot hold two columns of the same
# name, so a self-join that reports ID twice keeps only the later one here.
proc ::frostlake::result::dicts {result} {
    set names [names $result]
    set out {}
    foreach row [dict get $result rows] {
        set entry [dict create]
        foreach name $names cell $row { dict set entry $name $cell }
        lappend out $entry
    }
    return $out
}

# Rows returned, or rows affected for a DML statement.
proc ::frostlake::result::rowcount {result} {
    set count [dict get $result updatecount]
    if {$count >= 0} { return $count }
    return [llength [dict get $result rows]]
}

# Rows affected by DML, or -1 when the statement returned data.
proc ::frostlake::result::updatecount {result} {
    return [dict get $result updatecount]
}

# Whether this result came from a DML statement rather than a query.
proc ::frostlake::result::isupdate {result} {
    return [expr {[dict get $result updatecount] >= 0}]
}

# The raw `number of rows inserted`-style counters the engine reported, keyed by
# the name it gave each one.
proc ::frostlake::result::counters {result} {
    return [dict get $result counters]
}
