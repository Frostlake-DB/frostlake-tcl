# Shared setup for the test files: load the package under test, the fake
# server, and the real-engine launcher.

package require tcltest 2.5

namespace eval helper {
    variable root [file dirname [file dirname [file normalize [info script]]]]
}

if {![namespace exists ::frostlake] || ![llength [info commands ::frostlake::connect]]} {
    lappend auto_path [file join $helper::root lib]
    package require frostlake
}

foreach part {fakeserver testserver} {
    if {![namespace exists ::$part]} {
        source [file join $helper::root tests $part.tcl]
    }
}

namespace eval helper {
    # The message of the last error, with newlines flattened so a result
    # comparison reads on one line.
    proc flatten {text} {
        return [string map [list \n " " \r ""] $text]
    }
}
