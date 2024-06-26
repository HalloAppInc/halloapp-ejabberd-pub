%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @doc
%%%   This is the place for some unsorted auxiliary functions
%%%   Some functions from jlib.erl are moved here
%%%   Mild rubbish heap is accepted ;)
%%% @end
%%% Created : 30 Mar 2017 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------
-module(misc).

%% API
-export([
    tolower/1, term_to_base64/1, base64_to_term/1, ip_to_list/1,
    hex_to_bin/1, hex_to_base64/1, url_encode/1, expand_keyword/3,
    atom_to_binary/1, binary_to_atom/1, tuple_to_binary/1,
    l2i/1, i2l/1, i2l/2, expr_to_term/1, term_to_expr/1,
    now_to_usec/1, usec_to_now/1, encode_pid/1, decode_pid/2,
    compile_exprs/2, join_atoms/2, try_read_file/1, get_descr/2,
    css_dir/0, img_dir/0, js_dir/0, msgs_dir/0, sql_dir/0, lua_dir/0,
    xml_dir/0, data_dir/0, dtl_dir/0, share_post_dir/0, katchup_dir/0, read_css/1, read_img/1, read_js/1,
    read_lua/1, try_url/1,
    intersection/2, format_val/1, cancel_timer/1, unique_timestamp/0,
    best_match/2, pmap/2, peach/2, format_exception/4,
    parse_ip_mask/1, match_ip_mask/3, format_hosts_list/1, format_cycle/1,
    delete_dir/1]).

%% Deprecated functions
-export([decode_base64/1, encode_base64/1]).
-deprecated([
    {decode_base64, 1},
    {encode_base64, 1}]).

-include("logger.hrl").
-include("jid.hrl").
-include_lib("kernel/include/file.hrl").

-type distance_cache() :: #{{string(), string()} => non_neg_integer()}.

%%%===================================================================
%%% API
%%%===================================================================

-spec tolower(binary()) -> binary().
tolower(B) ->
    iolist_to_binary(tolower_s(binary_to_list(B))).

tolower_s([C | Cs]) ->
    if
        C >= $A, C =< $Z -> [C + 32 | tolower_s(Cs)];
        true -> [C | tolower_s(Cs)]
    end;
tolower_s([]) -> [].

-spec term_to_base64(term()) -> binary().
term_to_base64(Term) ->
    encode_base64(term_to_binary(Term)).

-spec base64_to_term(binary()) -> {term, term()} | error.
base64_to_term(Base64) ->
    try binary_to_term(base64:decode(Base64), [safe]) of
        Term -> {term, Term}
    catch _:_ ->
        error
    end.

-spec decode_base64(binary()) -> binary().
decode_base64(S) ->
    try base64:mime_decode(S)
    catch _:badarg -> <<>>
    end.

-spec encode_base64(binary()) -> binary().
encode_base64(Data) ->
    base64:encode(Data).

-spec ip_to_list(inet:ip_address() | undefined |
        {inet:ip_address(), inet:port_number()}) -> binary().
ip_to_list({IP, _Port}) ->
    ip_to_list(IP);
%% This function clause could use inet_parse too:
ip_to_list(undefined) ->
    <<"unknown">>;
ip_to_list(IP) ->
    list_to_binary(inet_parse:ntoa(IP)).

-spec hex_to_bin(binary()) -> binary().
hex_to_bin(Hex) ->
    hex_to_bin(binary_to_list(Hex), []).

-spec hex_to_bin(list(), list()) -> binary().
hex_to_bin([], Acc) ->
    list_to_binary(lists:reverse(Acc));
hex_to_bin([H1, H2 | T], Acc) ->
    {ok, [V], []} = io_lib:fread("~16u", [H1, H2]),
    hex_to_bin(T, [V | Acc]).

-spec hex_to_base64(binary()) -> binary().
hex_to_base64(Hex) ->
    base64:encode(hex_to_bin(Hex)).

-spec url_encode(binary()) -> binary().
url_encode(A) ->
    url_encode(A, <<>>).

-spec expand_keyword(iodata(), iodata(), iodata()) -> binary().
expand_keyword(Keyword, Input, Replacement) ->
    re:replace(Input, Keyword, Replacement,
           [{return, binary}, global]).

binary_to_atom(Bin) ->
    erlang:binary_to_atom(Bin, utf8).

tuple_to_binary(T) ->
    iolist_to_binary(tuple_to_list(T)).

atom_to_binary(A) ->
    erlang:atom_to_binary(A, utf8).

