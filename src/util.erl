%%%----------------------------------------------------------------------
%%% File    : util.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the utility functions used in various other modules.
%%%----------------------------------------------------------------------

-module(util).
-author('murali').
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    timestamp_to_binary/1,
    cur_timestamp/0,
    timestamp_secs_to_integer/1,
    get_host/0,
    pubsub_node_name/2,
    now_ms/0,
    now/0,
    now_binary/0,
    round_to_minute/1,
    random_str/1,
    generate_password/0,
    generate_gid/0,
    type/1,
    to_integer/1,
    to_atom/1,
    to_binary/1,
    new_msg_id/0,
    new_avatar_id/0,
    list_to_map/1,
    ms_to_sec/1,
    send_after/2,
    uids_to_jids/2,
    uuid_binary/0,
    timestamp_to_datetime/1,
    decode_base_64/1,
    is_test_number/1,
    join_binary/2,
    join_binary/3,
    err/1,
    err/2,
    ms_to_datetime_string/1
]).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-define(PASSWORD_SIZE, 24).
-define(GID_SIZE, 22).

-spec get_host() -> binary().
get_host() ->
    case config:is_testing_env() of
        true ->
            <<"s.halloapp.net">>;
        false ->
            [H | []] = ejabberd_option:hosts(),
            H
    end.

-spec now_ms() -> integer().
now_ms() ->
    os:system_time(millisecond).

-spec now() -> integer().
now() ->
    os:system_time(second).


-spec now_binary() -> binary().
now_binary() ->
    integer_to_binary(util:now()).


-spec round_to_minute(TimestampInSeconds :: non_neg_integer()) -> non_neg_integer().
round_to_minute(TimestampInSeconds) ->
    (TimestampInSeconds div 60) * 60.


%% Combines the MegaSec and Seconds part of the timestamp into a binary and returns it.
%% Expects an erlang timestamp as input.
-spec timestamp_to_binary(erlang:timestamp()) -> binary().
timestamp_to_binary(Timestamp) ->
    {T1, T2, _} = Timestamp,
    list_to_binary(integer_to_list(T1*1000000 + T2)).


%% Returns current Erlang system time on the format {MegaSecs, Secs, MicroSecs}
-spec cur_timestamp() -> erlang:timestamp().
cur_timestamp() ->
    erlang:timestamp().


%% Converts an erlang timestamp to seconds in integer.
-spec timestamp_secs_to_integer(erlang:timestamp()) -> integer().
timestamp_secs_to_integer(Timestamp) ->
    binary_to_integer(timestamp_to_binary(Timestamp)).


-spec pubsub_node_name(User :: binary(), NodeType :: atom()) -> binary().
pubsub_node_name(User, NodeType) ->
    list_to_binary(atom_to_list(NodeType) ++ "-" ++ binary_to_list(User)).


%% Returns random string containing [a-zA-Z0-9] and -_
-spec random_str(Size :: integer()) -> binary().
random_str(Size) ->
    SS = base64url:encode(crypto:strong_rand_bytes(Size)),
    binary:part(SS, 0, Size).


-spec generate_password() -> binary().
generate_password() ->
    random_str(?PASSWORD_SIZE).

-spec generate_gid() -> binary().
generate_gid() ->
    GidPart = random_str(?GID_SIZE - 1),
    <<"g", GidPart/binary>>.


type(X) when is_binary(X) ->
    "binary";
type(X) when is_list(X) ->
    "list";
type(X) when is_bitstring(X) ->
    "bitstring";
type(X) when is_boolean(X) ->
    "boolean";
type(X) when is_atom(X) ->
    "atom";
type(X) when is_float(X) ->
    "float";
type(X) when is_integer(X) ->
    "integer";
type(X) when is_map(X) ->
    "map";
type(X) when is_tuple(X) ->
    "tuple";
type(_X) ->
    "unknown".


-spec to_integer(any()) -> integer() | undefined.
to_integer(Data) ->
    case type(Data) of
        "binary" -> binary_to_integer(Data);
        "list" -> list_to_integer(Data);
        "float" -> round(Data);
        "integer" -> Data;
        _ ->
            ?ERROR_MSG("Failed converting data to integer: ~p", [Data]),
            undefined
    end.


