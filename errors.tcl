# The failures this driver raises.
#
# Tcl's machine-readable channel for a failure is `-errorcode`, and `try ...
# trap` matches it by leading elements, so the split below is the one a caller
# actually branches on:
#
#     try {
#         $conn execute $sql
#     } trap {FROSTLAKE QUERY} {message} {
#         # the engine refused the statement
#     } trap {FROSTLAKE CONNECTION} {message} {
#         # the request never became an answer
#     } trap {FROSTLAKE} {message} {
#         # anything else this driver raised
#     }
#
# `trap {FROSTLAKE}` catches all three, so a caller who does not care which
# kind it was writes one clause.
#
# Each code carries a third element: a dict of whatever detail the failure had
# to hand. Read it with `lindex $::errorCode 2`, or from the options dict a
# `trap` body's second variable receives.

namespace eval ::frostlake {}

# The driver was asked for something impossible and sent nothing: a malformed
# DSN, a closed connection, a bind value with no SQL spelling, a placeholder
# left without an argument.
proc ::frostlake::UsageError {message} {
    return -code error -errorcode [list FROSTLAKE USAGE {}] $message
}

# The server could not be reached, the request died mid-flight, or what came
# back was not a Frostlake response at all.
#
# A statement that failed this way has an UNKNOWN fate -- it may have arrived
# and run before the connection broke -- so it must not be blindly retried; a
# re-sent INSERT would insert twice.
#
# `detail` carries `endpoint` and, when the request got far enough to have one,
# `status`.
proc ::frostlake::ConnectionError {message {detail {}}} {
    return -code error -errorcode [list FROSTLAKE CONNECTION $detail] $message
}

# The engine rejected a statement: it compiled badly, named something that does
# not exist, or failed while running. The message is the engine's own wording,
# unmodified.
#
# `detail` carries `statement` and the HTTP `status`.
#
# WARNING: binding is client-side, so `statement` holds the SQL *after*
# parameter substitution -- a bound password or card number appears in it
# verbatim. The message itself carries none of it, so log the message freely
# and treat the detail dict as sensitive.
proc ::frostlake::QueryError {message {detail {}}} {
    return -code error -errorcode [list FROSTLAKE QUERY $detail] $message
}

# The detail dict of a failure, given the error code from `$::errorCode` or from
# a `trap` body's options dict. Empty for anything this driver did not raise.
proc ::frostlake::detail {errorcode} {
    if {[lindex $errorcode 0] ne "FROSTLAKE"} { return {} }
    return [lindex $errorcode 2]
}
