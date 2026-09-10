# Parsing a DSN into everything a connection needs.
#
# Tcl has no URI parser in the core, so the grammar is spelled out here. It is a
# small one, and owning it keeps the package dependency-free.
#
# A parsed DSN is a plain dict, so it can be printed, stored and compared
# without ceremony:
#
#     host port secure database schema role warehouse
#     connectTimeout timeout idleLimit     -- milliseconds; 0 means no bound

namespace eval ::frostlake::dsn {
    namespace export parse baseurl usestatements quote duration
    namespace ensemble create
}

namespace eval ::frostlake::dsn {
    # The port a DatabaseHttpServer listens on unless told otherwise.
    variable DEFAULT_PORT 18082

    # Long enough for a slow query, short enough that an unreachable host fails
    # while someone is still watching.
    variable DEFAULT_CONNECT_TIMEOUT 10000
    variable DEFAULT_REQUEST_TIMEOUT 300000

    # The engine reclaims a session after 30 minutes idle. Past that the driver
    # has to assume its own is gone, because nothing in a response says so.
    variable DEFAULT_IDLE_LIMIT 1800000

    # Everything the DSN query string may carry. Anything else is a typo, and a
    # typo in `schema` or `timeout` changes behaviour without saying so. The
    # spellings match the other Frostlake drivers, so one DSN string works
    # across all of them.
    variable PARAMETERS {connectTimeout idleLimit role schema timeout tls warehouse}

    variable PATTERN {^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)([^?#]*)(?:\?([^#]*))?$}
}

# Parses `frostlake://host[:port][/DATABASE][?param=value&...]` into a config
# dict.
#
# `http://` and `https://` are accepted too and mean the same thing; the custom
# scheme exists so a DSN reads as a database URL rather than a web one.
proc ::frostlake::dsn::parse {text} {
    variable PATTERN
    variable PARAMETERS
    variable DEFAULT_PORT
    variable DEFAULT_CONNECT_TIMEOUT
    variable DEFAULT_REQUEST_TIMEOUT
    variable DEFAULT_IDLE_LIMIT

    if {![regexp $PATTERN $text -> scheme authority path query]} {
        ::frostlake::UsageError \
            "a DSN must start with frostlake://, http:// or https://"
    }
    set scheme [string tolower $scheme]
    if {$scheme ni {frostlake http https}} {
        ::frostlake::UsageError \
            "a DSN must start with frostlake://, http:// or https://"
    }

    # The server authenticates nobody, so credentials in a DSN would be
    # silently dropped -- and silently dropping a password is worse than saying
    # so.
    if {[string first @ $authority] >= 0} {
        ::frostlake::UsageError \
            "the server takes no credentials; remove user:password from the DSN"
    }

    lassign [SplitAuthority $authority $scheme] host port
    if {$host eq ""} {
        ::frostlake::UsageError "the DSN is missing host\[:port\]"
    }
    if {$port < 1 || $port > 65535} {
        ::frostlake::UsageError \
            "the DSN port must be between 1 and 65535, got $port"
    }

    set segments {}
    foreach segment [split $path /] {
        if {$segment ne ""} { lappend segments $segment }
    }
    if {[llength $segments] > 1} {
        ::frostlake::UsageError "the DSN path names one database, got \"$path\""
    }
    set database ""
    if {[llength $segments] == 1} {
        set database [PercentDecode [lindex $segments 0]]
    }

    set params [ParseQuery $query]
    set unknown {}
    foreach key [dict keys $params] {
        if {$key ni $PARAMETERS} { lappend unknown $key }
    }
    if {[llength $unknown]} {
        ::frostlake::UsageError "unknown DSN parameter: [join [lsort $unknown] {, }]\
            (expected [join $PARAMETERS {, }])"
    }

    set secure [expr {$scheme eq "https"}]
    if {[dict exists $params tls] && [Boolean tls [dict get $params tls]]} {
        set secure 1
    }

    return [dict create \
        host           $host \
        port           $port \
        secure         $secure \
        database       $database \
        schema         [NonEmpty schema $params] \
        role           [NonEmpty role $params] \
        warehouse      [NonEmpty warehouse $params] \
        connectTimeout [Duration connectTimeout $params $DEFAULT_CONNECT_TIMEOUT] \
        timeout        [Duration timeout $params $DEFAULT_REQUEST_TIMEOUT] \
        idleLimit      [Duration idleLimit $params $DEFAULT_IDLE_LIMIT]]
}

# The base URL of a server, without a trailing slash.
proc ::frostlake::dsn::baseurl {config} {
    set scheme [expr {[dict get $config secure] ? "https" : "http"}]
    return "$scheme://[dict get $config host]:[dict get $config port]"
}

# The DSN's scope rendered as the USE statements a fresh session needs, in
# dependency order. Rebuilt on demand, so a session that may have lapsed can be
# put back on this scope.
proc ::frostlake::dsn::usestatements {config} {
    set out {}
    foreach {key keyword} {role ROLE warehouse WAREHOUSE database DATABASE schema SCHEMA} {
        set name [dict get $config $key]
        if {$name ne ""} { lappend out "USE $keyword [quote $name]" }
    }
    return $out
}

# Quotes an identifier for use in a statement.
#
# Always quoted. Leaving "unambiguous" names bare lets through ones that cannot
# legally appear that way -- `1ABC` starts with a digit, `SELECT` is reserved --
# and quoting costs nothing: "NAME" and NAME name the same object, so only
# genuinely lower-case names are affected, and those had to be quoted anyway.
# Embedded quotes are doubled, so a name arriving from a DSN cannot break out.
proc ::frostlake::dsn::quote {name} {
    if {$name eq ""} {
        ::frostlake::UsageError "an identifier cannot be empty"
    }
    return "\"[string map [list "\"" "\"\""] $name]\""
}

