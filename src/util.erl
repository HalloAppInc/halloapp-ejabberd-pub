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
-include("packets.hrl").
-include("ha_types.hrl").

-define(NOISE_STATIC_KEY, <<"static_key">>).
-define(NOISE_SERVER_CERTIFICATE, <<"server_certificate">>).

-define(STEST_SHARD_NUM, 100).

-export([
    timestamp_to_binary/1,
    cur_timestamp/0,
    timestamp_secs_to_integer/1,
    get_host/0,
    get_upload_server/0,
    get_noise_key_material/0,
    now_ms/0,
    now/0,
    now_binary/0,
    now_prettystring/0,
    tsms_to_date/1,
    round_to_minute/1,
    random_str/1,
    random_shuffle/1,
    generate_password/0,
    type/1,
    to_integer/1,
    to_atom/1,
    to_binary/1,
    to_list/1,
    list_to_map/1,
    ms_to_sec/1,
    send_after/2,
    timestamp_to_datetime/1,
    decode_base_64/1,
    is_test_number/1,
    join_binary/2,
    join_binary/3,
    join_strings/2,
    err/1,
    ms_to_datetime_string/1,
    get_shard/0,
    get_shard/1,
    get_stest_shard_num/0,
    get_payload_type/1,
    set_timestamp/2,
    get_timestamp/1,
    get_protocol/1,
    add_and_merge_maps/2,
    maybe_base64_encode/1,
    maybe_base64_decode/1,
    yesterday/0,
    normalize_scores/1
]).


-define(PASSWORD_SIZE, 24).

-spec get_host() -> binary().
get_host() ->
    case config:is_testing_env() of
        true ->
            <<"s.halloapp.net">>;
        false ->
            [H | []] = ejabberd_option:hosts(),
            H
    end.

-spec get_upload_server() -> binary().
get_upload_server() ->
    <<"upload.s.halloapp.net">>.


get_noise_key_material() ->
    [{?NOISE_STATIC_KEY, NoiseStaticKeyPair}, {?NOISE_SERVER_CERTIFICATE, NoiseCertificate}] =
            jsx:decode(mod_aws:get_secret(config:get_noise_secret_name())),
    NoiseStaticKey = base64:decode(NoiseStaticKeyPair),
    [{_, ServerPublic, _}, {_, ServerSecret, _}] = public_key:pem_decode(NoiseStaticKey),
    ServerKeypair = enoise_keypair:new(dh25519, ServerSecret, ServerPublic),

    [{_, Certificate, _}] = public_key:pem_decode(base64:decode(NoiseCertificate)),
    {ServerKeypair, Certificate}.


-spec now_ms() -> integer().
now_ms() ->
    os:system_time(millisecond).

-spec now() -> integer().
now() ->
    os:system_time(second).


-spec now_binary() -> binary().
now_binary() ->
    integer_to_binary(util:now()).


-spec now_prettystring() -> string().
now_prettystring() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    join_strings([
        integer_to_list(Year),
        binary_to_list(iolist_to_binary(io_lib:format("~2..0w", [Month]))),
        binary_to_list(iolist_to_binary(io_lib:format("~2..0w", [Day]))),
        binary_to_list(iolist_to_binary(io_lib:format("~2..0w", [Hour]))),
        binary_to_list(iolist_to_binary(io_lib:format("~2..0w", [Minute]))),
        binary_to_list(iolist_to_binary(io_lib:format("~2..0w", [Second])))
    ], "-").



-spec tsms_to_date(TsMs :: integer()) -> {integer(), integer(), integer()}.
tsms_to_date(TsMs) ->
    {Date, _} = calendar:system_time_to_local_time(TsMs, millisecond),
    Date.


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


%% Returns random string containing [a-zA-Z0-9] and -_
-spec random_str(Size :: integer()) -> binary().
random_str(Size) ->
    SS = base64url:encode(crypto:strong_rand_bytes(Size)),
    binary:part(SS, 0, Size).

