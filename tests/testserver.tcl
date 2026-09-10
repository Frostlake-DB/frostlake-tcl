# A real DatabaseHttpServer, booted from an engine classpath for the tests that
# need one.
#
# Nothing here is mocked: every statement the integration tests run travels the
# driver's own HTTP path to a live engine. Without FROSTLAKE_CLASSPATH there is
# no server, and the tests that need one skip themselves rather than passing on
# a stub -- a green suite that never reached an engine would be worse than a
# skipped one.

namespace eval testserver {
    variable running ""
}

# The engine classpath the tests were given, or "" when they were given none.
proc testserver::classpath {} {
    if {[info exists ::env(FROSTLAKE_CLASSPATH)]} { return $::env(FROSTLAKE_CLASSPATH) }
    return ""
}

# Why the engine-backed tests cannot run, or "" when they can.
proc testserver::skipreason {} {
    if {[classpath] eq ""} {
        return "FROSTLAKE_CLASSPATH is not set, so no engine can be started"
    }
    return ""
}

proc testserver::available {} {
    return [expr {[skipreason] eq ""}]
}

proc testserver::java {} {
    if {[info exists ::env(JAVA_HOME)] && $::env(JAVA_HOME) ne ""} {
        set candidate [file join $::env(JAVA_HOME) bin \
            [expr {$::tcl_platform(platform) eq "windows" ? "java.exe" : "java"}]]
        if {[file executable $candidate]} { return $candidate }
    }
    return java
}

# Boots a server on a free port and waits for it to answer.
#
# The engine keeps its catalog under ~/.frostlake_engine and its internal stages
# under ~/.frostlake_stages, so consecutive runs would otherwise inherit each
# other's warehouses and stages. Both are pointed at a directory of this run's
# own, which is what makes a run repeatable.
proc testserver::start {} {
    set cp [classpath]
    if {$cp eq ""} { error "FROSTLAKE_CLASSPATH is not set" }

    # Bind port 0 to have the OS name a free one, then hand it straight to the
    # engine. A race is possible in principle and has never been the problem in
    # practice; a fixed port collides with a developer's own server.
    set probe [socket -server {apply {{args} {}}} -myaddr 127.0.0.1 0]
    set port [lindex [chan configure $probe -sockname] 2]
    close $probe

    set home [file join [TempDir] "frostlake-tcl-$port"]
    file mkdir [file join $home data]
    set log [file join $home server.log]

    set command [list [java] -Duser.home=[file nativename $home] \
                     -cp $cp dev.frostlake.http.DatabaseHttpServer $port]
    set previous ""
    if {[info exists ::env(SQL_ENGINE_DATA_DIR)]} { set previous $::env(SQL_ENGINE_DATA_DIR) }
    set ::env(SQL_ENGINE_DATA_DIR) [file nativename [file join $home data]]
    # A real log file, not a null sink: the log is what says why a boot failed.
    # Started from the private home: the engine writes db-engine.log into its
    # cwd, which used to be the test directory (tcltest then reported it as a
    # file left behind).
    set cwd [pwd]
    cd $home
    try {
        set pid [exec {*}$command >& $log &]
    } finally {
        cd $cwd
    }
    if {$previous eq ""} { unset ::env(SQL_ENGINE_DATA_DIR) } else { set ::env(SQL_ENGINE_DATA_DIR) $previous }

    set server [dict create pid $pid port $port log $log home $home \
                            dsn "frostlake://127.0.0.1:$port"]
    if {![WaitUntilHealthy $port]} {
        stop $server
        error "the engine did not answer /api/health within 60s; see $log"
    }
    return $server
}

proc testserver::TempDir {} {
    foreach name {TMPDIR TEMP TMP} {
        if {[info exists ::env($name)] && [file isdirectory $::env($name)]} {
            return $::env($name)
        }
    }
    return [pwd]
}

proc testserver::WaitUntilHealthy {port {seconds 60}} {
    set deadline [expr {[clock seconds] + $seconds}]
    while {[clock seconds] < $deadline} {
        if {![catch {socket 127.0.0.1 $port} probe]} {
            # The port is listening; ask it whether it is really an engine.
            catch {close $probe}
            if {![catch {
                set conn [::frostlake::connect "frostlake://127.0.0.1:$port" -connecttimeout 5s]
                $conn close
            }]} { return 1 }
        }
        after 200
    }
    return 0
}

proc testserver::stop {server} {
    if {$server eq ""} { return }
    catch {exec [KillCommand] {*}[KillArguments [dict get $server pid]]}
    return
}

proc testserver::KillCommand {} {
    if {$::tcl_platform(platform) eq "windows"} { return taskkill }
    return kill
}

proc testserver::KillArguments {pid} {
    if {$::tcl_platform(platform) eq "windows"} { return [list /F /T /PID $pid] }
    return [list -9 $pid]
}

# One server for a whole test file, started on demand and stopped at the end.
proc testserver::shared {} {
    variable running
    if {$running eq ""} { set running [start] }
    return $running
}

proc testserver::release {} {
    variable running
    if {$running ne ""} {
        stop $running
        set running ""
    }
}
