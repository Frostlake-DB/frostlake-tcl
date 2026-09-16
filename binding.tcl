# Client-side parameter binding.
#
# The HTTP protocol has no server-side binding, so parameters are inlined here
# with the same rules Frostlake's JDBC driver uses. The scan that finds bind
# sites is shared by counting and substitution, so the two cannot disagree about
# what is a placeholder.

namespace eval ::frostlake::bind {
    namespace export sites count names positional named
    namespace ensemble create
}

# Every bind site in a statement, as a list of `{start stop name}` triples:
# `start` is the index of the marker's first character, `stop` the index just
# past it, and `name` the parameter's name upper-cased -- empty for a positional
# `?`, which no name can be.
#
# String literals, quoted identifiers, dollar-quoted bodies and comments are
# stepped over.
proc ::frostlake::bind::sites {sql} {
    set out {}
    set n [string length $sql]
    for {set i 0} {$i < $n} {incr i} {
        set skip [::frostlake::sql::skipenclosure $sql $i]
        if {$skip >= 0} {
            set i [expr {$skip - 1}]
            continue
        }
        set c [string index $sql $i]
        if {$c eq "?"} {
            lappend out [list $i [expr {$i + 1}] ""]
            continue
        }
        if {$c ne ":"} { continue }

        # `::` is a cast and `:=` an assignment; neither introduces a parameter.
        set next [string index $sql [expr {$i + 1}]]
        if {$next eq ":" || $next eq "="} {
            incr i
            continue
        }
        # A colon ADJACENT to the end of an expression -- an identifier
        # character, a closing paren, bracket or brace, a double or single
        # quote -- is VARIANT path access (v:field, PARSE_JSON('...'):k,
        # OBJECT_CONSTRUCT(...):a, "V":k), not a parameter: a bind marker
        # follows an operator, comma or keyword boundary instead.
        if {$i > 0} {
            set prev [string index $sql [expr {$i - 1}]]
            if {[regexp {[A-Za-z0-9_$)\]\}"']} $prev]} { continue }
        }
        set j [expr {$i + 1}]
        while {$j < $n && [regexp {[A-Za-z0-9_$]} [string index $sql $j]]} { incr j }
        # A leading digit means a positional reference (`:1`), not a name.
        if {$j > $i + 1 && ![string match {[0-9]} [string index $sql [expr {$i + 1}]]]} {
            lappend out [list $i $j \
                [string toupper [string range $sql [expr {$i + 1}] [expr {$j - 1}]]]]
            set i [expr {$j - 1}]
        }
    }
    return $out
}

# How many arguments a statement expects. Named placeholders count once each
# however often they appear. A statement mixing the two styles reports -1, so a
# caller checking the count leaves the real complaint to the substitution.
proc ::frostlake::bind::count {sql} {
    set positional 0
    set seen {}
    foreach site [sites $sql] {
        set name [lindex $site 2]
        if {$name eq ""} {
            incr positional
        } elseif {$name ni $seen} {
            lappend seen $name
        }
    }
    if {$positional > 0 && [llength $seen] > 0} { return -1 }
    if {[llength $seen]} { return [llength $seen] }
    return $positional
}

# The parameter names a statement carries, upper-cased, in order of first
# appearance.
proc ::frostlake::bind::names {sql} {
    set out {}
    foreach site [sites $sql] {
        set name [lindex $site 2]
        if {$name ne "" && $name ni $out} { lappend out $name }
    }
    return $out
}

# Inlines positional `?` placeholders. The argument count has to match in both
# directions: a placeholder left without an argument is an error, never a
# silently bound NULL.
proc ::frostlake::bind::positional {sql params types null} {
    set sites [sites $sql]
    set named 0
    foreach site $sites {
        if {[lindex $site 2] ne ""} { incr named }
    }
    if {$named > 0 && $named != [llength $sites]} {
        ::frostlake::UsageError \
            "a statement may use ? or :name placeholders, not both"
    }
    if {$named > 0} {
        # With no arguments at all, the colon references are the SERVER's --
        # Scripting variables (`EXECUTE IMMEDIATE :v`, `IFF(:flag, ...)`) -- and
        # the statement passes through verbatim. Named client binds exist only
        # when named arguments are supplied.
        if {![llength $params]} { return $sql }
        ::frostlake::UsageError "the statement uses :name placeholders;\
            pass a dict of named parameters instead of a list"
    }
    # Symmetrically, with no arguments at all the `?` marks are the SERVER's --
    # a Scripting cursor placeholder bound by `OPEN c USING (...)` -- and the
    # statement passes through verbatim.
    if {![llength $params]} { return $sql }
    if {[llength $sites] != [llength $params]} {
        ::frostlake::UsageError "the statement has [llength $sites] placeholder(s),\
            got [llength $params] argument(s)"
    }
    set types [Spread $types [llength $params]]
    set literals {}
    foreach value $params type $types {
        lappend literals [::frostlake::value::literal $value $type $null]
    }
    return [Render $sql $sites $literals]
}

# Inlines `:name` placeholders. Names match case-insensitively and their order
# does not matter. An argument that no placeholder mentions is an error rather
# than a silent no-op -- it almost always means the name was misspelled on one
# side or the other.
proc ::frostlake::bind::named {sql params types null} {
    set sites [sites $sql]
    set positional 0
    foreach site $sites {
        if {[lindex $site 2] eq ""} { incr positional }
    }
    if {$positional > 0 && $positional != [llength $sites]} {
        ::frostlake::UsageError \
            "a statement may use ? or :name placeholders, not both"
    }
    if {$positional > 0} {
        ::frostlake::UsageError "the statement uses positional ? placeholders;\
            pass a list of parameters instead of a dict"
    }

    if {[llength $params] % 2} {
        ::frostlake::UsageError "the statement uses :name placeholders, so its\
            parameters are a dict of name/value pairs; got [llength $params]\
            element(s), which cannot pair up"
    }
    set values [dict create]
    dict for {key value} $params {
        dict set values [string toupper $key] $value
    }
    if {![llength $sites]} {
        if {![dict size $values]} { return $sql }
        ::frostlake::UsageError "the statement has no placeholders,\
            got [dict size $values] named argument(s)"
    }

    # A single bare word applies to every name; otherwise `-types` is a dict
    # keyed the same way the parameters are.
    set bytype [dict create]
    if {[llength $types] == 1} {
        foreach key [dict keys $values] { dict set bytype $key [lindex $types 0] }
    } else {
        dict for {key type} $types { dict set bytype [string toupper $key] $type }
    }

    set used {}
    set literals {}
    foreach site $sites {
        set name [lindex $site 2]
        if {![dict exists $values $name]} {
            ::frostlake::UsageError "no argument bound for :[string tolower $name]"
        }
        if {$name ni $used} { lappend used $name }
        set type string
        if {[dict exists $bytype $name]} { set type [dict get $bytype $name] }
        lappend literals [::frostlake::value::literal [dict get $values $name] $type $null]
    }

    set unused {}
    foreach key [dict keys $values] {
        if {$key ni $used} { lappend unused ":[string tolower $key]" }
    }
    if {[llength $unused]} {
        ::frostlake::UsageError "argument(s) [join [lsort $unused] {, }]\
            do not appear in the statement"
    }
    return [Render $sql $sites $literals]
}

# Spreads a `-types` list over `n` bind sites: nothing means every one is a
# string, one word applies to them all, and a full list lines up one to one.
proc ::frostlake::bind::Spread {types n} {
    switch -- [llength $types] {
        0 { set types [lrepeat $n string] }
        1 { set types [lrepeat $n [lindex $types 0]] }
    }
    if {[llength $types] != $n} {
        ::frostlake::UsageError "-types has [llength $types] entr(ies) for $n\
            placeholder(s); give one type per placeholder, or one for all"
    }
    return $types
}

# Rebuilds the statement with each bind site replaced by its literal.
proc ::frostlake::bind::Render {sql sites literals} {
    set out ""
    set cursor 0
    foreach site $sites literal $literals {
        lassign $site start stop
        if {$start > $cursor} {
            append out [string range $sql $cursor [expr {$start - 1}]]
        }
        append out $literal
        set cursor $stop
    }
    append out [string range $sql $cursor end]
    return $out
}