expr_to_term(Expr) ->
    Str = binary_to_list(<<Expr/binary, ".">>),
    {ok, Tokens, _} = erl_scan:string(Str),
    {ok, Term} = erl_parse:parse_term(Tokens),
    Term.

term_to_expr(Term) ->
    list_to_binary(io_lib:print(Term)).

-spec now_to_usec(erlang:timestamp()) -> non_neg_integer().
now_to_usec({MSec, Sec, USec}) ->
    (MSec*1000000 + Sec)*1000000 + USec.

-spec usec_to_now(non_neg_integer()) -> erlang:timestamp().
usec_to_now(Int) ->
    Secs = Int div 1000000,
    USec = Int rem 1000000,
    MSec = Secs div 1000000,
    Sec = Secs rem 1000000,
    {MSec, Sec, USec}.

l2i(I) when is_integer(I) -> I;
l2i(L) when is_binary(L) -> binary_to_integer(L).

i2l(I) when is_integer(I) -> integer_to_binary(I);
i2l(L) when is_binary(L) -> L.

i2l(I, N) when is_integer(I) -> i2l(i2l(I), N);
i2l(L, N) when is_binary(L) ->
    case str:len(L) of
        N -> L;
        C when C > N -> L;
        _ -> i2l(<<$0, L/binary>>, N)
    end.

-spec encode_pid(pid()) -> binary().
encode_pid(Pid) ->
    list_to_binary(erlang:pid_to_list(Pid)).

-spec decode_pid(binary(), binary()) -> pid().
decode_pid(PidBin, NodeBin) ->
    PidStr = binary_to_list(PidBin),
    Pid = erlang:list_to_pid(PidStr),
    case erlang:binary_to_atom(NodeBin, latin1) of
        Node when Node == node() ->
            Pid;
        Node ->
            try set_node_id(PidStr, NodeBin)
            catch _:badarg ->
                erlang:error({bad_node, Node})
            end
    end.

-spec compile_exprs(module(), [string()]) -> ok | {error, any()}.
compile_exprs(Mod, Exprs) ->
    try
    Forms = lists:map(
        fun(Expr) ->
            {ok, Tokens, _} = erl_scan:string(lists:flatten(Expr)),
            {ok, Form} = erl_parse:parse_form(Tokens),
            Form
        end, Exprs),
    {ok, Code} = case compile:forms(Forms, []) of
        {ok, Mod, Bin} -> {ok, Bin};
        {ok, Mod, Bin, _Warnings} -> {ok, Bin};
        Error -> Error
    end,
    {module, Mod} = code:load_binary(Mod, "nofile", Code),
    ok
    catch
        _:{badmatch, {error, ErrInfo, _ErrLocation}} ->
            {error, ErrInfo};
        _:{badmatch, {error, _} = Err} ->
            Err;
        _:{badmatch, error} ->
            {error, compile_failed}
    end.

-spec join_atoms([atom()], binary()) -> binary().
join_atoms(Atoms, Sep) ->
    str:join([io_lib:format("~p", [A]) || A <- lists:sort(Atoms)], Sep).

%% @doc Checks if the file is readable and converts its name to binary.
%%      Fails with `badarg` otherwise. The function is intended for usage
%%      in configuration validators only.
-spec try_read_file(file:filename_all()) -> binary().
try_read_file(Path) ->
    case file:open(Path, [read]) of
        {ok, Fd} ->
            file:close(Fd),
            iolist_to_binary(Path);
        {error, Why} ->
            ?ERROR("Failed to read ~ts: ~ts", [Path, file:format_error(Why)]),
            erlang:error(badarg)
    end.

%% @doc Checks if the URL is valid HTTP(S) URL and converts its name to binary.
%%      Fails with `badarg` otherwise. The function is intended for usage
%%      in configuration validators only.
-spec try_url(binary() | string()) -> binary().
try_url(URL0) ->
    URL = case URL0 of
    V when is_binary(V) -> binary_to_list(V);
    _ -> URL0
    end,
    case http_uri:parse(URL) of
        {ok, {Scheme, _, _, _, _, _}} when Scheme /= http, Scheme /= https ->
            ?ERROR("Unsupported URI scheme: ~ts", [URL]),
            erlang:error(badarg);
        {ok, {_, _, Host, _, _, _}} when Host == ""; Host == <<"">> ->
            ?ERROR("Invalid URL: ~ts", [URL]),
            erlang:error(badarg);
        {ok, _} ->
            iolist_to_binary(URL);
        {error, _} ->
            ?ERROR("Invalid URL: ~ts", [URL]),
            erlang:error(badarg)
    end.