to_atom(Data) ->
    case type(Data) of
        "binary" -> binary_to_atom(Data, utf8);
        "atom" -> Data;
        "boolean" -> Data;
        "list" -> list_to_atom(Data);
        _ ->
            ?ERROR_MSG("Failed converting data to atom: ~p", [Data]),
            undefined
    end.

to_binary(Data) ->
    case type(Data) of
        "binary" -> Data;
        "atom" -> atom_to_binary(Data, utf8);
        "boolean" -> atom_to_binary(Data, utf8);
        "list" -> list_to_binary(Data);
        "integer" -> integer_to_binary(Data);
        _ ->
            ?ERROR_MSG("Failed converting data to binary: ~p", [Data]),
            <<>>
    end.

-spec new_msg_id() -> binary().
new_msg_id() ->
    new_base64_uuid().


-spec new_avatar_id() -> binary().
new_avatar_id() ->
    new_base64_uuid().


-spec new_base64_uuid() -> binary().
new_base64_uuid() ->
    base64url:encode(uuid:uuid1()).


list_to_map(L) ->
    list_to_map(L, #{}).

list_to_map([K, V | Rest], Map) ->
    Map2 = maps:put(K, V, Map),
    list_to_map(Rest, Map2);
list_to_map([], Map) ->
    Map.


-spec ms_to_sec(MilliSeconds :: integer()) -> integer().
ms_to_sec(MilliSeconds) when is_integer(MilliSeconds) ->
    MilliSeconds div 1000.


-spec send_after(TimeoutMs :: integer(), Msg :: any()) -> reference().
send_after(TimeoutMs, Msg) ->
    NewTimer = erlang:send_after(TimeoutMs, self(), Msg),
    NewTimer.


-spec uids_to_jids(Uids :: list(binary()), Server :: binary()) -> list(jid()).
uids_to_jids(Uids, Server) ->
    lists:map(fun(Uid) -> jid:make(Uid, Server) end, Uids).


-spec uuid_binary() -> binary().
uuid_binary() ->
    list_to_binary(uuid:to_string(uuid:uuid1())).


%% does not throw exception return error instead.
-spec decode_base_64(Base64Data :: binary()) -> {ok, binary()} | {error, bad_data}.
decode_base_64(Base64Data) ->
    try
        {ok, base64:decode(Base64Data)}
    catch
        error:badarg -> {error, bad_data}
    end.


-spec timestamp_to_datetime(TsMs :: non_neg_integer()) -> calendar:datetime().
timestamp_to_datetime(TsMs) ->
    BaseDate = calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
    calendar:gregorian_seconds_to_datetime(BaseDate + (TsMs div 1000)).


-spec is_test_number(Phone :: binary()) -> boolean().
is_test_number(Phone) ->
    case re:run(Phone, "^1...555....$") of
        {match, _} -> true;
        _ -> false
    end.


-spec join_binary(Char :: binary(), Elements :: [binary()]) -> binary().
join_binary(Char, Elements) ->
    join_binary(Char, Elements, <<>>).


-spec join_binary(Char :: binary(), Elements :: [binary()], FinalString :: binary()) -> binary().
join_binary(_Char, [], FinalString) -> FinalString;
join_binary(Char, [Element | Rest], FinalString) ->
    NewFinalString = <<FinalString/binary, Char/binary, Element/binary>>,
    join_binary(Char, Rest, NewFinalString).


-spec err(Reason :: atom()) -> stanza_error().
err(Reason) ->
    #error_st{reason = Reason, type = cancel, bad_req = 'bad-request'}.


-spec err(Reason :: atom(), Hash :: binary()) -> stanza_error().
err(Reason, Hash) ->
    #error_st{reason = Reason, type= cancel, hash = Hash, bad_req = 'bad-request'}.


-spec ms_to_datetime_string(Ms :: non_neg_integer()) -> {string(), string()}.
ms_to_datetime_string(Ms) ->
    case Ms of
        undefined -> {"unknown date", "unknown time"};
        _ ->
            {{Y, Mo, D}, {H, Min, S}} = util:timestamp_to_datetime(Ms),
            Date = io_lib:format("~4..0B-~2..0B-~2..0B", [Y, Mo, D]),
            Time = io_lib:format("~2..0B:~2..0B:~2..0B", [H, Min, S]),
            {Date, Time}
    end.

