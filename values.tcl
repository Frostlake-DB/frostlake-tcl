# Rendering Tcl values as SQL literals, and reading the engine's cells back.
#
# ------------------------------------------------------------------- writing
#
# The HTTP protocol has no server-side binding, so a bound parameter is inlined
# as a literal here. Tcl has no types to read the intent from -- 42, "42" and
# the result of `expr {6*7}` are one and the same string -- so every bind is
# rendered as a *string literal* unless the caller names another type.
#
# That default is the only one that cannot silently change a value. The engine
# coerces freely in expressions, so `WHERE id = '42'` finds the row with id 42
# and `'42' + 1` is 43; but a bare 007 is the number seven, and storing it in a
# VARCHAR gives back "7", not "007". Quoting is therefore right for data, and
# the `-types` option covers the places where SQL syntax demands a real
# numeric literal:
#
#     $conn execute {SELECT * FROM t LIMIT ?} 5 -types number
#
# ------------------------------------------------------------------- reading
#
# Almost nothing happens on the way back, and that is deliberate. The engine
# renders temporals, binary and semi-structured values as text and numbers as
# bare JSON numbers, and Tcl's every value is a string -- so the text the engine
# sent IS the Tcl value, exactly, with no conversion to lose digits or offsets
# on the way. `parsetimestamp` and `hextobinary` below are there for callers who
# want a converted form; the driver never applies them behind the caller's back.

namespace eval ::frostlake::value {
    namespace export literal identifier types \
        basetype istemporal isbinary parsetimestamp formattimestamp \
        hextobinary binarytohex
    namespace ensemble create
}

namespace eval ::frostlake::value {
    # The type names `-types` accepts.
    variable TYPES {string number boolean null binary raw
                    date time timestamp timestampntz timestamptz variant}