-spec random_shuffle(L :: list(any())) -> list(any()).
random_shuffle(L) ->
    % pair each element of the list with a random number, sort based on the random number, then extract the values
    % https://stackoverflow.com/a/8820501
    % this is also O(N*logN) but is much faster then O(N) solutions implementend in erlang
    % https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle
    [X || {_, X} <- lists:sort([{random:uniform(), N} || N <- L])].

-spec generate_password() -> binary().
generate_password() ->
    random_str(?PASSWORD_SIZE).


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
            ?ERROR("Failed converting data to integer: ~p", [Data]),
            undefined
    end.


to_atom(Data) ->
    case type(Data) of
        "binary" -> binary_to_atom(Data, utf8);
        "atom" -> Data;
        "boolean" -> Data;
        "list" -> list_to_atom(Data);
        _ ->
            ?ERROR("Failed converting data to atom: ~p", [Data]),
            undefined
    end.

% TODO: add spec
to_binary(Data) ->
    case type(Data) of
        "binary" -> Data;
        "atom" -> atom_to_binary(Data, utf8);
        "boolean" -> atom_to_binary(Data, utf8);
        "list" -> list_to_binary(Data);
        "integer" -> integer_to_binary(Data);
        "float" -> float_to_binary(Data);
        _ ->
            ?ERROR("Failed converting data to binary: ~p", [Data]),
            % TODO: change to undefined
            <<>>
    end.

-spec to_list(Data :: list() | binary() | atom() | boolean() | integer()) -> maybe(list()).
to_list(Data) ->
    case type(Data) of
        "list" -> Data;
        "binary" -> binary_to_list(Data);
        "atom" -> atom_to_list(Data);
        "boolean" -> atom_to_list(Data);
        "integer" -> integer_to_list(Data);
        "float" -> float_to_list(Data);
        _ ->
            ?ERROR("Failed converting data to list: ~p", [Data]),
            undefined
    end.


