# Changelog

## Unreleased

- Session lifetime. Against an engine that reports `newSession` (0.1.0 and
  later), every request naming the session carries `requireSession: true`, so
  a session the engine no longer holds is refused with a 404 rather than
  quietly replaced by a fresh one at the default scope. The driver then drops
  the id, puts the DSN's scope on a fresh session and sends the statement once
  more; when the lost session held an open transaction or a context (`USE`,
  `SET`, `ALTER SESSION`, a temporary object) it raises the new
  `FROSTLAKE SESSIONLOST` failure instead, and the statement does not run.
  `tdbc::frostlake` reports that failure as `CONNECTION_EXCEPTION 08003`.
- Closing a connection releases its session with `DELETE /api/sessions/{id}`,
  which also rolls back a transaction left open on it: best effort, bounded by
  the shorter of `-timeout` and five seconds, and never raised. An older engine
  is sent neither the field nor the request.
- The `-idlelimit` re-scope is left to engines before 0.1.0, which give no
  sign that a session was replaced.

## 0.2.0

- The package files moved from `lib/` to the top of the repository, so the
  directory is itself a package directory: dropping it into any directory on
  `auto_path` is enough, where before `lib/` had to be named. A script that
  named `.../frostlake-tcl/lib` must now name `.../frostlake-tcl`.

## 0.1.0

First release.

- `frostlake::connect` over the engine's HTTP protocol, with one keep-alive
  socket per connection and the caller's timeout bounding the whole exchange.
- Results as plain Tcl dicts, with a `frostlake::result` ensemble for the parts
  `dict get` cannot reach.
- Cells are handed back as the engine's own text, so a `NUMBER(38,0)` keeps
  every digit and a timestamp keeps its offset. `frostlake::value` converts on
  request.
- Client-side binding for `?` and `:name` placeholders, string-typed by default
  with `-types` for the rest.
- Transactions, session scope from the DSN, and re-application of that scope
  after the engine's idle sweep has taken the session away.
- Failures carry `-errorcode` `{FROSTLAKE USAGE|CONNECTION|QUERY detail}`.
- Unit tests, with the transport covered against an in-process server, and
  engine-backed tests that boot a real `DatabaseHttpServer`.
- `tdbc::frostlake`, a TDBC driver over the same connection, modelled on
  `tdbc::sqlite3`: `:name` variables with TDBC's NULL rules, TDBC error codes,
  transactions, `preparecall`, and schema introspection.
- `$conn timeout` reads or moves the per-statement bound after connecting.