-spec css_dir() -> file:filename().
css_dir() ->
    get_dir("css").

-spec img_dir() -> file:filename().
img_dir() ->
    get_dir("img").

-spec js_dir() -> file:filename().
js_dir() ->
    get_dir("js").

-spec msgs_dir() -> file:filename().
msgs_dir() ->
    get_dir("msgs").

-spec sql_dir() -> file:filename().
sql_dir() ->
    get_dir("sql").

-spec lua_dir() -> file:filename().
lua_dir() ->
    get_dir("lua").

-spec xml_dir() -> file:filename().
xml_dir() ->
    get_dir("xml").

-spec data_dir() -> file:filename().
data_dir() ->
    get_dir("data").

-spec dtl_dir() -> file:filename().
dtl_dir() ->
    get_dir("dtl").

-spec share_post_dir() -> file:filename().
share_post_dir() ->
    filename:join([get_dir("data"), "share_post"]).

-spec katchup_dir() -> file:filename().
katchup_dir() ->
    filename:join([get_dir("data"), "katchup"]).

-spec read_css(file:filename()) -> {ok, binary()} | {error, file:posix()}.
read_css(File) ->
    read_file(filename:join(css_dir(), File)).

-spec read_img(file:filename()) -> {ok, binary()} | {error, file:posix()}.
read_img(File) ->
    read_file(filename:join(img_dir(), File)).

-spec read_js(file:filename()) -> {ok, binary()} | {error, file:posix()}.
read_js(File) ->
    read_file(filename:join(js_dir(), File)).

-spec read_lua(file:filename()) -> {ok, binary()} | {error, file:posix()}.
read_lua(File) ->
    read_file(filename:join(lua_dir(), File)).

-spec get_descr(binary(), binary()) -> binary().
get_descr(_Lang, Text) ->
    Copyright = ejabberd_config:get_copyright(),
    <<Text/binary, $\n, Copyright/binary>>.

-spec intersection(list(), list()) -> list().
intersection(L1, L2) ->
    lists:filter(
        fun(E) ->
            lists:member(E, L2)
        end, L1).

-spec format_val(any()) -> iodata().
format_val({yaml, S}) when is_integer(S); is_binary(S); is_atom(S) ->
    format_val(S);
format_val({yaml, YAML}) ->
    S = try fast_yaml:encode(YAML)
    catch _:_ -> YAML
    end,
    format_val(S);
format_val(I) when is_integer(I) ->
    integer_to_list(I);
format_val(B) when is_atom(B) ->
    erlang:atom_to_binary(B, utf8);
format_val(Term) ->
    S = try iolist_to_binary(Term)
    catch _:_ -> list_to_binary(io_lib:format("~p", [Term]))
    end,
    case binary:match(S, <<"\n">>) of
        nomatch -> S;
        _ -> [io_lib:nl(), S]
    end.

-spec cancel_timer(reference() | undefined) -> ok.
cancel_timer(TRef) when is_reference(TRef) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive {timeout, TRef, _} -> ok
            after 0 -> ok
            end;
        _ ->
            ok
    end;
cancel_timer(_) ->
    ok.

-spec best_match(atom(), [atom()]) -> atom();
        (binary(), [binary()]) -> binary().
best_match(Pattern, []) ->
    Pattern;
