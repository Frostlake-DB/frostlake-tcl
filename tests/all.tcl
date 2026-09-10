# Runs the whole test suite.
#
#     tclsh tests/all.tcl                       unit tests only
#     FROSTLAKE_CLASSPATH=... tclsh tests/all.tcl    everything
#
# tcltest's own options are accepted after the script name, so
# `tests/all.tcl -file binding.test` or `-match bind-3.*` narrow a run.
#
# The files are run in one interpreter, in a deliberate order: the pure ones
# first, so a broken scanner is reported before an engine is even started, then
# the engine-backed tests.

package require tcltest 2.5
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
configure -testdir $here -singleproc 1
if {[llength $argv]} { configure {*}$argv }

source [file join $here helper.tcl]

set order {
    json.test dsn.test sql.test binding.test values.test result.test
    transport.test connection.test tdbc.test suites.test
}
set files {}
foreach name $order {
    set path [file join $here $name]
    if {[file exists $path] && [string match [configure -file] $name]} {
        lappend files $path
    }
}
# Anything added later that the list above has not heard of still runs.
foreach path [lsort [glob -nocomplain -directory $here *.test]] {
    if {$path ni $files && [string match [configure -file] [file tail $path]]} {
        lappend files $path
    }
}

# Tells `cleanupTests` to accumulate across files rather than reset and report
# each one as if it were the whole run.
set ::tcltest::testSingleFile false

set broken {}
foreach path $files {
    puts [outputChannel] "\n==== [file tail $path]"
    # Read as UTF-8 whatever the system encoding is. Several cases compare
    # against non-ASCII text, and on a Windows console the default encoding
    # would turn that text into mojibake before the comparison ever ran.
    if {[catch {source -encoding utf-8 $path} why]} {
        puts [errorChannel] "ERROR sourcing [file tail $path]: $why"
        puts [errorChannel] $::errorInfo
        lappend broken [file tail $path]
    }
}

::testserver::release

set failed [expr {$::tcltest::numTests(Failed) + [llength $broken]}]
cleanupTests 1
if {[llength $broken]} {
    puts [errorChannel] "files that did not run to the end: [join $broken {, }]"
}
exit [expr {$failed > 0}]
