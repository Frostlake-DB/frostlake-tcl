# An in-process HTTP server, for the transport cases a real engine cannot be
# talked into producing on demand: a chunked body, a `Connection: close`, a
# reply that is not JSON, a server that never answers at all.
#
# It shares the interpreter with the driver under test. That works because the
# driver waits in the event loop rather than blocking a socket, so the server's
# file events fire while a statement is in flight -- which is also a useful
# check that the driver really does leave the event loop running.

namespace eval fakeserver {
    variable servers
    array set servers {}
    variable seq 0
}

# Starts a server on a free loopback port and answers with whatever `handler`
# returns. The handler is a command prefix called as
#
#     {*}$handler method path headers body
#
# and returns a dict, any key of which may be left out:
#
#     status   3-digit code                       (default 200)
#     reason   the text after the code            (default OK)
#     headers  a dict of extra response headers   (default none)
#     body     the body, as a Tcl string          (default {})
#     chunked  1 to send it in chunked encoding   (default 0)
#     close    1 to close the socket afterwards   (default 0)
#     silent   1 to answer nothing at all         (default 0)
#     raw      bytes to send instead of a response, verbatim
#
# Answers a token to pass to `stop`, and `port` reads its port.
proc fakeserver::start {handler} {
    variable servers
    variable seq
    set id [incr seq]
    set listener [socket -server [list ::fakeserver::Accept $id] -myaddr 127.0.0.1 0]
    set servers($id) [dict create \
        listener $listener \
        port [lindex [chan configure $listener -sockname] 2] \
        handler $handler \
        requests 0 \
        connections 0]
    return $id
}

proc fakeserver::port {id} {
    variable servers
    return [dict get $servers($id) port]
}

proc fakeserver::dsn {id} {
    return "frostlake://127.0.0.1:[port $id]"
}

# How many requests this server has answered, and over how many sockets. The
# second is what says whether the driver is really reusing its connection.
proc fakeserver::stats {id} {
    variable servers
    return [dict create requests [dict get $servers($id) requests] \
                       connections [dict get $servers($id) connections]]
}

proc fakeserver::stop {id} {
    variable servers
    if {![info exists servers($id)]} { return }
    catch {close [dict get $servers($id) listener]}
    unset servers($id)
}

proc fakeserver::Accept {id sock host port} {
    variable servers
    if {![info exists servers($id)]} {
        catch {close $sock}
        return
    }
    dict incr servers($id) connections
    # Blocking is safe here: the client always writes a whole request before it
    # waits for the answer, so a read can never leave this handler stuck.
    chan configure $sock -translation binary -blocking 1 -buffering full
    chan event $sock readable [list ::fakeserver::Serve $id $sock]
}

proc fakeserver::Serve {id sock} {
    variable servers
    if {![info exists servers($id)] || [eof $sock]} {
        catch {chan event $sock readable {}}
        catch {close $sock}
        return
    }
    if {[catch {ReadRequest $sock} request] || $request eq ""} {
        catch {chan event $sock readable {}}
        catch {close $sock}
        return
    }
    dict incr servers($id) requests

    lassign $request method path headers body
    set answer [{*}[dict get $servers($id) handler] $method $path $headers $body]

    if {[Field $answer silent 0]} { return }
    if {[dict exists $answer raw]} {
        puts -nonewline $sock [dict get $answer raw]
        flush $sock
        catch {chan event $sock readable {}}
        catch {close $sock}
        return
    }

    set bytes [encoding convertto utf-8 [Field $answer body ""]]
    set closing [Field $answer close 0]
    set out "HTTP/1.1 [Field $answer status 200] [Field $answer reason OK]\r\n"
    append out "Content-Type: application/json\r\n"
    if {[Field $answer chunked 0]} {
        append out "Transfer-Encoding: chunked\r\n"
    } else {
        append out "Content-Length: [string length $bytes]\r\n"
    }
    if {$closing} { append out "Connection: close\r\n" }
    dict for {name value} [Field $answer headers {}] {
        append out "$name: $value\r\n"
    }
    append out "\r\n"
    if {[Field $answer chunked 0]} {
        # Split across two chunks, so the reader has to actually reassemble.
        set half [expr {[string length $bytes] / 2}]
        foreach piece [list [string range $bytes 0 [expr {$half - 1}]] \
                            [string range $bytes $half end]] {
            if {$piece eq ""} continue
            append out [format %x [string length $piece]]
            append out "\r\n$piece\r\n"
        }
        append out "0\r\n\r\n"
    } else {
        append out $bytes
    }
    puts -nonewline $sock $out
    flush $sock
    if {$closing} {
        catch {chan event $sock readable {}}
        catch {close $sock}
    }
}

proc fakeserver::ReadRequest {sock} {
    set line [string trimright [gets $sock] "\r"]
    if {$line eq "" && [eof $sock]} { return "" }
    lassign [split $line " "] method path version
    set headers [dict create]
    while {1} {
        set line [string trimright [gets $sock] "\r"]
        if {$line eq ""} break
        set colon [string first ":" $line]
        if {$colon < 0} continue
        dict set headers [string tolower [string trim [string range $line 0 [expr {$colon - 1}]]]] \
                         [string trim [string range $line [expr {$colon + 1}] end]]
    }
    set body ""
    if {[dict exists $headers content-length]} {
        set length [dict get $headers content-length]
        while {[string length $body] < $length} {
            set chunk [read $sock [expr {$length - [string length $body]}]]
            if {$chunk eq ""} break
            append body $chunk
        }
    }
    return [list $method $path $headers [encoding convertfrom utf-8 $body]]
}

proc fakeserver::Field {dict key default} {
    if {[dict exists $dict $key]} { return [dict get $dict $key] }
    return $default
}

# The answers a real engine gives, for handlers that only care about one of
# them.
proc fakeserver::healthy {} {
    return {{"status":"healthy","activeSessions":0}}
}

proc fakeserver::ok {{resultSets {[]}} {session s-1}} {
    return "{\"errorMessage\":null,\"executionTimeMs\":1,\"resultSets\":$resultSets,\"sessionId\":\"$session\",\"success\":true}"
}

proc fakeserver::failed {message} {
    return "{\"errorMessage\":[::frostlake::json::encode_string $message],\"executionTimeMs\":0,\"resultSets\":\[\],\"sessionId\":null,\"success\":false}"
}
