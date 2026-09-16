# Lexical helpers shared by parameter binding and session-scope tracking.
#
# Both need to walk a statement while stepping over the places where SQL syntax
# stops meaning what it says -- string literals, quoted identifiers,
# dollar-quoted bodies and comments -- so both read the same scanner and cannot
# disagree about what is inside one.
#
# Positions are character indices, which is what Tcl's string commands take.

namespace eval ::frostlake::sql {
    namespace export skipenclosure splitstatements changesscope leadingwords
    namespace ensemble create
}

namespace eval ::frostlake::sql {
    # The characters that may appear in an unquoted identifier.
    variable WORD {[A-Za-z0-9_$]}

    # Modifiers that may sit between CREATE/DROP/ALTER and the kind of object
    # being named.
    variable OBJECT_MODIFIERS {OR REPLACE TRANSIENT TEMPORARY TEMP VOLATILE
                               LOCAL GLOBAL SECURE IF NOT EXISTS}
}

proc ::frostlake::sql::IsWordChar {c} {
    variable WORD
    return [regexp $WORD $c]
}

# Whether a comment or a quoted region opens at `i`, and where it ends: the
# index just past the region, or -1 when `i` opens none. Every walk over a
# statement starts here, so none of them can forget a case.
proc ::frostlake::sql::skipenclosure {sql i} {
    set c [string index $sql $i]
    switch -- $c {
        "'"  { return [SkipString $sql $i] }
        "\"" { return [SkipQuoted $sql $i] }
        "\$" {
            if {[OpensDollarQuote $sql $i]} { return [SkipDollarQuoted $sql $i] }
            return -1
        }
        "-" {
            if {[string index $sql [expr {$i + 1}]] eq "-"} { return [SkipLine $sql $i] }
            return -1
        }
        "/" {
            switch -- [string index $sql [expr {$i + 1}]] {
                "/" { return [SkipLine $sql $i] }
                "*" { return [SkipBlockComment $sql $i] }
            }
            return -1
        }
    }
    return -1
}

# The index just past the single-quoted literal starting at `i`. Both '' and
# backslash escapes end up inside the literal -- a backslash always escapes in
# Frostlake's string dialect.
proc ::frostlake::sql::SkipString {sql i} {
    set n [string length $sql]
    set j [expr {$i + 1}]
    while {$j < $n} {
        set c [string index $sql $j]
        if {$c eq "\\"} {
            incr j 2
        } elseif {$c eq "'"} {
            if {[string index $sql [expr {$j + 1}]] eq "'"} {
                incr j 2
            } else {
                return [expr {$j + 1}]
            }
        } else {
            incr j
        }
    }
    return $j
}

# The index just past the double-quoted identifier starting at `i`.
proc ::frostlake::sql::SkipQuoted {sql i} {
    set n [string length $sql]
    set j [expr {$i + 1}]
    while {$j < $n} {
        if {[string index $sql $j] eq "\""} {
            if {[string index $sql [expr {$j + 1}]] eq "\""} {
                incr j 2
                continue
            }
            return [expr {$j + 1}]
        }
        incr j
    }
    return $j
}

# Whether the `$` at `i` opens a dollar-quoted body. A `$` is legal inside an
# unquoted identifier, so `A$$B` is a name rather than the start of a body: a
# real delimiter is never preceded by an identifier character.
proc ::frostlake::sql::OpensDollarQuote {sql i} {
    if {[string index $sql [expr {$i + 1}]] ne "\$"} { return 0 }
    if {$i == 0} { return 1 }
    return [expr {![IsWordChar [string index $sql [expr {$i - 1}]]]}]
}

# The index just past the dollar-quoted body starting at `i`. Function and
# procedure bodies are written this way, and their contents are not SQL -- a `?`
# inside one is part of the body, never a placeholder.
proc ::frostlake::sql::SkipDollarQuoted {sql i} {
    set stop [string first "\$\$" $sql [expr {$i + 2}]]
    if {$stop < 0} { return [string length $sql] }
    return [expr {$stop + 2}]
}

