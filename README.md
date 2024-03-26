# Local Logs

[![Erlangsters Repository](https://img.shields.io/badge/erlangsters-logs--book-%23a90432)](https://github.com/erlangsters/logs-book)
![Supported Erlang/OTP Versions](https://img.shields.io/badge/erlang%2Fotp-27%7C28%7C29-%23a90432)
![Current Version](https://img.shields.io/badge/version-0.0.1-%23354052)
![License](https://img.shields.io/github/license/erlangsters/logs-book)
[![Build Status](https://img.shields.io/github/actions/workflow/status/erlangsters/logs-book/build.yml)](https://github.com/erlangsters/logs-book/actions/workflows/build.yml)
[![Documentation Link](https://img.shields.io/badge/documentation-available-yellow)](http://erlangsters.github.io/logs-book/)

This 0.0.1 is a candidate implementation. The API may change in 0.0.2.

A simple logs library that stores logs locally (in memory or on disk) and which can be queried and streamed.

It is a thin process facade on top of `book-storage`. It is not a `logger` handler and it is not Loki. Application code calls `logs_book:log/3,4`. Prefer `{folder, Path}` as the persistent target.

```erlang
{ok, Pid} = logs_book:open({folder, "logs"}),
ok = logs_book:log(Pid, warning, "disk full", #{device => sda}),
{ok, Logs} = logs_book:query(Pid, 10).
```

Written by the Erlangsters [community](https://about.erlangsters.org/) and released under the MIT [license](https://opensource.org/license/mit).

## Getting started

`logs_book:open/1` starts a linked gen_server that owns one book. Put that `open/1` in your supervisor if you want it supervised.

```erlang
{ok, Pid} = logs_book:open({folder, "logs"}),
ok = logs_book:log(Pid, info, "started", #{app => myapp}),
{ok, [#{level := info, message := <<"started">>}]} = logs_book:query(Pid, 10),
{ok, Ref} = logs_book:stream(Pid, 0, self()),
receive {logs_book, Ref, live} -> ok end,
ok = logs_book:close(Pid).
```

Query accepts a last-N integer or a map with `from` / `to` / `levels` / `labels`. Stream replies a ref, then historical matches, then `{live}`, then later matching records. There is no durable cursor.

## Installing the library

To use logs-book in a rebar3 project, add it to your rebar.config.

```erlang
{deps, [
  {logs_book, {git, "https://github.com/erlangsters/logs-book.git", {tag, "0.0.1"}}}
]}.
```