list_to_map(L) ->
    list_to_map(L, #{}).

list_to_map([K, V | Rest], Map) ->
    Map2 = maps:put(K, V, Map),
    list_to_map(Rest, Map2);
list_to_map([], Map) ->
    Map.


%% iterates over map2.
-spec add_and_merge_maps(Map1 :: map(), Map2 :: map()) -> map().
add_and_merge_maps(Map1, Map2) ->
    maps:fold(
        fun(K, V, Map) ->
            maps:update_with(K, fun(X) -> util:to_integer(X) + util:to_integer(V) end, util:to_integer(V), Map)
        end, Map1, Map2).


-spec ms_to_sec(MilliSeconds :: integer()) -> integer().
ms_to_sec(MilliSeconds) when is_integer(MilliSeconds) ->
    MilliSeconds div 1000.


-spec send_after(TimeoutMs :: integer(), Msg :: any()) -> reference().
send_after(TimeoutMs, Msg) ->
    NewTimer = erlang:send_after(TimeoutMs, self(), Msg),
    NewTimer.


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


-spec join_strings([string()], string()) -> string().
join_strings(Components, Separator) ->
    lists:append(lists:join(Separator, Components)).


-spec err(Reason :: atom()) -> pb_error_stanza().
err(Reason) ->
    #pb_error_stanza{reason = util:to_binary(Reason)}.


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


-spec get_shard() -> maybe(non_neg_integer()).
get_shard() ->
    get_shard(node()).

-spec get_shard(Node :: atom()) -> maybe(non_neg_integer()).
get_shard(Node) ->
    [_Name, NodeBin] = binary:split(to_binary(Node), <<"@">>),
    case NodeBin of
        <<"s-test">> -> ?STEST_SHARD_NUM;
        <<"prod", N/binary>> -> to_integer(N);
        _ -> undefined
    end.

-spec get_stest_shard_num() -> non_neg_integer().
get_stest_shard_num() -> ?STEST_SHARD_NUM.

-spec get_payload_type(Packet :: stanza()) -> atom.
get_payload_type(#pb_iq{} = Pkt) -> pb:get_payload_type(Pkt);
get_payload_type(#pb_msg{} = Pkt) -> pb:get_payload_type(Pkt);
get_payload_type(_) -> undefined.


%% Currently, we only set/get timestamps for different message stanzas:
%% chat/group_chat/silent_chat/seen/delivery/playedreceipt stanzas.

-spec set_timestamp(pb_msg(), binary()) -> stanza().
set_timestamp(#pb_msg{payload = #pb_group_chat{} = GroupChat} = Msg, T) ->
    Msg#pb_msg{payload = GroupChat#pb_group_chat{timestamp = T}};
set_timestamp(#pb_msg{payload = #pb_chat_stanza{} = Chat} = Msg, T) ->
    Msg#pb_msg{payload = Chat#pb_chat_stanza{timestamp = T}};
set_timestamp(#pb_msg{payload = #pb_seen_receipt{} = SeenReceipt} = Msg, T) ->
    Msg#pb_msg{payload = SeenReceipt#pb_seen_receipt{timestamp = T}};
set_timestamp(#pb_msg{payload = #pb_delivery_receipt{} = DeliveryReceipt} = Msg, T) ->
    Msg#pb_msg{payload = DeliveryReceipt#pb_delivery_receipt{timestamp = T}};
set_timestamp(#pb_msg{payload = #pb_silent_chat_stanza{chat_stanza = #pb_chat_stanza{} = Chat} = SilentChat} = Msg, T) ->
    Msg#pb_msg{payload = SilentChat#pb_silent_chat_stanza{chat_stanza = Chat#pb_chat_stanza{timestamp = T}}};
set_timestamp(#pb_msg{payload = #pb_played_receipt{} = PlayedReceipt} = Msg, T) ->
    Msg#pb_msg{payload = PlayedReceipt#pb_played_receipt{timestamp = T}};
set_timestamp(Packet, _T) -> Packet.


-spec get_timestamp(pb_msg()) -> binary() | undefined.
get_timestamp(#pb_msg{payload = #pb_chat_stanza{timestamp = T}}) -> T;
get_timestamp(#pb_msg{payload = #pb_silent_chat_stanza{chat_stanza = #pb_chat_stanza{timestamp = T}}}) -> T;
get_timestamp(#pb_msg{payload = #pb_seen_receipt{timestamp = T}}) -> T;
get_timestamp(#pb_msg{payload = #pb_delivery_receipt{timestamp = T}}) -> T;
get_timestamp(#pb_msg{payload = #pb_played_receipt{timestamp = T}}) -> T;
get_timestamp(#pb_msg{}) -> undefined.


-spec get_protocol({inet:address(), inet:port_number()}) -> ipv4 | ipv6.
get_protocol({{_, _, _, _}, _}) ->
    ipv4;
get_protocol({{0, 0, 0, 0, 0, _, _, _}, _}) ->
    ipv4;
get_protocol({{_, _, _, _, _, _, _, _}, _}) ->
    ipv6.


-spec maybe_base64_encode(maybe(binary())) -> maybe(binary()).
maybe_base64_encode(undefined) -> undefined;
maybe_base64_encode(Data) -> base64:encode(Data).


-spec maybe_base64_decode(maybe(binary())) -> maybe(binary()).
maybe_base64_decode(undefined) -> undefined;
maybe_base64_decode(Data) -> base64:decode(Data).


-spec yesterday() -> calendar:date().
yesterday() ->
    {Date, _} = calendar:universal_time(),
    calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(Date) - 1).

-spec day_before(Date :: calendar:date()) -> calendar:date().
day_before(Date) ->
    calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(Date) - 1).


%% takes a list of scores and returns normalized scores between 0 & 1
-spec normalize_scores(ScoreList :: list()) -> list().
normalize_scores(ScoreList) ->
    Sum = lists:sum(ScoreList),
    NormalizedList = [XX/Sum || XX <- ScoreList],
    NormalizedList.

