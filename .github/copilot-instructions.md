# Logs Book Copilot Guidelines

- `logs-book` is a `pure-erlang-library` repository in the `observability` family.
- Build with `rebar3`. Do not reintroduce Erlang.mk or Makefile-based usage.
- It is a thin `gen_server` facade on top of `book-storage`. One process owns one book.
- It is not a `logger` handler and it is not Loki. Application code calls `logs_book:log/3,4`.
- Production persistence is `{folder, Path}` with `{max_pages, N}` (default 16). `{file, Path}` is unbounded debug persist. `memory` is for tests.
- Keep the design local-first and simple. No high write volume, compression, NIFs, or distributed storage.
- Keep examples and API shaping Erlang-first. Prefer BEAM-neutral public one-liners.
