%%
%% Copyright (c) 2026, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project repository.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>
%%
-module(logs_book).
-moduledoc """
Process facade for local queryable logs on top of `book_storage`.

It is not a `logger` handler. Application code calls `log/3,4` (or `log/5`
with an explicit time). One gen_server owns one book.

```erlang
{ok, Pid} = logs_book:open({folder, "logs"}),
ok = logs_book:log(Pid, warning, "disk full", #{device => sda}),
{ok, Logs} = logs_book:query(Pid, 10).
```

Callers who want a supervised book put `{logs_book, open, [Target, Options]}`
in their supervisor. Prefer `{folder, Path}` over `{file, Path}` for anything
that outlives a debug session.
""".
-behaviour(gen_server).

-export_type([
    server/0,
    target/0,
    option/0,
    level/0,
    message/0,
    label_value/0,
    labels/0,
    log/0,
    query/0,
    stream_ref/0,
    reason/0
]).

-export([
    open/1, open/2,
    close/1,
    log/3, log/4, log/5,
    query/2,
    stream/3,
    cancel/2,
    info/1,
    sync/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(CALL_TIMEOUT, 5000).
-define(VERSION, 1).

-record(stream, {
    ref :: reference(),
    pid :: pid(),
    mon :: reference(),
    levels :: undefined | [level()],
    labels :: #{atom() => binary()},
    silent = false :: boolean(),
    overflow = 0 :: non_neg_integer()
}).

-record(state, {
    book :: book_storage:book(),
    last_time :: empty | book_storage:time(),
    max_mailbox :: pos_integer(),
    streams = [] :: [#stream{}]
}).

-doc """
Pid or locally registered name of a logs book.
""".
-type server() :: pid() | atom().

-doc """
Storage target, the same term `book_storage:open/1` accepts.
""".
-type target() :: book_storage:target().

-doc """
OTP logger severity.
""".
-type level() ::
    debug | info | notice | warning | error | critical | alert | emergency.

-doc """
Log message, stored as UTF-8.
""".
-type message() :: unicode:chardata().

-doc """
Accepted label value before canonicalization to binary.
""".
-type label_value() :: atom() | integer() | unicode:chardata().

-doc """
User labels. The key `level` is reserved.
""".
-type labels() :: #{atom() => label_value()}.

-doc """
One log record returned by query and stream.
""".
-type log() :: #{
    time := book_storage:time(),
    level := level(),
    message := binary(),
    labels := #{atom() => binary()}
}.

-doc """
Query or stream filter.

An integer `N` passed to `query/2` or `stream/3` means `#{last => N}`.
""".
-type query() :: #{
    from => book_storage:time() | beginning,
    to => book_storage:time() | latest,
    last => non_neg_integer(),
    limit => pos_integer(),
    levels => [level()],
    labels => labels()
}.

-doc """
Open option: book-storage options plus process options.
""".
-type option() ::
    book_storage:option() |
    {name, atom()} |
    {timeout, timeout()} |
    {max_mailbox, pos_integer()}.

-doc """
Opaque stream identifier returned by `stream/3`.
""".
-opaque stream_ref() :: reference().

-doc """
Facade error, including storage reasons.
""".
-type reason() ::
    book_storage:reason() |
    {already_started, pid()} |
    {invalid_message, term()} |
    {reserved_label, atom()} |
    {invalid_label, atom(), term()} |
    {invalid_level, term()} |
    {unknown_stream, reference()}.

-doc """
Open a logs book with facade defaults.

Default `max_pages` is 16 on memory and folder. The option is omitted on file.
""".
-spec open(target()) -> {ok, pid()} | {error, reason()}.
open(Target) ->
    open(Target, []).

-doc """
Open a logs book.

`{name, Atom}` registers `{local, Atom}`. A taken name is
`{error, {already_started, Pid}}`. `{timeout, T}` is the `gen_server:call`
timeout for later calls (default 5000). It does not bound stream replay
after `{ok, Ref}`.
""".
-spec open(target(), [option()]) -> {ok, pid()} | {error, reason()}.
open(Target, Options) ->
    {Name, Rest} = take_name(Options),
    Start = case Name of
        undefined ->
            gen_server:start_link(?MODULE, {Target, Rest}, []);
        Atom ->
            gen_server:start_link({local, Atom}, ?MODULE, {Target, Rest}, [])
    end,
    case Start of
        {ok, Pid} ->
            {ok, Pid};
        {error, {already_started, Pid}} ->
            {error, {already_started, Pid}};
        {error, Reason} ->
            {error, Reason}
    end.

-doc """
Stop the server and close the book.

It is idempotent: `ok` if the process is already dead.
""".
-spec close(server()) -> ok.
close(Server) ->
    try
        gen_server:stop(Server)
    catch
        exit:noproc ->
            ok;
        exit:{noproc, _} ->
            ok
    end.

-doc """
Return `book_storage:info/1` for the held book.
""".
-spec info(server()) -> {ok, book_storage:book_info()} | {error, reason()}.
info(Server) ->
    call(Server, info).

-doc """
Fsync the held book.
""".
-spec sync(server()) -> ok | {error, reason()}.
sync(Server) ->
    call(Server, sync).

-doc """
Log a message with no labels.
""".
-spec log(server(), level(), message()) -> ok | {error, reason()}.
log(Server, Level, Message) ->
    log(Server, Level, Message, #{}).

-doc """
Log a message.

Time is `max(Now, LastTime)` inside the server so a backward clock cannot
lock the book.
""".
-spec log(server(), level(), message(), labels()) -> ok | {error, reason()}.
log(Server, Level, Message, Labels) ->
    call(Server, {log, auto, Level, Message, Labels}).

-doc """
Log a message at an explicit time.

It does not clamp. Out-of-order times surface `{out_of_order, Time, Last}`.
""".
-spec log(server(), book_storage:time(), level(), message(), labels()) ->
    ok | {error, reason()}.
log(Server, Time, Level, Message, Labels) ->
    call(Server, {log, {time, Time}, Level, Message, Labels}).

-doc """
Query log records, oldest-first.

An integer `N` means the last N matching records.
""".
-spec query(server(), non_neg_integer() | query()) ->
    {ok, [log()]} | {error, reason()}.
query(Server, N) when is_integer(N), N >= 0 ->
    query(Server, #{last => N});
query(Server, Query) when is_map(Query) ->
    call(Server, {query, Query}).

-doc """
Start a stream.

The call replies `{ok, Ref}` before historical records are delivered, then
the subscriber receives historical matches, `{logs_book, Ref, live}`, and
later matching records. `last => 0` is live-only. A map with no window
defaults to `last => 100`.
""".
-spec stream(server(), non_neg_integer() | query(), pid()) ->
    {ok, stream_ref()} | {error, reason()}.
stream(Server, N, Pid) when is_integer(N), N >= 0, is_pid(Pid) ->
    stream(Server, #{last => N}, Pid);
stream(Server, Query, Pid) when is_map(Query), is_pid(Pid) ->
    call(Server, {stream, Query, Pid}).

-doc """
Cancel a stream and send `{logs_book, Ref, closed}`.
""".
-spec cancel(server(), stream_ref()) -> ok | {error, reason()}.
cancel(Server, Ref) ->
    call(Server, {cancel, Ref}).

call(Server, Req) ->
    gen_server:call(Server, Req, call_timeout(Server)).

call_timeout(Server) when is_pid(Server) ->
    persistent_term:get({?MODULE, timeout, Server}, ?CALL_TIMEOUT);
call_timeout(Server) when is_atom(Server) ->
    case whereis(Server) of
        undefined ->
            ?CALL_TIMEOUT;
        Pid ->
            persistent_term:get({?MODULE, timeout, Pid}, ?CALL_TIMEOUT)
    end.

-doc false.
init({Target, Options}) ->
    case parse_open_options(Options) of
        {error, Reason} ->
            {stop, Reason};
        {ok, MaxMailbox, Timeout, BookOpts} ->
            BookOpts1 = apply_max_pages_default(Target, BookOpts, 16),
            case book_storage:open(Target, BookOpts1) of
                {ok, Book} ->
                    {ok, Info} = book_storage:info(Book),
                    persistent_term:put({?MODULE, timeout, self()}, Timeout),
                    {ok, #state{
                        book = Book,
                        last_time = maps:get(last_time, Info),
                        max_mailbox = MaxMailbox
                    }};
                {error, Reason} ->
                    {stop, Reason}
            end
    end.

-doc false.
handle_call({log, TimeSpec, Level, Message, Labels}, _From, State) ->
    case do_log(TimeSpec, Level, Message, Labels, State) of
        {ok, State2} ->
            {reply, ok, State2};
        {error, Reason, State2} ->
            {reply, {error, Reason}, State2}
    end;
handle_call({query, Query}, _From, #state{book = Book} = State) ->
    case run_query(Book, Query) of
        {ok, Logs} ->
            {reply, {ok, Logs}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call({stream, Query, Pid}, From, State) ->
    start_stream(Query, Pid, From, State);
handle_call({cancel, Ref}, _From, State) ->
    case take_stream(Ref, State#state.streams) of
        {ok, Stream, Rest} ->
            send_overflow_then(Stream, closed),
            demonitor(Stream#stream.mon, [flush]),
            {reply, ok, State#state{streams = Rest}};
        error ->
            {reply, {error, {unknown_stream, Ref}}, State}
    end;
handle_call(info, _From, #state{book = Book} = State) ->
    {reply, book_storage:info(Book), State};
handle_call(sync, _From, #state{book = Book} = State) ->
    {reply, book_storage:sync(Book), State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info({'DOWN', Mon, process, _Pid, _Reason}, State) ->
    Streams = [S || S <- State#state.streams, S#stream.mon =/= Mon],
    {noreply, State#state{streams = Streams}};
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, #state{book = Book, streams = Streams}) ->
    lists:foreach(
        fun(S) ->
            send_overflow_then(S, closed),
            demonitor(S#stream.mon, [flush])
        end,
        Streams
    ),
    _ = book_storage:close(Book),
    _ = persistent_term:erase({?MODULE, timeout, self()}),
    ok.

do_log(TimeSpec, Level, Message, Labels, State) ->
    case prepare_record(TimeSpec, Level, Message, Labels, State#state.last_time) of
        {error, Reason} ->
            {error, Reason, State};
        {ok, Time, Log, Value, Tags} ->
            case book_storage:write(State#state.book, Time, Value, Tags) of
                {ok, Book2} ->
                    State2 = State#state{book = Book2, last_time = Time},
                    {ok, fanout(Log, State2)};
                {error, Reason, Book3} ->
                    {error, Reason, State#state{book = Book3}}
            end
    end.

prepare_record(TimeSpec, Level, Message, Labels, LastTime) ->
    case is_level(Level) of
        false ->
            {error, {invalid_level, Level}};
        true ->
            case encode_message(Message) of
                {error, Reason} ->
                    {error, Reason};
                {ok, MsgBin} ->
                    case canonicalize_labels(Labels) of
                        {error, Reason} ->
                            {error, Reason};
                        {ok, Canon} ->
                            Time = stamp(TimeSpec, LastTime),
                            case Time of
                                {error, Reason} ->
                                    {error, Reason};
                                T ->
                                    Log = #{
                                        time => T,
                                        level => Level,
                                        message => MsgBin,
                                        labels => Canon
                                    },
                                    {ok, T, Log, encode_value(Level, MsgBin), encode_tags(Level, Canon)}
                            end
                    end
            end
    end.

stamp(auto, empty) ->
    erlang:system_time(millisecond);
stamp(auto, Last) ->
    max(erlang:system_time(millisecond), Last);
stamp({time, T}, empty) when is_integer(T), T >= 0 ->
    T;
stamp({time, T}, Last) when is_integer(T), T >= 0 ->
    case T < Last of
        true ->
            {error, {out_of_order, T, Last}};
        false ->
            T
    end;
stamp({time, T}, _) ->
    {error, {invalid_time, T}}.

encode_message(Message) ->
    case unicode:characters_to_binary(Message) of
        Bin when is_binary(Bin) ->
            {ok, Bin};
        {error, _, _} = Err ->
            {error, {invalid_message, Err}};
        {incomplete, _, _} = Err ->
            {error, {invalid_message, Err}}
    end.

canonicalize_labels(Labels) when is_map(Labels) ->
    maps:fold(
        fun
            (level, _V, _Acc) ->
                {error, {reserved_label, level}};
            (K, V, {ok, Acc}) when is_atom(K) ->
                case canon_value(V) of
                    {ok, Bin} ->
                        {ok, Acc#{K => Bin}};
                    error ->
                        {error, {invalid_label, K, V}}
                end;
            (K, V, {ok, _}) ->
                {error, {invalid_label, K, V}};
            (_, _, {error, _} = Err) ->
                Err
        end,
        {ok, #{}},
        Labels
    );
canonicalize_labels(Other) ->
    {error, {invalid_label, invalid, Other}}.

canon_value(V) when is_atom(V) ->
    {ok, atom_to_binary(V, utf8)};
canon_value(V) when is_integer(V) ->
    {ok, integer_to_binary(V)};
canon_value(V) ->
    case unicode:characters_to_binary(V) of
        Bin when is_binary(Bin) ->
            {ok, Bin};
        _ ->
            error
    end.

encode_value(Level, MsgBin) ->
    Term = term_to_binary(#{level => Level, message => MsgBin}, [{minor_version, 1}]),
    <<?VERSION, Term/binary>>.

encode_tags(Level, Labels) ->
    Labels#{level => atom_to_binary(Level, utf8)}.

is_level(debug) -> true;
is_level(info) -> true;
is_level(notice) -> true;
is_level(warning) -> true;
is_level(error) -> true;
is_level(critical) -> true;
is_level(alert) -> true;
is_level(emergency) -> true;
is_level(_) -> false.

run_query(Book, Query) ->
    case to_book_query(Query, query) of
        {error, Reason} ->
            {error, Reason};
        {ok, BQ} ->
            case book_storage:query(Book, BQ) of
                {ok, Lines} ->
                    {ok, [Log || Line <- Lines, {ok, Log} <- [decode_line(Line)]]};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

to_book_query(Query, Kind) ->
    case canonicalize_query_labels(Query) of
        {error, Reason} ->
            {error, Reason};
        {ok, Labels} ->
            case query_levels(Query) of
                {error, Reason} ->
                    {error, Reason};
                {ok, Levels} ->
                    Tags0 = Labels,
                    Tags = case Levels of
                        undefined ->
                            Tags0;
                        List ->
                            Tags0#{level => [atom_to_binary(L, utf8) || L <- List]}
                    end,
                    BQ = maps:with([from, to, last, limit], Query),
                    BQ1 = case {Kind, has_window(Query)} of
                        {stream, false} ->
                            BQ#{last => maps:get(last, Query, 100)};
                        _ ->
                            BQ
                    end,
                    {ok, BQ1#{tags => Tags}}
            end
    end.

has_window(Query) ->
    maps:is_key(from, Query) orelse maps:is_key(to, Query) orelse maps:is_key(last, Query).

query_levels(Query) ->
    case maps:find(levels, Query) of
        error ->
            {ok, undefined};
        {ok, List} when is_list(List) ->
            case lists:all(fun is_level/1, List) of
                true ->
                    {ok, List};
                false ->
                    {error, {invalid_level, List}}
            end;
        {ok, Other} ->
            {error, {invalid_level, Other}}
    end.

canonicalize_query_labels(Query) ->
    case maps:get(labels, Query, #{}) of
        Map when is_map(Map) ->
            canonicalize_labels(Map);
        Other ->
            {error, {invalid_label, invalid, Other}}
    end.

decode_line(#{time := Time, value := <<?VERSION, Term/binary>>, tags := Tags}) ->
    try binary_to_term(Term) of
        #{level := Level, message := Message} ->
            Labels = maps:remove(level, Tags),
            {ok, #{time => Time, level => Level, message => Message, labels => Labels}}
    catch
        _:_ ->
            skip
    end;
decode_line(_) ->
    skip.

start_stream(Query, Pid, From, #state{book = Book, last_time = Last, max_mailbox = Max} = State) ->
    case to_book_query(Query, stream) of
        {error, Reason} ->
            {reply, {error, Reason}, State};
        {ok, BQ} ->
            case book_storage:query(Book, BQ) of
                {error, Reason} ->
                    {reply, {error, Reason}, State};
                {ok, Lines} ->
                    Logs = [Log || Line <- Lines, {ok, Log} <- [decode_line(Line)]],
                    Ref = make_ref(),
                    Mon = monitor(process, Pid),
                    {ok, Levels} = query_levels(Query),
                    {ok, Labels} = canonicalize_query_labels(Query),
                    Silent = is_silent(Query, Last),
                    Stream = #stream{
                        ref = Ref,
                        pid = Pid,
                        mon = Mon,
                        levels = Levels,
                        labels = Labels,
                        silent = Silent
                    },
                    gen_server:reply(From, {ok, Ref}),
                    send_history(Pid, Ref, Logs, Max),
                    {noreply, State#state{streams = [Stream | State#state.streams]}}
            end
    end.

is_silent(Query, LastTime) ->
    case maps:get(to, Query, latest) of
        latest ->
            false;
        To when is_integer(To) ->
            Now = erlang:system_time(millisecond),
            Next = case LastTime of
                empty ->
                    Now;
                Last ->
                    max(Now, Last)
            end,
            To < Next;
        _ ->
            false
    end.

send_history(Pid, Ref, Logs, Max) ->
    Dropped = send_each(Pid, Ref, Logs, Max, 0),
    case Dropped of
        0 ->
            ok;
        N ->
            Pid ! {logs_book, Ref, {overflow, N}}
    end,
    Pid ! {logs_book, Ref, live},
    ok.

send_each(_Pid, _Ref, [], _Max, Dropped) ->
    Dropped;
send_each(Pid, Ref, [Log | Rest], Max, Dropped) ->
    case mailbox_len(Pid) > Max of
        true ->
            send_each(Pid, Ref, Rest, Max, Dropped + 1);
        false ->
            Pid ! {logs_book, Ref, {log, Log}},
            send_each(Pid, Ref, Rest, Max, Dropped)
    end.

fanout(Log, #state{streams = Streams, max_mailbox = Max} = State) ->
    State#state{streams = [fanout_one(S, Log, Max) || S <- Streams]}.

fanout_one(#stream{silent = true} = S, _Log, _Max) ->
    S;
fanout_one(#stream{pid = Pid, ref = Ref, overflow = Over} = S, Log, Max) ->
    case stream_match(S, Log) of
        false ->
            S;
        true ->
            case mailbox_len(Pid) > Max of
                true ->
                    S#stream{overflow = Over + 1};
                false ->
                    case Over of
                        0 ->
                            ok;
                        N ->
                            Pid ! {logs_book, Ref, {overflow, N}}
                    end,
                    Pid ! {logs_book, Ref, {log, Log}},
                    S#stream{overflow = 0}
            end
    end.

stream_match(#stream{levels = Levels, labels = Want}, #{level := Level, labels := Have}) ->
    LevelOk = Levels =:= undefined orelse lists:member(Level, Levels),
    LabelsOk = maps:fold(
        fun(K, V, Acc) ->
            Acc andalso maps:get(K, Have, undefined) =:= V
        end,
        true,
        Want
    ),
    LevelOk andalso LabelsOk.

send_overflow_then(#stream{pid = Pid, ref = Ref, overflow = Over}, closed) ->
    case Over of
        0 ->
            ok;
        N ->
            Pid ! {logs_book, Ref, {overflow, N}}
    end,
    Pid ! {logs_book, Ref, closed},
    ok.

take_stream(Ref, Streams) ->
    case lists:keytake(Ref, #stream.ref, Streams) of
        {value, Stream, Rest} ->
            {ok, Stream, Rest};
        false ->
            error
    end.

mailbox_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} ->
            N;
        undefined ->
            0
    end.

take_name(Options) ->
    case lists:keytake(name, 1, Options) of
        {value, {name, Atom}, Rest} when is_atom(Atom) ->
            {Atom, Rest};
        false ->
            {undefined, Options};
        {value, Term, _} ->
            {invalid, Term}
    end.

parse_open_options(Options) ->
    parse_open_options(Options, 1000, ?CALL_TIMEOUT, []).

parse_open_options([], MaxMailbox, Timeout, BookOpts) ->
    {ok, MaxMailbox, Timeout, lists:reverse(BookOpts)};
parse_open_options([{timeout, T} | Rest], MaxMailbox, _Timeout, BookOpts) ->
    case is_timeout(T) of
        true ->
            parse_open_options(Rest, MaxMailbox, T, BookOpts);
        false ->
            {error, {invalid_option, {timeout, T}}}
    end;
parse_open_options([{max_mailbox, N} | Rest], _Max, Timeout, BookOpts) when is_integer(N), N > 0 ->
    parse_open_options(Rest, N, Timeout, BookOpts);
parse_open_options([Opt | Rest], MaxMailbox, Timeout, BookOpts) ->
    parse_open_options(Rest, MaxMailbox, Timeout, [Opt | BookOpts]).

is_timeout(infinity) ->
    true;
is_timeout(T) when is_integer(T), T >= 0 ->
    true;
is_timeout(_) ->
    false.

apply_max_pages_default({file, _}, BookOpts, _Default) ->
    BookOpts;
apply_max_pages_default(_Target, BookOpts, Default) ->
    case proplists:is_defined(max_pages, BookOpts) of
        true ->
            BookOpts;
        false ->
            [{max_pages, Default} | BookOpts]
    end.