    variable RE_NUMBER {^[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?$}
}

# The type names a bind may be given.
proc ::frostlake::value::types {} {
    variable TYPES
    return $TYPES
}

# Renders one bound value as the SQL literal that stands in for it.
#
# `null` is the connection's stand-in for SQL NULL: a value equal to it becomes
# NULL whatever type was asked for, which is what makes the same string mean
# NULL in both directions.
proc ::frostlake::value::literal {value {type string} {null ""}} {
    variable TYPES
    variable RE_NUMBER

    if {$type ni $TYPES} {
        ::frostlake::UsageError \
            "unknown bind type \"$type\" (expected [join $TYPES {, }])"
    }
    if {$value eq $null} { return "NULL" }

    switch -- $type {
        null { return "NULL" }
        string { return [String $value] }
        number {
            if {![regexp $RE_NUMBER $value]} {
                ::frostlake::UsageError \
                    "a number bind needs a number, got \"$value\""
            }
            # A negative numeral goes in parentheses: spliced straight after a
            # minus it would otherwise open a `--` comment, so `SELECT 3-?`
            # bound -5 became `SELECT 3--5`, which the engine reads as SELECT 3.
            if {[string index $value 0] eq "-"} { return "($value)" }
            return $value
        }
        boolean {
            if {![string is boolean -strict $value]} {
                ::frostlake::UsageError \
                    "a boolean bind needs true or false, got \"$value\""
            }
            return [expr {$value ? "TRUE" : "FALSE"}]
        }
        binary {
            # A Tcl byte array, rendered the way the engine writes BINARY.
            return "X'[binarytohex $value]'"
        }
        raw {
            # Inserted verbatim. The caller owns whatever it says -- this is the
            # one bind that can carry SQL syntax, and so the one that can carry
            # an injection. It exists because the alternative, callers splicing
            # text into the statement themselves, is strictly worse.
            return $value
        }
        date         { return "[String $value]::DATE" }
        time         { return "[String $value]::TIME" }
        timestamp -
        timestampntz { return "[String $value]::TIMESTAMP_NTZ" }
        timestamptz {
            # The engine prints an offset as +0100 but parses only +01:00, so a
            # value read straight back out of a result is repaired on the way
            # in rather than rejected.
            return "[String [ColonizeOffset $value]]::TIMESTAMP_TZ"
        }
        variant { return "PARSE_JSON([String $value])" }
    }
}

# Mirrors the engine's canonical literal encoder: backslashes doubled (a
# backslash always escapes), quotes doubled.
proc ::frostlake::value::String {text} {
    return "'[string map [list "\\" "\\\\" "'" "''"] $text]'"
}

# Puts the colon back into a `+0100`-style offset, leaving `+01:00` and `Z`
# alone.
proc ::frostlake::value::ColonizeOffset {text} {
    # Anchored to a time of day, so a date's own hyphens are left alone:
    # `15-01-2024` used to come out as `15-01-20:24`.
    if {[regexp {^(.*\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?\s*[-+])([0-9]{2})([0-9]{2})$} $text -> head hours minutes]} {
        return "$head$hours:$minutes"
    }
    return $text
}

# Quotes an identifier -- a table, column or schema name assembled at runtime --
# so it can be spliced into a statement safely. Embedded quotes are doubled.
proc ::frostlake::value::identifier {name} {
    return [::frostlake::dsn::quote $name]
}

# ---------------------------------------------------------------- type names

# Strips any `(p,s)` suffix, so `NUMBER(38,0)` and `NUMBER` answer alike.
proc ::frostlake::value::basetype {datatype} {
    set name [string toupper [string trim $datatype]]
    set open [string first "(" $name]
    if {$open < 0} { return $name }
    return [string trim [string range $name 0 [expr {$open - 1}]]]
}

# Which temporal shape a declared type names: date, time, naive, zoned, or the
# empty string for anything that is not temporal.
proc ::frostlake::value::istemporal {datatype} {
    switch -- [basetype $datatype] {
        DATE { return date }
        TIME { return time }
        TIMESTAMP - TIMESTAMP_NTZ - DATETIME { return naive }
        TIMESTAMP_LTZ - TIMESTAMP_TZ { return zoned }
    }
    return ""
}

proc ::frostlake::value::isbinary {datatype} {
    return [expr {[basetype $datatype] in {BINARY VARBINARY}}]
}

# ---------------------------------------------------------------- conversions

# Reads a temporal cell as a dict: `seconds` since the epoch, `nanos` for the
# fraction the second does not carry, and `offset` in seconds east of UTC (0
# for a value that named none).
#
# Offered rather than applied: `clock scan` cannot hold a sub-second fraction
# and would round a TIMESTAMP_NTZ(9) off, so the driver hands back the engine's
# own text and lets a caller who wants an instant ask for one.
proc ::frostlake::value::parsetimestamp {text} {
    set text [string trim $text]
    set pattern {^([0-9]{4,})-([0-9]{2})-([0-9]{2})(?:[ T]([0-9]{1,2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?)?}
    append pattern {\s*(Z|[-+][0-9]{2}:?[0-9]{2})?$}
    if {![regexp $pattern $text -> year month day hour minute second fraction zone]} {
        # A bare TIME, which carries no date at all.
        if {![regexp {^([0-9]{1,2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?$} \
                  $text -> hour minute second fraction]} {
            ::frostlake::UsageError "cannot read \"$text\" as a date or time"
        }
        set seconds [expr {$hour * 3600 + $minute * 60 + $second}]
        return [dict create seconds $seconds nanos [Nanos $fraction] offset 0]
    }
    if {$hour eq ""} { set hour 0; set minute 0; set second 0 }
    set stamp [clock scan [format {%04d-%02d-%02d %02d:%02d:%02d} \
                    $year $month $day $hour $minute $second] \
                    -gmt 1 -format {%Y-%m-%d %H:%M:%S}]
    set offset [OffsetSeconds $zone]
    return [dict create seconds [expr {$stamp - $offset}] \
                        nanos [Nanos $fraction] offset $offset]
}

proc ::frostlake::value::Nanos {fraction} {
    if {$fraction eq ""} { return 0 }
    set padded [string range "${fraction}000000000" 0 8]
    scan $padded %d nanos
    return $nanos
}

proc ::frostlake::value::OffsetSeconds {zone} {
    if {$zone eq "" || $zone eq "Z"} { return 0 }
    regexp {^([-+])([0-9]{2}):?([0-9]{2})$} $zone -> sign hours minutes
    scan $hours %d h
    scan $minutes %d m
    set total [expr {$h * 3600 + $m * 60}]
    return [expr {$sign eq "-" ? -$total : $total}]
}

# Renders an instant the way a TIMESTAMP literal is written. `offset` is
# seconds east of UTC; a non-zero one produces the `+HH:MM` form the engine
# parses.
proc ::frostlake::value::formattimestamp {seconds {nanos 0} {offset 0}} {
    set local [expr {$seconds + $offset}]
    set text [clock format $local -gmt 1 -format {%Y-%m-%d %H:%M:%S}]
    if {$nanos != 0} {
        append text [string trimright [format {.%09d} $nanos] 0]
    }
    if {$offset != 0} {
        set sign [expr {$offset < 0 ? "-" : "+"}]
        set total [expr {abs($offset)}]
        append text [format { %s%02d:%02d} $sign \
                         [expr {$total / 3600}] [expr {($total % 3600) / 60}]]
    }
    return $text
}

# Decodes the hex text the engine renders BINARY as into a Tcl byte array.
proc ::frostlake::value::hextobinary {text} {
    if {![regexp {^(?:[0-9a-fA-F]{2})*$} $text]} {
        ::frostlake::UsageError "\"$text\" is not an even run of hex digits"
    }
    return [binary format H* $text]
}

# The inverse: a Tcl byte array as the upper-case hex the engine expects.
proc ::frostlake::value::binarytohex {bytes} {
    binary scan $bytes H* hex
    return [string toupper $hex]
}
