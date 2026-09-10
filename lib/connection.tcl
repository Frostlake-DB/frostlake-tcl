# A connection to a Frostlake HTTP server, and the engine session behind it.
#
# The connection is the one thing in this package that is an object rather than
# a value: it owns a socket and a server-side session, so it has a lifetime, and
# a lifetime is what `oo::class` is for. Results, configs and rows are all plain
# values.
#
# Statements are serialized over the one session, which is what makes session
# state -- USE, session variables, an open transaction -- carry from one
# statement to the next.

namespace eval ::frostlake {}

oo::class create ::frostlake::Connection {
    # The parsed DSN plus the options given at connect time.
    variable config
    # The keep-alive socket, or "" when there is none open just now.
    variable sock
    # The engine's id for this session, once it has answered with one.
    variable sessionid
    variable autocommit
    variable closed
    # USE statements still owed to the session, in dependency order.
    variable pendingUse
    # The scope the DSN named, kept so a lapsed session can be put back on it.
    variable sessionDefaults
    # `clock milliseconds` when this connection last had an answer, or "".
    variable lastUsed
    # Whether the caller has selected a scope themselves; if they have, the
    # DSN's defaults are no longer the whole truth about this session.
    variable sessionTouched
    # The two-way stand-in for SQL NULL.
    variable nullvalue
    # Guards against a statement started from inside another one's event wait.
    variable busy

    constructor {dsn options} {
        # Everything the destructor reads is set before anything that can
        # throw. TclOO destroys an object whose constructor failed, so a DSN
        # rejected on its first line still runs the destructor -- which would
        # otherwise be reading variables that were never created.
        set sock ""
        set sessionid ""
        set autocommit 1
        set closed 0
        set lastUsed ""
        set sessionTouched 0
        set busy 0
        set nullvalue ""
        set config {}
        set sessionDefaults {}
        set pendingUse {}

        set config [::frostlake::dsn::parse $dsn]
        dict set config verify 1
        dict set config cacert ""

        if {[llength $options] % 2} {
            ::frostlake::UsageError "option \"[lindex $options end]\" has no value"
        }
        foreach {option value} $options {
            switch -exact -- $option {
                -timeout        { dict set config timeout [::frostlake::dsn::duration timeout $value] }
                -connecttimeout { dict set config connectTimeout [::frostlake::dsn::duration connectTimeout $value] }
                -idlelimit      { dict set config idleLimit [::frostlake::dsn::duration idleLimit $value] }
                -database       { dict set config database $value }
                -schema         { dict set config schema $value }
                -role           { dict set config role $value }
                -warehouse      { dict set config warehouse $value }
                -nullvalue      { set nullvalue $value }
                -cacert         { dict set config cacert $value }
                -verify {
                    if {![string is boolean -strict $value]} {
                        ::frostlake::UsageError "-verify takes a boolean, got \"$value\""
                    }
                    dict set config verify [expr {!!$value}]
                }
                default {
                    ::frostlake::UsageError "unknown option \"$option\" (expected\
                        -timeout, -connecttimeout, -idlelimit, -database, -schema,\
                        -role, -warehouse, -nullvalue, -cacert or -verify)"
                }
            }
        }
        if {!([dict get $config secure]) && ([dict get $config cacert] ne "" || ![dict get $config verify])} {
            ::frostlake::UsageError "-cacert and -verify apply to https DSNs only"
        }

        set sessionDefaults [::frostlake::dsn::usestatements $config]
        set pendingUse $sessionDefaults

        # The server is contacted before the constructor returns: its health
        # endpoint is called, and the scope the DSN names is selected. A
        # database that does not exist is therefore reported here, rather than
        # surfacing later on whichever query happened to run first.
        try {
            my ping
            my applyscope
        } on error {message options} {
            my Release
            return -options $options $message
        }
    }

    destructor {
        my Release
    }

    # Releases the socket. The HTTP API has no endpoint for ending a session, so
    # the engine's own idle sweep is what reclaims the session behind it.
    method Release {} {
        set closed 1
        if {[info exists sock]} { ::frostlake::http::disconnect $sock }
        set sock ""
    }

    # Closes the connection and removes its command, the way `sqlite3` handles
    # a database handle.
    method close {} {
        my destroy
    }

    method Check {} {
        if {$closed} { ::frostlake::UsageError "the connection is closed" }
    }

    # Claims the connection for one caller.
    #
    # A connection carries one session, and the transport waits in the event
    # loop -- so an application with its own file events can reach `execute`
    # again while a statement is still in flight. Two half-interleaved
    # statements on one session would corrupt exactly the state a session
    # exists to keep, so the second is refused rather than half-done.
    method Enter {} {
        my Check
        if {$busy} {
            ::frostlake::UsageError "this connection is already running a\
                statement; a connection carries one session and cannot\
                interleave two"
        }
        set busy 1
    }

    method Leave {} {
        set busy 0
    }

    # ------------------------------------------------------------- reporting

    # The engine's id for this connection's session, once it has one.
    method sessionid {} { return $sessionid }

    # Whether a transaction is open -- `begin` without a matching `commit` or
    # `rollback`.
    method intransaction {} { return [expr {!$autocommit}] }

    # The server this connection speaks to, as scheme://host:port.
    method baseurl {} { return [::frostlake::dsn::baseurl $config] }

    # The parsed DSN, as a dict.
    method config {} { return $config }

    # How long one statement may take, in milliseconds; 0 means no bound.
    # Given a duration -- `30s`, `500ms`, a bare number of seconds -- it moves
    # the bound first, the way `-timeout` sets it at connect time.
    method timeout {{duration ""}} {
        if {$duration ne ""} {
            dict set config timeout [::frostlake::dsn::duration timeout $duration]
        }
        return [dict get $config timeout]
    }

    # The stand-in this connection uses for SQL NULL, in both directions.
    method nullvalue {} { return $nullvalue }

    method isopen {} { return [expr {!$closed}] }

    # ------------------------------------------------------------- statements

    # Runs one statement and returns its first result set.
    #
    #     $conn execute {INSERT INTO people VALUES (?, ?)} {1 Ada}
    #     $conn execute {SELECT :a + :b AS total} {a 2 b 40}
    #     $conn execute {SELECT * FROM t LIMIT ?} 5 -types number
    #
    # Whether `params` is read as a list of positional arguments or a dict of
    # named ones is decided by the STATEMENT, not by the argument: `?` markers
    # take a list, `:name` markers take a dict. In Tcl those are the same value,
    # so letting the statement decide is the only reading that cannot be
    # ambiguous.
    method execute {sql args} {
        return [lindex [my executeall $sql {*}$args] 0]
    }

    # Runs a statement string and returns every result set it produced, in
    # order. A single statement gives a one-element list.
    method executeall {sql args} {
        lassign [my ParseArguments $args] params types
        set rendered [my Render $sql $params $types]
        return [my Run $sql $rendered]
    }

    # Renders a statement with its parameters inlined, without sending it.
    # Useful for logging, and for seeing what a bind actually produced.
    #
    # WARNING: the result holds bound values verbatim -- a password bound into
    # a statement appears in it in the clear.
    method render {sql args} {
        lassign [my ParseArguments $args] params types
        return [my Render $sql $params $types]
    }

    method Render {sql params types} {
        # Rendered even with no parameters, so a `?` left without an argument is
        # reported rather than sent to the engine as a literal question mark.
        # With no arguments at all both marker styles belong to the SERVER --
        # Scripting variables and cursor placeholders -- and the statement
        # passes through untouched; that pass-through lives in `positional`.
        if {![llength $params]} {
            return [::frostlake::bind::positional $sql {} $types $nullvalue]
        }
        if {[llength [::frostlake::bind::names $sql]] > 0} {
            return [::frostlake::bind::named $sql $params $types $nullvalue]
        }
        return [::frostlake::bind::positional $sql $params $types $nullvalue]
    }

    # `sql ?params? ?-types list?`. Parameters come first; an argument starting
    # with a dash is read as an option, so a parameter list whose first element
    # begins with one is introduced by `--`.
    method ParseArguments {argv} {
        set params {}
        set types {}
        if {[llength $argv]} {
            if {[lindex $argv 0] eq "--"} {
                set params [lindex $argv 1]
                set argv [lrange $argv 2 end]
            } elseif {[string index [lindex $argv 0] 0] ne "-"} {
                set params [lindex $argv 0]
                set argv [lrange $argv 1 end]
            }
        }
        if {[llength $argv] % 2} {
            ::frostlake::UsageError "option \"[lindex $argv end]\" has no value"
        }
        foreach {option value} $argv {
            switch -exact -- $option {
                -types { set types $value }
                default {
                    ::frostlake::UsageError \
                        "unknown option \"$option\" (expected -types)"
                }
            }
        }
        return [list $params $types]
    }

    # The pending USE statements and the statement itself reach the session as
    # one unit: no other caller may slip a query in between them.
    method Run {sql rendered} {
        my Enter
        try {
            my RestoreSessionDefaults
            my DrainPendingUse
            set answer [my RoundTrip $rendered]
            if {[::frostlake::sql::changesscope $sql]} { set sessionTouched 1 }
            return [my Shape $answer]
        } finally {
            my Leave
        }
    }

    # Each USE leaves the queue only once it has succeeded. A DSN naming a
    # database that does not exist has to keep failing; the alternative is later
    # statements quietly running in the default scope.
    method DrainPendingUse {} {
        while {[llength $pendingUse]} {
            my RoundTrip [lindex $pendingUse 0]
            set pendingUse [lrange $pendingUse 1 end]
        }
    }

    # Selects the database, schema, role and warehouse the DSN names. The
    # constructor calls this, so it is only worth calling again after the
    # session has been moved somewhere else deliberately.
    method applyscope {} {
        my Enter
        try {
            if {![llength $sessionDefaults]} { return }
            # Re-queue the whole scope: the constructor drained the queue
            # already, so without this a second call sent nothing and reported
            # success.
            set pendingUse $sessionDefaults
            set sessionTouched 0
            my DrainPendingUse
        } finally {
            my Leave
        }
        return
    }

    # The engine reclaims a session once it has been idle long enough, then
    # quietly builds a fresh one for the id we keep sending -- losing the scope
    # we selected. Nothing in the reply gives it away: the id we sent is echoed
    # back either way. So past the limit the only safe reading is that the
    # session is new, and the DSN's defaults go back on.
    #
    # Not once the caller has selected a scope themselves: putting our defaults
    # over their choice is its own surprise.
    method RestoreSessionDefaults {} {
        if {![llength $sessionDefaults] || $sessionTouched} { return }
        set limit [dict get $config idleLimit]
        if {$limit == 0 || $lastUsed eq ""} { return }
        if {[clock milliseconds] - $lastUsed < $limit} { return }
        set pendingUse $sessionDefaults
    }

    # ----------------------------------------------------------- transactions

    # Opens a transaction: autocommit goes off and BEGIN is sent.
    method begin {} {
        my Enter
        set autocommit 0
        try {
            my RoundTrip "BEGIN"
        } on error {message options} {
            set autocommit 1
            return -options $options $message
        } finally {
            my Leave
        }
        return
    }

    # Commits the open transaction and restores autocommit.
    method commit {} {
        my Enter
        try {
            my RoundTrip "COMMIT"
        } finally {
            set autocommit 1
            my Leave
        }
        return
    }

    # Rolls the open transaction back and restores autocommit.
    method rollback {} {
        my Enter
        try {
            my RoundTrip "ROLLBACK"
        } finally {
            set autocommit 1
            my Leave
        }
        return
    }

    # Runs `script` in the caller's scope between BEGIN and COMMIT, rolling back
    # if it fails and re-raising the original error either way.
    #
    #     $conn transaction {
    #         $conn execute {INSERT INTO acc VALUES (1)}
    #     }
    #
    # The connection is NOT held for the duration: a transaction lives on the
    # session, so anything else run on this same connection meanwhile joins the
    # transaction. Give a transaction its own connection if that is not what you
    # want.
    method transaction {script} {
        my begin
        # catch, not try/on error: a script that finishes with `return`,
        # `break` or `continue` completes with a code that is not an error and
        # is not ok either, and `try` let it fly past the commit -- leaving the
        # transaction open on the session with every later statement inside it.
        # Only an error (code 1) rolls back; everything else commits, and the
        # script's own completion code is then handed back to the caller.
        set code [catch {uplevel 1 $script} result options]
        if {$code == 1} {
            # A failed rollback must not replace the error that caused it.
            catch {my rollback}
            return -options $options $result
        }
        my commit
        if {$code == 0} { return $result }
        # A `return`, `break` or `continue` in the script belongs to the
        # caller, so it gets one more level to unwind. Re-raised as caught, it
        # stopped at this method: a `break` was "invoked outside of a loop",
        # and a `return` left the transaction instead of the caller.
        dict incr options -level
        return -options $options $result
    }

    # ------------------------------------------------------------- transport

    # Checks that a Frostlake engine is answering, via GET /api/health.
    #
    # A 200 on its own only says something is listening -- anything can serve
    # that. The health payload is what says it is an engine, so a body that is
    # not one is reported rather than passed off as healthy.
    method ping {} {
        my Enter
        try {
            my Health
        } finally {
            my Leave
        }
        return
    }

    method Health {} {
        set endpoint "[my baseurl]/api/health"
        set answer [my Send GET /api/health ""]
        if {[dict get $answer status] != 200} {
            ::frostlake::ConnectionError \
                "$endpoint answered HTTP [dict get $answer status]:\
                 [::frostlake::http::Snippet [dict get $answer body]]" \
                [dict create endpoint $endpoint status [dict get $answer status]]
        }
        set health [my Decode $endpoint $answer]
        if {![::frostlake::json::exists $health status]} {
            ::frostlake::ConnectionError \
                "$endpoint answered HTTP [dict get $answer status] with a body that is\
                 not a Frostlake response: [::frostlake::http::Snippet [dict get $answer body]]" \
                [dict create endpoint $endpoint status [dict get $answer status]]
        }
        return
    }

    method RoundTrip {sql} {
        set endpoint "[my baseurl]/api/execute"
        set payload "\{\"sql\":[::frostlake::json::encode_string $sql]"
        if {$sessionid ne ""} {
            append payload ",\"sessionId\":[::frostlake::json::encode_string $sessionid]"
        }
        append payload ",\"autoCommit\":[expr {$autocommit ? {true} : {false}}]\}"

        set answer [my Send POST /api/execute $payload]
        set decoded [my Decode $endpoint $answer]

        # On a failure the engine answers with sessionId null, so the id is
        # taken only when it is really there -- otherwise one bad statement
        # would drop the session and silently start a new one.
        set session [::frostlake::json::at $decoded sessionId]
        if {[::frostlake::json::type $session] eq "string"
            && [::frostlake::json::value $session] ne ""} {
            set sessionid [::frostlake::json::value $session]
        }

        set success [::frostlake::json::at $decoded success]
        if {!([::frostlake::json::type $success] eq "bool"
              && [::frostlake::json::value $success])} {
            ::frostlake::QueryError \
                [my FailureMessage $decoded $answer] \
                [dict create statement $sql status [dict get $answer status]]
        }
        set lastUsed [clock milliseconds]
        return $decoded
    }

    # Sends one request, opening the socket if this connection has none and
    # replacing it if the server has closed the one it had.
    method Send {method path payload} {
        my Check
        if {[my SocketIsStale]} {
            ::frostlake::http::disconnect $sock
            set sock ""
            set sock [::frostlake::http::connect $config]
        }
        try {
            set answer [::frostlake::http::exchange $sock $config $method $path $payload]
        } on error {message options} {
            # The statement's fate is unknown -- it may have run before the
            # connection broke -- so the socket goes, but nothing is re-sent.
            ::frostlake::http::disconnect $sock
            set sock ""
            return -options $options $message
        }
        if {[dict get $answer close]} {
            ::frostlake::http::disconnect $sock
            set sock ""
        }
        return $answer
    }

    # Whether the socket cannot carry another request.
    #
    # Between exchanges there is nothing left to read -- the body was read to
    # its stated length -- so anything readable now is either the close the
    # server did while we were idle, or a desynchronised stream. Either way the
    # socket is replaced, and it is replaced BEFORE the statement is written,
    # which is what keeps this from ever re-sending one that may have run.
    method SocketIsStale {} {
        if {$sock eq ""} { return 1 }
        if {[catch {read $sock} leftover]} { return 1 }
        if {$leftover ne ""} { return 1 }
        return [eof $sock]
    }

    # Reads a response body as the JSON object a Frostlake answer is.
    #
    # A proxy error page, the wrong port, a crashed server: report what came
    # back rather than where the JSON parser gave up, which is the difference
    # between "malformed JSON at offset 0" and a message naming the address that
    # answered.
    method Decode {endpoint answer} {
        set body [dict get $answer body]
        if {![catch {::frostlake::json::parse $body} decoded]
            && [::frostlake::json::type $decoded] eq "object"} {
            return $decoded
        }
        ::frostlake::ConnectionError \
            "$endpoint answered HTTP [dict get $answer status] with a body that is\
             not a Frostlake response: [::frostlake::http::Snippet $body]" \
            [dict create endpoint $endpoint status [dict get $answer status]]
    }

    # Never answers the empty string: a response can report failure carrying no
    # message at all, and an error that prints as nothing tells the caller less
    # than the status code would.
    method FailureMessage {decoded answer} {
        foreach key {errorMessage error} {
            set field [::frostlake::json::at $decoded $key]
            if {[::frostlake::json::type $field] eq "string"
                && [::frostlake::json::value $field] ne ""} {
                return [::frostlake::json::value $field]
            }
        }
        return "the statement failed with HTTP [dict get $answer status] and no\
                error message: [::frostlake::http::Snippet [dict get $answer body]]"
    }

    # ----------------------------------------------------------- result shape

    method Shape {decoded} {
        set sets [::frostlake::json::at $decoded resultSets]
        set out {}
        if {[::frostlake::json::type $sets] eq "array"} {
            foreach entry [::frostlake::json::value $sets] {
                if {[::frostlake::json::type $entry] eq "object"} {
                    lappend out [my ShapeOne $entry]
                }
            }
        }
        # A statement that returned no grid at all -- DDL, a bare USE -- still
        # answers with one result, so that `execute` always has one to hand
        # back.
        if {![llength $out]} { return [list [::frostlake::result::new {} {}]] }
        return $out
    }

    method ShapeOne {entry} {
        set columns {}
        set raw [::frostlake::json::at $entry columns]
        if {[::frostlake::json::type $raw] eq "array"} {
            foreach column [::frostlake::json::value $raw] {
                if {[::frostlake::json::type $column] ne "object"} { continue }
                lappend columns [dict create \
                    name      [my Text $column name] \
                    datatype  [my Text $column dataType] \
                    nullable  [my Flag $column nullable] \
                    precision [my Number $column precision] \
                    scale     [my Number $column scale]]
            }
        }

        set rows {}
        set raw [::frostlake::json::at $entry rows]
        if {[::frostlake::json::type $raw] eq "array"} {
            foreach row [::frostlake::json::value $raw] {
                if {[::frostlake::json::type $row] ne "array"} { continue }
                set cells {}
                foreach cell [::frostlake::json::value $row] {
                    lappend cells [::frostlake::json::scalar $cell $nullvalue]
                }
                # A row the server sent short of the column count is padded, so
                # every row lines up with `columns` positionally.
                while {[llength $cells] < [llength $columns]} { lappend cells $nullvalue }
                lappend rows $cells
            }
        }

        # The protocol carries no statement type, so a DML answer is recognised
        # by its shape: a single row whose every column is a "number of ..."
        # counter. INSERT and DELETE report one, UPDATE adds "number of
        # multi-joined rows updated", and MERGE reports an inserted and an
        # updated count.
        if {[llength $rows] == 1 && [llength $columns] > 0} {
            set allCounters 1
            foreach column $columns {
                if {![string match "number of *" [string tolower [dict get $column name]]]} {
                    set allCounters 0
                    break
                }
            }
            if {$allCounters} {
                set counters [dict create]
                set affected 0
                set i 0
                foreach column $columns {
                    set text [lindex $rows 0 $i]
                    incr i
                    # Spelled the way JSON spells an integer -- no leading
                    # zeros -- because `incr` reads 010 as octal, and a
                    # counter is worth nothing if it is silently eight.
                    if {![regexp {^-?(?:0|[1-9][0-9]*)$} $text]} { continue }
                    set name [dict get $column name]
                    dict set counters $name $text
                    # "number of multi-joined rows updated" is a diagnostic
                    # sub-count of rows already counted as updated, so only the
                    # "number of rows ..." counters are summed.
                    if {[string match "number of rows *" [string tolower $name]]} {
                        incr affected $text
                    }
                }
                # The grid itself is kept rather than folded away: a statement
                # whose answer merely LOOKS like a status grid is
                # indistinguishable from one that is, and hiding its rows would
                # lose the only copy of them.
                return [::frostlake::result::new $columns $rows $affected $counters]
            }
        }
        return [::frostlake::result::new $columns $rows]
    }

    method Text {object key} {
        set field [::frostlake::json::at $object $key]
        if {[::frostlake::json::type $field] eq "string"} {
            return [::frostlake::json::value $field]
        }
        return ""
    }

    # A boolean field, or "" when the server did not say -- an engine that
    # predates a field reports nothing rather than false.
    method Flag {object key} {
        set field [::frostlake::json::at $object $key]
        if {[::frostlake::json::type $field] eq "bool"} {
            return [::frostlake::json::value $field]
        }
        return ""
    }

    method Number {object key} {
        set field [::frostlake::json::at $object $key]
        if {[::frostlake::json::type $field] eq "number"} {
            return [::frostlake::json::value $field]
        }
        return ""
    }
}

# Opens a connection to a Frostlake HTTP server.
#
#     set conn [frostlake::connect frostlake://localhost:18082/MY_DB?schema=PUBLIC]
#
# Every option may also be given in the DSN query string, where an explicit
# option outranks it. Durations are written the way a DSN writes them -- `30s`,
# `500ms`, `5m`, or a bare number of seconds -- and 0 removes the bound.
#
# | option            | meaning                                                   |
# | ----------------- | --------------------------------------------------------- |
# | `-timeout`        | how long one statement may take                            |
# | `-connecttimeout` | how long to wait for the socket                            |
# | `-idlelimit`      | how long a connection may idle before its scope is re-applied |
# | `-nullvalue`      | the stand-in for SQL NULL, in both directions (default "") |
# | `-database` `-schema` `-role` `-warehouse` | the session's scope       |
# | `-cacert`         | a CA bundle for HTTPS, instead of the system's             |
# | `-verify`         | 0 to accept any HTTPS certificate                          |
proc ::frostlake::connect {dsn args} {
    return [::frostlake::Connection new $dsn $args]
}
