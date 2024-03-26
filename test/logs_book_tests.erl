%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(logs_book_tests).
-include_lib("eunit/include/eunit.hrl").

log_query_roundtrip_test() ->
    lists:foreach(
        fun(Target) ->
            {ok, Pid} = logs_book:open(Target),
            ok = logs_book:log(Pid, warning, "disk full", #{device => sda}),
            {ok, [Log]} = logs_book:query(Pid, 10),
            warning = maps:get(level, Log),
            <<"disk full">> = maps:get(message, Log),
            #{device := <<"sda">>} = maps:get(labels, Log),
            true = is_integer(maps:get(time, Log)),
            ok = logs_book:close(Pid)
        end,
        [memory, {file, tmp_file()}, {folder, tmp_dir()}]
    ).

filter_levels_labels_test() ->
    {ok, Pid} = logs_book:open(memory),
    ok = logs_book:log(Pid, info, "a", #{k => <<"x">>}),
    ok = logs_book:log(Pid, error, "b", #{k => <<"y">>}),
    {ok, [#{level := error}]} = logs_book:query(Pid, #{levels => [error]}),
    {ok, []} = logs_book:query(Pid, #{levels => []}),
    {ok, Two} = logs_book:query(Pid, #{}),
    2 = length(Two),
    {ok, [#{message := <<"a">>}]} = logs_book:query(Pid, #{labels => #{k => x}}),
    ok = logs_book:close(Pid).

reserved_and_invalid_message_test() ->
    {ok, Pid} = logs_book:open(memory),
    {error, {reserved_label, level}} =
        logs_book:log(Pid, info, "x", #{level => <<"no">>}),
    {error, {invalid_message, _}} =
        logs_book:log(Pid, info, [<<255>>]),
    ok = logs_book:close(Pid).

stream_live_and_cancel_test() ->
    {ok, Pid} = logs_book:open(memory),
    ok = logs_book:log(Pid, info, "old"),
    {ok, Ref} = logs_book:stream(Pid, #{}, self()),
    {logs_book, Ref, {log, #{message := <<"old">>}}} = recv(),
    {logs_book, Ref, live} = recv(),
    ok = logs_book:log(Pid, info, "new"),
    {logs_book, Ref, {log, #{message := <<"new">>}}} = recv(),
    ok = logs_book:cancel(Pid, Ref),
    {logs_book, Ref, closed} = recv(),
    {ok, Ref2} = logs_book:stream(Pid, 0, self()),
    {logs_book, Ref2, live} = recv(),
    ok = logs_book:log(Pid, warning, "liveonly"),
    {logs_book, Ref2, {log, #{message := <<"liveonly">>}}} = recv(),
    ok = logs_book:cancel(Pid, Ref2),
    {logs_book, Ref2, closed} = recv(),
    Dead = spawn(fun() -> receive stop -> ok end end),
    {ok, _Ref3} = logs_book:stream(Pid, 0, Dead),
    exit(Dead, kill),
    timer:sleep(20),
    ok = logs_book:close(Pid).

stream_to_in_past_no_live_fanout_test() ->
    flush(),
    {ok, Pid} = logs_book:open(memory),
    ok = logs_book:log(Pid, 100, info, "hist", #{}),
    T2 = 200,
    true = T2 < erlang:system_time(millisecond),
    {ok, Ref} = logs_book:stream(Pid, #{to => T2}, self()),
    {logs_book, Ref, {log, #{message := <<"hist">>, time := 100}}} = recv(),
    {logs_book, Ref, live} = recv(),
    ok = logs_book:log(Pid, warning, "should-not-live"),
    receive
        {logs_book, Ref, {log, _}} ->
            error(got_live_fanout)
    after 100 ->
        ok
    end,
    ok = logs_book:close(Pid).

stream_overflow_test() ->
    {ok, Pid} = logs_book:open(memory, [{max_mailbox, 1}]),
    lists:foreach(
        fun(N) ->
            ok = logs_book:log(Pid, info, integer_to_list(N))
        end,
        lists:seq(1, 5)
    ),
    Sink = spawn_link(fun() ->
        receive go -> ok end,
        sink_loop([])
    end),
    {ok, Ref} = logs_book:stream(Pid, #{}, Sink),
    timer:sleep(30),
    Sink ! go,
    Msgs = drain_sink(Sink),
    true = lists:any(
        fun
            ({logs_book, R, {overflow, N}}) when R =:= Ref, N > 0 ->
                true;
            (_) ->
                false
        end,
        Msgs
    ),
    true = lists:member({logs_book, Ref, live}, Msgs),
    ok = logs_book:close(Pid).

explicit_time_and_clamp_test() ->
    {ok, Pid} = logs_book:open(memory),
    ok = logs_book:log(Pid, 100, info, "a", #{}),
    {error, {out_of_order, 50, 100}} = logs_book:log(Pid, 50, info, "b", #{}),
    ok = logs_book:close(Pid).

reopen_clamp_test() ->
    lists:foreach(
        fun(Target) ->
            {ok, Pid} = logs_book:open(Target),
            ok = logs_book:log(Pid, 5000, warning, "x", #{}),
            ok = logs_book:close(Pid),
            {ok, Pid2} = logs_book:open(Target),
            {ok, Info} = logs_book:info(Pid2),
            5000 = maps:get(last_time, Info),
            ok = logs_book:log(Pid2, warning, "y"),
            {ok, Logs} = logs_book:query(Pid2, 10),
            true = length(Logs) >= 2,
            Times = [maps:get(time, L) || L <- Logs],
            true = lists:all(fun(T) -> T >= 5000 end, Times),
            ok = logs_book:close(Pid2)
        end,
        [{file, tmp_file()}, {folder, tmp_dir()}]
    ).

info_sync_name_noproc_test() ->
    {ok, Pid} = logs_book:open(memory, [{name, unique_logs_name}]),
    {ok, #{page_count := _}} = logs_book:info(Pid),
    ok = logs_book:sync(Pid),
    {error, {already_started, Pid}} =
        logs_book:open(memory, [{name, unique_logs_name}]),
    ok = logs_book:close(Pid),
    ok = logs_book:close(Pid),
    {'EXIT', {noproc, _}} = catch logs_book:log(Pid, info, "z").

call_timeout_test() ->
    {ok, Pid} = logs_book:open(memory, [{timeout, 0}]),
    {'EXIT', {timeout, _}} = catch logs_book:log(Pid, info, "z"),
    ok = logs_book:close(Pid).

folder_retention_test() ->
    Dir = tmp_dir(),
    {ok, Pid} = logs_book:open({folder, Dir}, [{max_pages, 1}, {page_lines, 1}]),
    ok = logs_book:log(Pid, 1, info, "old", #{}),
    ok = logs_book:log(Pid, 2, info, "new", #{}),
    {ok, [#{message := <<"new">>}]} = logs_book:query(Pid, 10),
    ok = logs_book:close(Pid).

flush() ->
    receive
        _ ->
            flush()
    after 0 ->
        ok
    end.

recv() ->
    receive
        M ->
            M
    after 1000 ->
        error(timeout)
    end.

sink_loop(Acc) ->
    receive
        {dump, From} ->
            From ! {sink, lists:reverse(Acc)};
        Msg ->
            sink_loop([Msg | Acc])
    end.

drain_sink(Pid) ->
    Pid ! {dump, self()},
    receive
        {sink, Msgs} ->
            Msgs
    after 1000 ->
        []
    end.

tmp_file() ->
    filename:join(tmp_dir(), "logs.bin").

tmp_dir() ->
    string:chomp(os:cmd("mktemp -d")).