proc ::frostlake::sql::SkipLine {sql i} {
    set stop [string first "\n" $sql $i]
    if {$stop < 0} { return [string length $sql] }
    return [expr {$stop + 1}]
}

proc ::frostlake::sql::SkipBlockComment {sql i} {
    set stop [string first "*/" $sql [expr {$i + 2}]]
    if {$stop < 0} { return [string length $sql] }
    return [expr {$stop + 2}]
}

# Splits a request on its top-level semicolons, leaving alone any that sit
# inside a string literal, a quoted identifier, a dollar-quoted body or a
# comment.
#
# A procedural block is split along with everything else, which only makes the
# scope check below more willing to flag -- the safe direction.
proc ::frostlake::sql::splitstatements {sql} {
    set out {}
    set n [string length $sql]
    set start 0
    for {set i 0} {$i < $n} {incr i} {
        set skip [skipenclosure $sql $i]
        if {$skip >= 0} {
            set i [expr {$skip - 1}]
            continue
        }
        if {[string index $sql $i] eq ";"} {
            lappend out [string range $sql $start [expr {$i - 1}]]
            set start [expr {$i + 1}]
        }
    }
    lappend out [string range $sql $start end]
    return $out
}

# Whether a request can move the session off the scope the DSN established.
#
# A request may hold more than one statement, and a `USE` riding behind a
# leading `SELECT` moves the scope just as surely as one standing alone, so
# every statement is examined rather than only the first.
proc ::frostlake::sql::changesscope {sql} {
    foreach statement [splitstatements $sql] {
        if {[StatementChangesScope $statement]} { return 1 }
    }
    return 0
}

# Only USE, the SET family, ALTER SESSION, and CREATE/DROP of a DATABASE or
# SCHEMA move the session -- CREATE TABLE and its kind leave the scope exactly
# where it was, and counting those would mark the session dirty for every DDL
# statement a caller runs.
proc ::frostlake::sql::StatementChangesScope {statement} {
    set words [leadingwords $statement 6]
    if {![llength $words]} { return 0 }
    switch -- [lindex $words 0] {
        USE - SET - UNSET { return 1 }
        ALTER { return [NamesObject [lrange $words 1 end] {SESSION}] }
        CREATE - DROP { return [NamesObject [lrange $words 1 end] {DATABASE SCHEMA}] }
    }
    return 0
}

# Walks the words between the verb and the object being named, stepping over
# the modifiers that may sit between them -- `CREATE OR REPLACE DATABASE`,
# `DROP SCHEMA IF EXISTS` -- and reports whether the object is one of `want`.
proc ::frostlake::sql::NamesObject {words want} {
    variable OBJECT_MODIFIERS
    foreach word $words {
        if {$word in $OBJECT_MODIFIERS} { continue }
        return [expr {$word in $want}]
    }
    return 0
}

# Up to `n` words from the start of a statement, upper-cased, skipping
# whitespace and comments and stopping at the first thing that is not a word.
proc ::frostlake::sql::leadingwords {statement n} {
    set out {}
    set len [string length $statement]
    set i 0
    while {$i < $len && [llength $out] < $n} {
        set c [string index $statement $i]
        if {[string is space -strict $c]} {
            incr i
            continue
        }
        # Only comments are stepped over here: a leading string literal or
        # quoted identifier means the statement does not start with a keyword
        # at all.
        if {$c eq "-" || $c eq "/"} {
            set skip [skipenclosure $statement $i]
            if {$skip >= 0} {
                set i $skip
                continue
            }
        }
        if {![IsWordChar $c]} { return $out }
        set start $i
        while {$i < $len && [IsWordChar [string index $statement $i]]} { incr i }
        lappend out [string toupper [string range $statement $start [expr {$i - 1}]]]
    }
    return $out
}
