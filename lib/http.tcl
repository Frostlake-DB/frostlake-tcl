# The HTTP/1.1 transport: one socket, held open across statements.
#
# Tcl ships an `http` package, and this does not use it. Two reasons, both
# about what a database driver needs that a general web client does not:
#
#  * A connection keeps ONE socket for its whole life. A driver that opens a
#    socket per statement burns a TCP port per statement, and a corpus run of a
#    few thousand statements will exhaust a machine's ephemeral port range and
#    start failing on connections that have nothing to do with the query. Here
#    the socket is opened once and every statement rides it.
#  * The deadline is the caller's. `-timeout` bounds the whole exchange --
#    connect, write, status line, headers and body -- rather than any one read,
#    so a server that answers a byte a minute still fails when it said it would.
#
# The channel stays non-blocking and the event loop does the waiting, which is
# how Tcl bounds an I/O wait at all. That means `vwait` runs while a statement
# is in flight, so an application with its own file events will see them fire
# there -- the same bargain the core `http` package makes.

namespace eval ::frostlake::http {
    variable SIGNAL
    array set SIGNAL {}
    variable seq 0
}

# Opens a socket to the server named by `config`, waiting no longer than its
# connectTimeout. The channel comes back non-blocking and in binary mode.
proc ::frostlake::http::connect {config} {
    set host [dict get $config host]
    set port [dict get $config port]
    set endpoint "[::frostlake::dsn::baseurl $config]"

    if {[dict get $config secure]} {
        if {[catch {package require tls} why]} {
            ::frostlake::ConnectionError "an https DSN needs the TclTLS package,\
                which is not installed: $why" [dict create endpoint $endpoint]
        }
        set command [list ::tls::socket -async -servername $host]
        if {![dict get $config verify]} {
            lappend command -require 0
        } else {
            lappend command -require 1
        }
        if {[dict get $config cacert] ne ""} {
            lappend command -cafile [dict get $config cacert]
        }
        lappend command $host $port
    } else {
        set command [list socket -async $host $port]
    }

    if {[catch {uplevel #0 $command} sock]} {
        ::frostlake::ConnectionError "cannot reach $endpoint: $sock" \
            [dict create endpoint $endpoint]
    }
    chan configure $sock -blocking 0 -translation binary -buffering full

    set outcome [Await $sock writable [dict get $config connectTimeout]]
    if {$outcome eq "timeout"} {
        catch {close $sock}
        ::frostlake::ConnectionError \
            "$endpoint did not accept a connection within\
             [Describe [dict get $config connectTimeout]]" \
            [dict create endpoint $endpoint]
    }
    # An async socket reports its failure here rather than at `socket` time.
    set why [chan configure $sock -error]
    if {$why ne ""} {
        catch {close $sock}
        ::frostlake::ConnectionError "cannot reach $endpoint: $why" \
            [dict create endpoint $endpoint]
    }
    return $sock
}

proc ::frostlake::http::disconnect {sock} {
    if {$sock eq ""} { return }
    catch {chan event $sock readable {}}
    catch {chan event $sock writable {}}
    catch {close $sock}
}

# Sends one request and reads its response.
#
# Answers a dict of `status`, `reason`, `headers` (keys folded to lower case),
# `body` (decoded from UTF-8) and `close` -- whether the server said this socket
# may not be reused.
proc ::frostlake::http::exchange {sock config method path payload} {
    set endpoint "[::frostlake::dsn::baseurl $config]$path"
    set limit [dict get $config timeout]
    # One deadline for the whole exchange, so a server dribbling a byte at a
    # time cannot outlast it by resetting a per-read timer.
    set deadline [expr {$limit > 0 ? [clock milliseconds] + $limit : 0}]

    set bytes [encoding convertto utf-8 $payload]
    set request "$method $path HTTP/1.1\r\n"
    append request "Host: [dict get $config host]:[dict get $config port]\r\n"
    append request "User-Agent: frostlake-tcl/[set ::frostlake::VERSION]\r\n"
    append request "Accept: application/json\r\n"
    append request "Connection: keep-alive\r\n"
    if {$method ne "GET"} {
        append request "Content-Type: application/json\r\n"
        append request "Content-Length: [string length $bytes]\r\n"
    }
    append request "\r\n"
    append request $bytes

    if {[catch {
        puts -nonewline $sock $request
        flush $sock
    } why]} {
        ::frostlake::ConnectionError "cannot write to $endpoint: $why" \
            [dict create endpoint $endpoint]
    }

    set status [ReadLine $sock $endpoint $deadline $limit]
    if {![regexp {^HTTP/(\d\.\d)\s+(\d{3})\s*(.*)$} $status -> version code reason]} {
        ::frostlake::ConnectionError \
            "$endpoint answered something that is not HTTP: [Snippet $status]" \
            [dict create endpoint $endpoint]
    }
    scan $code %d code

    set headers [dict create]
    while {1} {
        set line [ReadLine $sock $endpoint $deadline $limit]
        if {$line eq ""} { break }
        set colon [string first ":" $line]
        if {$colon < 0} { continue }
        # Header names are case-insensitive, and this server spells it
        # `Content-length`. Folding here is what keeps that from mattering.
        dict set headers [string tolower [string trim [string range $line 0 [expr {$colon - 1}]]]] \
                         [string trim [string range $line [expr {$colon + 1}] end]]
    }

    set closing [expr {$version eq "1.0"}]
    if {[dict exists $headers connection]} {
        set token [string tolower [dict get $headers connection]]
        set closing [expr {[string first "close" $token] >= 0}]
    }

    set body [ReadBody $sock $endpoint $deadline $limit $headers $code $method]

    return [dict create status $code reason $reason headers $headers \
                       body [encoding convertfrom utf-8 $body] close $closing]
}

proc ::frostlake::http::ReadBody {sock endpoint deadline limit headers code method} {
    # A response to HEAD, and the statuses that are defined to carry no body,
    # have none however the headers read.
    if {$method eq "HEAD" || $code == 204 || $code == 304 || ($code >= 100 && $code < 200)} {
        return ""
    }
    if {[dict exists $headers transfer-encoding]
        && [string match "*chunked*" [string tolower [dict get $headers transfer-encoding]]]} {
        return [ReadChunked $sock $endpoint $deadline $limit]
    }
    if {[dict exists $headers content-length]} {
        set length [string trim [dict get $headers content-length]]
        if {![regexp {^[0-9]+$} $length]} {
            ::frostlake::ConnectionError \
                "$endpoint sent a Content-Length that is not a number: [Snippet $length]" \
                [dict create endpoint $endpoint status $code]
        }
        scan $length %d length
        return [ReadCount $sock $endpoint $deadline $limit $length]
    }
    # No length and no chunking: the body runs to end of stream, and the socket
    # cannot be reused afterwards.
    return [ReadToEnd $sock $endpoint $deadline $limit]
}

proc ::frostlake::http::ReadChunked {sock endpoint deadline limit} {
    set body ""
    while {1} {
        set line [ReadLine $sock $endpoint $deadline $limit]
        # A chunk size may carry `;ext=value` extensions after a semicolon.
        set size [lindex [split $line ";"] 0]
        if {![regexp {^[0-9a-fA-F]+$} [string trim $size]]} {
            ::frostlake::ConnectionError \
                "$endpoint sent a chunk header that is not a size: [Snippet $line]" \
                [dict create endpoint $endpoint]
        }
        scan [string trim $size] %x size
        if {$size == 0} {
            # Trailers, then the blank line that ends them.
            while {[ReadLine $sock $endpoint $deadline $limit] ne ""} {}
            return $body
        }
        append body [ReadCount $sock $endpoint $deadline $limit $size]
        ReadLine $sock $endpoint $deadline $limit ;# the CRLF after the chunk
    }
}

# Reads one CRLF-terminated line, minus its terminator.
proc ::frostlake::http::ReadLine {sock endpoint deadline limit} {
    while {1} {
        set line [gets $sock]
        if {![chan blocked $sock]} {
            # At end of stream `gets` answers an empty string with the channel
            # NOT blocked, which used to read as an empty line and blame the
            # server for "something that is not HTTP". A real empty line still
            # carries its CR.
            if {$line eq "" && [eof $sock]} { Died $sock $endpoint }
            return [string trimright $line "\r"]
        }
        if {[eof $sock]} { Died $sock $endpoint }
        Block $sock $endpoint $deadline $limit
    }
}

proc ::frostlake::http::ReadCount {sock endpoint deadline limit count} {
    set body ""
    while {[string length $body] < $count} {
        append body [read $sock [expr {$count - [string length $body]}]]
        if {[string length $body] >= $count} { break }
        if {[eof $sock]} { Died $sock $endpoint }
        Block $sock $endpoint $deadline $limit
    }
    return $body
}

proc ::frostlake::http::ReadToEnd {sock endpoint deadline limit} {
    set body ""
    while {1} {
        append body [read $sock]
        if {[eof $sock]} { return $body }
        Block $sock $endpoint $deadline $limit
    }
}

# Waits for the socket to have more to say, or gives up on the deadline.
proc ::frostlake::http::Block {sock endpoint deadline limit} {
    set remaining 0
    if {$deadline > 0} {
        set remaining [expr {$deadline - [clock milliseconds]}]
        if {$remaining <= 0} { Expired $endpoint $limit }
    }
    if {[Await $sock readable $remaining] eq "timeout"} { Expired $endpoint $limit }
}

proc ::frostlake::http::Expired {endpoint limit} {
    ::frostlake::ConnectionError "$endpoint did not answer within [Describe $limit]" \
        [dict create endpoint $endpoint]
}

proc ::frostlake::http::Died {sock endpoint} {
    ::frostlake::ConnectionError "$endpoint closed the connection mid-response" \
        [dict create endpoint $endpoint]
}

# Waits for one channel event, or for `ms` to pass; 0 waits without a bound.
# Answers `ready` or `timeout`.
proc ::frostlake::http::Await {sock event ms} {
    variable SIGNAL
    variable seq
    set id [incr seq]
    set SIGNAL($id) ""
    # The handler disarms itself: while a nested event loop (an application
    # file event, a second connection driven from a callback) holds this vwait,
    # a still-armed readable event fires on every turn of the loop — measured
    # at thousands of times a second.
    chan event $sock $event [list ::frostlake::http::Signal $id ready $sock $event]
    set timer ""
    if {$ms > 0} {
        set timer [after $ms [list ::frostlake::http::Signal $id timeout]]
    }
    vwait ::frostlake::http::SIGNAL($id)
    set outcome $SIGNAL($id)
    unset SIGNAL($id)
    catch {chan event $sock $event {}}
    if {$timer ne ""} { after cancel $timer }
    return $outcome
}

# First signal wins: a deadline timer firing after the channel became ready
# must not turn a completed wait into a timeout that closes a live socket.
proc ::frostlake::http::Signal {id what {sock ""} {event ""}} {
    variable SIGNAL
    if {$sock ne ""} { catch {chan event $sock $event {}} }
    if {[info exists SIGNAL($id)] && $SIGNAL($id) eq ""} { set SIGNAL($id) $what }
}

proc ::frostlake::http::Describe {ms} {
    if {$ms < 1000} { return "${ms}ms" }
    if {$ms % 1000 == 0} { return "[expr {$ms / 1000}]s" }
    return [format {%.3gs} [expr {$ms / 1000.0}]]
}

proc ::frostlake::http::Snippet {text} {
    set text [string trim $text]
    if {$text eq ""} { return "(nothing)" }
    if {[string length $text] > 512} { return "[string range $text 0 511]..." }
    return $text
}
