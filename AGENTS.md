# logs-book

- Pure Erlang library in the `observability` family.
- OTP 27, 28, and 29. `rebar3` is the build. Library app: `kernel` / `stdlib` / `book_storage`, no `{mod, ...}`.
- OTP `gen_server` facade. One process owns one book. It is not a `logger` handler.
- Callers start with `open/1,2` in their own supervisor. `{name, Atom}` registers `{local, Atom}`.
- Default `max_pages` is 16 on memory and folder; the option is omitted on `{file, Path}`.
- Prefer `{folder, Path}` for anything that outlives a debug session. `{file, Path}` is unbounded debug persist. `memory` is for tests.
- Stream is reply, then history, then `{live}`. `last => 0` is live-only. There is no durable cursor.