best_match(Pattern, Opts) ->
    F = if
        is_atom(Pattern) -> fun atom_to_list/1;
        is_binary(Pattern) -> fun binary_to_list/1
    end,
    String = F(Pattern),
    {Ds, _} = lists:mapfoldl(
        fun(Opt, Cache) ->
            {Distance, Cache1} = ld(String, F(Opt), Cache),
            {{Distance, Opt}, Cache1}
        end, #{}, Opts),
    element(2, lists:min(Ds)).

-spec pmap(fun((T1) -> T2), [T1]) -> [T2].
pmap(Fun, [_,_|_] = List) ->
    case erlang:system_info(logical_processors) of
        1 -> lists:map(Fun, List);
        _ ->
            Self = self(),
            lists:map(
                fun({Pid, Ref}) ->
                    receive
                        {Pid, Ret} ->
                            receive
                                {'DOWN', Ref, _, _, _} ->
                                    Ret
                            end;
                        {'DOWN', Ref, _, _, Reason} ->
                            exit(Reason)
                    end
                end,
                [spawn_monitor(fun() -> Self ! {self(), Fun(X)} end) || X <- List])
    end;
pmap(Fun, List) ->
    lists:map(Fun, List).

-spec peach(fun((T) -> any()), [T]) -> ok.
peach(Fun, [_,_|_] = List) ->
    case erlang:system_info(logical_processors) of
        1 -> lists:foreach(Fun, List);
        _ ->
            Self = self(),
            lists:foreach(
                fun({Pid, Ref}) ->
                    receive
                        Pid ->
                            receive
                                {'DOWN', Ref, _, _, _} ->
                                    ok
                            end;
                        {'DOWN', Ref, _, _, Reason} ->
                            exit(Reason)
                    end
                end,
                [spawn_monitor(fun() -> Fun(X), Self ! self() end) || X <- List])
    end;
peach(Fun, List) ->
    lists:foreach(Fun, List).

-ifdef(HAVE_ERL_ERROR).
format_exception(Level, Class, Reason, Stacktrace) ->
    erl_error:format_exception(
        Level, Class, Reason, Stacktrace,
        fun(_M, _F, _A) -> false end,
        fun(Term, I) ->
            io_lib:print(Term, I, 80, -1)
        end).
-else.
format_exception(Level, Class, Reason, Stacktrace) ->
    lib:format_exception(
        Level, Class, Reason, Stacktrace,
        fun(_M, _F, _A) -> false end,
        fun(Term, I) ->
            io_lib:print(Term, I, 80, -1)
        end).
-endif.

-spec parse_ip_mask(binary()) -> {ok, {inet:ip4_address(), 0..32}} |
        {ok, {inet:ip6_address(), 0..128}} |
        error.
parse_ip_mask(S) ->
    case econf:validate(econf:ip_mask(), S) of
        {ok, _} = Ret -> Ret;
        _ -> error
    end.

-spec match_ip_mask(inet:ip_address(), inet:ip_address(), 0..128) -> boolean().
match_ip_mask({_, _, _, _} = IP, {_, _, _, _} = Net, Mask) ->
    IPInt = ip_to_integer(IP),
    NetInt = ip_to_integer(Net),
    M = bnot (1 bsl (32 - Mask) - 1),
    IPInt band M =:= NetInt band M;
match_ip_mask({_, _, _, _, _, _, _, _} = IP,
        {_, _, _, _, _, _, _, _} = Net, Mask) ->
    IPInt = ip_to_integer(IP),
    NetInt = ip_to_integer(Net),
    M = bnot (1 bsl (128 - Mask) - 1),
    IPInt band M =:= NetInt band M;
match_ip_mask({_, _, _, _} = IP,
        {0, 0, 0, 0, 0, 16#FFFF, _, _} = Net, Mask) ->
    IPInt = ip_to_integer({0, 0, 0, 0, 0, 16#FFFF, 0, 0}) + ip_to_integer(IP),
    NetInt = ip_to_integer(Net),
    M = bnot (1 bsl (128 - Mask) - 1),
    IPInt band M =:= NetInt band M;
match_ip_mask({0, 0, 0, 0, 0, 16#FFFF, _, _} = IP,
        {_, _, _, _} = Net, Mask) ->
    IPInt = ip_to_integer(IP) - ip_to_integer({0, 0, 0, 0, 0, 16#FFFF, 0, 0}),
    NetInt = ip_to_integer(Net),
    M = bnot (1 bsl (32 - Mask) - 1),
    IPInt band M =:= NetInt band M;
match_ip_mask(_, _, _) ->
    false.

-spec format_hosts_list([binary(), ...]) -> iolist().
format_hosts_list([Host]) ->
    Host;
format_hosts_list([H1, H2]) ->
    [H1, " and ", H2];
format_hosts_list([H1, H2, H3]) ->
    [H1, ", ", H2, " and ", H3];
format_hosts_list([H1, H2|Hs]) ->
    io_lib:format("~ts, ~ts and ~B more hosts",
          [H1, H2, length(Hs)]).

-spec format_cycle([atom(), ...]) -> iolist().
format_cycle([M1]) ->
    atom_to_list(M1);
format_cycle([M1, M2]) ->
    [atom_to_list(M1), " and ", atom_to_list(M2)];
format_cycle([M|Ms]) ->
    atom_to_list(M) ++ ", " ++ format_cycle(Ms).

-spec delete_dir(file:filename_all()) -> ok | {error, file:posix()}.
delete_dir(Dir) ->
    try
    {ok, Entries} = file:list_dir(Dir),
    lists:foreach(
        fun(Path) ->
            case filelib:is_dir(Path) of
                true ->
                    ok = delete_dir(Path);
                false ->
                    ok = file:delete(Path)
            end
        end, [filename:join(Dir, Entry) || Entry <- Entries]),
    ok = file:del_dir(Dir)
    catch
        _:{badmatch, {error, Error}} ->
            {error, Error}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec url_encode(binary(), binary()) -> binary().
url_encode(<<H:8, T/binary>>, Acc) when
        (H >= $a andalso H =< $z) orelse
        (H >= $A andalso H =< $Z) orelse
        (H >= $0 andalso H =< $9) orelse
        H == $_ orelse
        H == $. orelse
        H == $- orelse
        H == $/ orelse
        H == $: ->
    url_encode(T, <<Acc/binary, H>>);
url_encode(<<H:8, T/binary>>, Acc) ->
    case integer_to_list(H, 16) of
        [X, Y] -> url_encode(T, <<Acc/binary, $%, X, Y>>);
        [X] -> url_encode(T, <<Acc/binary, $%, $0, X>>)
    end;
url_encode(<<>>, Acc) ->
    Acc.

-spec set_node_id(string(), binary()) -> pid().
set_node_id(PidStr, NodeBin) ->
    ExtPidStr = erlang:pid_to_list(
          binary_to_term(
            <<131,103,100,(size(NodeBin)):16,NodeBin/binary,0:72>>)),
    [H|_] = string:tokens(ExtPidStr, "."),
    [_|T] = string:tokens(PidStr, "."),
    erlang:list_to_pid(string:join([H|T], ".")).

-spec read_file(file:filename()) -> {ok, binary()} | {error, file:posix()}.
read_file(Path) ->
    case file:read_file(Path) of
    {ok, Data} ->
        {ok, Data};
    {error, Why} = Err ->
        ?ERROR("Failed to read file ~ts: ~ts",
               [Path, file:format_error(Why)]),
        Err
    end.

-spec get_dir(string()) -> file:filename().
get_dir(Type) ->
    Env = "EJABBERD_" ++ string:to_upper(Type) ++ "_PATH",
    case os:getenv(Env) of
    false ->
        case code:priv_dir(ejabberd) of
        {error, _} ->
            Ebin = filename:dirname(code:which(?MODULE)),
            P = filename:join([filename:dirname(Ebin), "priv", Type]),
            P2 = case {filelib:is_dir(P), config:is_testing_env()} of
                {false, true} -> filename:join("..", P);
                _ -> P
            end,
            P2;
        Path -> filename:join([Path, Type])
        end;
    Path ->
        Path
    end.

%% Generates erlang:timestamp() that is guaranteed to unique
-spec unique_timestamp() -> erlang:timestamp().
unique_timestamp() ->
    {MS, S, _} = erlang:timestamp(),
    {MS, S, erlang:unique_integer([positive, monotonic]) rem 1000000}.

%% Levenshtein distance
-spec ld(string(), string(), distance_cache()) -> {non_neg_integer(), distance_cache()}.
ld([] = S, T, Cache) ->
    {length(T), maps:put({S, T}, length(T), Cache)};
ld(S, [] = T, Cache) ->
    {length(S), maps:put({S, T}, length(S), Cache)};
ld([X|S], [X|T], Cache) ->
    ld(S, T, Cache);
ld([_|ST] = S, [_|TT] = T, Cache) ->
    try {maps:get({S, T}, Cache), Cache}
    catch _:{badkey, _} ->
        {L1, C1} = ld(S, TT, Cache),
        {L2, C2} = ld(ST, T, C1),
        {L3, C3} = ld(ST, TT, C2),
        L = 1 + lists:min([L1, L2, L3]),
        {L, maps:put({S, T}, L, C3)}
    end.

-spec ip_to_integer(inet:ip_address()) -> non_neg_integer().
ip_to_integer({IP1, IP2, IP3, IP4}) ->
    IP1 bsl 8 bor IP2 bsl 8 bor IP3 bsl 8 bor IP4;
ip_to_integer({IP1, IP2, IP3, IP4, IP5, IP6, IP7,
           IP8}) ->
    IP1 bsl 16 bor IP2 bsl 16 bor IP3 bsl 16 bor IP4 bsl 16
    bor IP5 bsl 16 bor IP6 bsl 16 bor IP7 bsl 16 bor IP8.
