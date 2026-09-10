# Changelog

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