# Splits `host`, `host:port` or `[v6::addr]:port`.
#
# A scheme that has a port of its own keeps it: reading the engine's default
# into `https://h` would quietly move the DSN to another port, so only the
# custom scheme -- which has no default of its own -- falls back to the
# engine's.
proc ::frostlake::dsn::SplitAuthority {authority scheme} {
    variable DEFAULT_PORT
    switch -- $scheme {
        http  { set fallback 80 }
        https { set fallback 443 }
        default { set fallback $DEFAULT_PORT }
    }
    if {[string index $authority 0] eq "\["} {
        set close [string first "\]" $authority]
        if {$close < 0} {
            ::frostlake::UsageError "the DSN has an unclosed IPv6 address"
        }
        set host [string range $authority 1 [expr {$close - 1}]]
        set rest [string range $authority [expr {$close + 1}] end]
        if {$rest eq ""} { return [list $host $fallback] }
        if {[string index $rest 0] ne ":"} {
            ::frostlake::UsageError "the DSN is missing host\[:port\]"
        }
        return [list $host [Port [string range $rest 1 end]]]
    }
    set colon [string last ":" $authority]
    if {$colon < 0} { return [list $authority $fallback] }
    return [list [string range $authority 0 [expr {$colon - 1}]] \
                 [Port [string range $authority [expr {$colon + 1}] end]]]
}

proc ::frostlake::dsn::Port {text} {
    if {![regexp {^[0-9]+$} $text]} {
        ::frostlake::UsageError "the DSN port must be a number, got \"$text\""
    }
    # Scanned rather than `expr`-ed so a leading zero cannot be read as octal.
    scan $text %d port
    return $port
}

proc ::frostlake::dsn::ParseQuery {query} {
    set out [dict create]
    foreach pair [split $query &] {
        if {$pair eq ""} { continue }
        set eq [string first = $pair]
        if {$eq < 0} {
            dict set out [PercentDecode $pair] ""
        } else {
            dict set out [PercentDecode [string range $pair 0 [expr {$eq - 1}]]] \
                         [PercentDecode [string range $pair [expr {$eq + 1}] end]]
        }
    }
    return $out
}

# Percent-decoding, over bytes: a %C3%A9 pair is one UTF-8 character in two
# escapes, so the bytes are rebuilt first and decoded as UTF-8 afterwards.
proc ::frostlake::dsn::PercentDecode {text} {
    if {![regexp {[%+]} $text]} { return $text }
    set bytes ""
    set n [string length $text]
    for {set i 0} {$i < $n} {incr i} {
        set c [string index $text $i]
        if {$c eq "%" && $i + 2 < $n
            && [regexp {^[0-9a-fA-F]{2}$} [string range $text [expr {$i + 1}] [expr {$i + 2}]] hex]} {
            append bytes [binary format H2 $hex]
            incr i 2
        } elseif {$c eq "+"} {
            append bytes " "
        } else {
            append bytes [encoding convertto utf-8 $c]
        }
    }
    return [encoding convertfrom utf-8 $bytes]
}

proc ::frostlake::dsn::NonEmpty {name params} {
    if {![dict exists $params $name]} { return "" }
    set value [dict get $params $name]
    if {$value eq ""} {
        ::frostlake::UsageError "the DSN parameter $name cannot be empty"
    }
    return $value
}

proc ::frostlake::dsn::Boolean {name value} {
    switch -- [string tolower $value] {
        true - 1 - yes { return 1 }
        false - 0 - no { return 0 }
    }
    ::frostlake::UsageError "$name must be true or false, got \"$value\""
}

proc ::frostlake::dsn::Duration {name params fallback} {
    if {![dict exists $params $name]} { return $fallback }
    return [duration $name [dict get $params $name]]
}

# Reads a duration the way a connection string writes one: a bare number of
# seconds, or a number with an `ms`/`s`/`m`/`h` suffix. Answers milliseconds,
# which is the unit every timer in Tcl takes.
#
# Zero is meaningful -- it removes the bound -- so it is accepted where a
# negative number is not.
proc ::frostlake::dsn::duration {name text} {
    set text [string trim $text]
    if {![regexp {^([0-9]+(?:\.[0-9]+)?)(ms|s|m|h)?$} $text -> amount unit]} {
        ::frostlake::UsageError \
            "$name must be a duration such as 30s, 500ms or 5m, got \"$text\""
    }
    # Scanned rather than `expr`-ed, like the port: `expr` reads a leading zero
    # as octal, which made 010ms eight milliseconds and 08 an error.
    scan $amount %f amount
    switch -- $unit {
        ms      { set factor 1 }
        m       { set factor 60000 }
        h       { set factor 3600000 }
        default { set factor 1000 }
    }
    return [expr {entier(round($amount * $factor))}]
}
