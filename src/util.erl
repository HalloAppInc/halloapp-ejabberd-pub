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
-include("stanza.hrl").
-include("packets.hrl").
-include("ha_types.hrl").
-include("time.hrl").

-define(NOISE_STATIC_KEY, <<"static_key">>).
-define(NOISE_SERVER_CERTIFICATE, <<"server_certificate">>).

-define(STEST_SHARD_NUM, 100).

-ifdef(TEST).
-export([is_main_stest/2]).
-endif.

-export([
    is_android_user/1,
    is_ios_user/1,
    get_content_id/1,
    timestamp_to_binary/1,
    cur_timestamp/0,
    timestamp_secs_to_integer/1,
    get_host/0,
    get_upload_server/0,
    get_noise_key_material/0,
    get_noise_static_pubkey/0,
    get_date/1,
    now_ms/0,
    now/0,
    now_binary/0,
    now_prettystring/0,
    tsms_to_date/1,
    round_to_minute/1,
    random_str/1,
    random_shuffle/1,
    type/1,
    to_integer/1,
    to_integer_maybe/1,
    to_integer_zero/1,
    to_float/1,
    to_float_maybe/1,
    to_atom/1,
    to_atom_maybe/1,
    to_binary/1,
    to_binary_maybe/1,
    to_list/1,
    to_list_maybe/1,
    list_to_map/1,
    ms_to_sec/1,
    sec_to_ms/1,
    check_and_convert_ms_to_sec/1,
    check_and_convert_sec_to_ms/1,
    send_after/2,
    timestamp_to_datetime/1,
    decode_base_64/1,
    is_test_number/1,
    is_apple_number/1,
    is_google_number/1,
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
    get_protocol/1,
    is_ipv4/1,
    is_ipv6/1,
    parse_ip_address/1,
    add_and_merge_maps/2,
    maybe_base64_encode/1,
    maybe_base64_decode/1,
    yesterday/0,
    day_before/1,
    normalize_scores/1,
    get_machine_name/0,
    is_machine_stest/0,
    repair_utf8/1,
    get_media_type/1,
    get_detailed_media_type/1,
    is_voip_incoming_message/1,
    rev_while/2,
    map_intersect/2,
    map_intersect_with/3, 
    map_merge_with/3,
    map_from_keys/2,
    remove_cc_from_langid/1,
    get_monitor_phone/0,
    is_monitor_phone/1,
    is_node_stest/0,
    is_node_stest/1,
    is_main_stest/0,
    get_nodes/0,
    get_node/0,
    index_of/2,
    get_stat_namespace/1,
    secs_to_hrs/1,
    uniq/1,
    is_dst_america/1,
    is_dst_europe/1
]).


-define(PASSWORD_SIZE, 24).

-spec is_android_user(Uid :: binary()) -> boolean().
is_android_user(Uid) ->
    case model_accounts:get_client_version(Uid) of
        {ok, ClientVersion} ->
            util_ua:is_android(ClientVersion);
        {error, _} -> false
    end.


-spec is_ios_user(Uid :: binary()) -> boolean().
is_ios_user(Uid) ->
    case model_accounts:get_client_version(Uid) of
        {ok, ClientVersion} ->
            util_ua:is_ios(ClientVersion);
        {error, _} -> false
    end.


%% TODO(murali@): extend this for all types of payload.
-spec get_content_id(Payload :: term()) -> binary() | undefined.
get_content_id(#pb_feed_item{item = #pb_post{} = Post}) -> Post#pb_post.id;
get_content_id(#pb_feed_item{item = #pb_comment{} = Comment}) -> Comment#pb_comment.id;
get_content_id(#pb_group_feed_item{item = #pb_post{} = Post}) -> Post#pb_post.id;
get_content_id(#pb_group_feed_item{item = #pb_comment{} = Comment}) -> Comment#pb_comment.id;
get_content_id(_) -> undefined.


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
    % TODO: mod_aws caches the secret, but we can save ourselves the
    % json decoding and the rest of the computation
    NoiseSecret = jiffy:decode(mod_aws:get_secret(config:get_noise_secret_name()), [return_maps]),
    NoiseStaticKeyPair = maps:get(?NOISE_STATIC_KEY, NoiseSecret),
    NoiseCertificate = maps:get(?NOISE_SERVER_CERTIFICATE, NoiseSecret),

    NoiseStaticKey = base64:decode(NoiseStaticKeyPair),
    [{_, ServerPublic, _}, {_, ServerSecret, _}] = public_key:pem_decode(NoiseStaticKey),
    ServerKeypair = enoise_keypair:new(dh25519, ServerSecret, ServerPublic),

    [{_, Certificate, _}] = public_key:pem_decode(base64:decode(NoiseCertificate)),
    {ServerKeypair, Certificate}.


get_noise_static_pubkey() ->
    NoiseSecret = jiffy:decode(mod_aws:get_secret(config:get_noise_secret_name()), [return_maps]),
    NoiseStaticKeyPair = maps:get(?NOISE_STATIC_KEY, NoiseSecret),

    NoiseStaticKey = base64:decode(NoiseStaticKeyPair),
    [{_, ServerStaticPubKey, _}, {_, _, _}] = public_key:pem_decode(NoiseStaticKey),
    ServerStaticPubKey.


-spec get_date(TimeInSec :: integer()) -> integer().
get_date(TimeInSec) ->
    {{_,_,Day}, {_,_,_}} = calendar:system_time_to_universal_time(TimeInSec, second),
    Day.

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


-spec to_integer(any()) -> integer() | no_return().
to_integer(Data) ->
    case type(Data) of
        "binary" -> binary_to_integer(Data);
        "list" -> list_to_integer(Data);
        "float" -> round(Data);
        "integer" -> Data;
        _ ->
            erlang:error(badarg, [Data])
    end.

-spec to_integer_maybe(any()) -> maybe(integer()).
to_integer_maybe(undefined) -> undefined;
to_integer_maybe(Data) ->
    try to_integer(Data)
    catch
        error : badarg : _ ->
            ?ERROR("Failed converting data to integer: ~p", [Data]),
            undefined
    end.

to_integer_zero(Bin) ->
    case util:to_integer_maybe(Bin) of
      undefined -> 0;
      Int -> Int
    end.


-spec to_float(any()) -> float() | no_return().
to_float(Data) when is_float(Data) ->
    Data;
to_float(Data) when is_integer(Data) ->
    float(Data);
to_float(Data) when is_list(Data) ->
    case string:to_float(Data) of
        {Float, ""} -> Float;
        {error, _} -> float(to_integer(Data));
        _ -> erlang:error(badarg, [Data])
    end;
to_float(Data) when is_binary(Data) ->
    to_float(binary_to_list(Data));
to_float(Data) ->
    erlang:error(badarg, [Data]).

-spec to_float_maybe(Data :: any()) -> maybe(float()).
to_float_maybe(Data) ->
    try to_float(Data)
    catch
        error : badarg ->
            ?ERROR("Failed converting data to float: ~p", [Data]),
            undefined
    end.

-spec to_atom(Data :: any()) -> atom() | no_return().
to_atom(Data) ->
    case type(Data) of
        "binary" -> binary_to_atom(Data, utf8);
        "atom" -> Data;
        "boolean" -> Data;
        "list" -> list_to_atom(Data);
        _ ->
            erlang:error(badarg, [Data])
    end.

-spec to_atom_maybe(Data :: any()) -> maybe(atom()).
to_atom_maybe(Data) ->
    try to_atom(Data)
    catch
        error : badarg ->
            ?ERROR("failed to convert to atom: ~p", [Data]),
            undefined
    end.

-spec to_binary(Data :: any()) -> binary() | no_return().
to_binary(Data) ->
    case type(Data) of
        "binary" -> Data;
        "boolean" -> atom_to_binary(Data, utf8);
        "atom" -> atom_to_binary(Data, utf8);
        "list" -> list_to_binary(Data);
        "integer" -> integer_to_binary(Data);
        "float" -> float_to_binary(Data, [{decimals, 15}, compact]);
        _ ->
            erlang:error(badarg, [Data])
    end.

% returns empty binary on error
-spec to_binary_maybe(Data :: any()) -> maybe(binary()).
to_binary_maybe(Data) ->
    try to_binary(Data)
    catch
        error : badarg ->
            ?ERROR("Failed converting data to binary: ~p", [Data]),
            % TODO: change to undefined
            <<>>
    end.

-spec to_list(Data :: list() | binary() | atom() | boolean() | integer() | float()) -> maybe(list()).
to_list(Data) ->
    case type(Data) of
        "list" -> Data;
        "binary" -> binary_to_list(Data);
        "atom" -> atom_to_list(Data);
        "boolean" -> atom_to_list(Data);
        "integer" -> integer_to_list(Data);
        "float" -> float_to_list(Data, [{decimals, 15}, compact]);
        _ ->
            erlang:error(badarg, [Data])
    end.

-spec to_list_maybe(Data :: any()) -> maybe(list()).
to_list_maybe(Data) ->
    try to_list(Data)
    catch
        error : badarg ->
            ?ERROR("Failed converting data to list: ~p", [Data]),
            undefined
    end.

list_to_map(L) ->
    list_to_map(L, #{}).

list_to_map([K, V | Rest], Map) ->
    Map2 = maps:put(K, V, Map),
    list_to_map(Rest, Map2);
list_to_map([_X], _Map) ->
    erlang:error(badarg);
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


-spec sec_to_ms(Seconds :: integer()) -> integer().
sec_to_ms(Seconds) when is_integer(Seconds) ->
    Seconds * 1000.


-spec check_and_convert_ms_to_sec(Timestamp :: integer()) -> integer().
check_and_convert_ms_to_sec(Timestamp) when is_integer(Timestamp), Timestamp < 0 -> Timestamp;
check_and_convert_ms_to_sec(Timestamp) when is_integer(Timestamp) ->
    case Timestamp of
        %% 1597095974000 is epoch timestamp in ms for august 10th 2020.
        %% any timestamp larger than that is definitely milliseconds.
        %% else, we assume it is seconds.
        MilliSeconds when MilliSeconds > 1597095974000 ->
            Seconds = MilliSeconds div 1000,
            ?INFO("changed timestamp to Seconds: ~p from MilliSeconds: ~p", [Seconds, MilliSeconds]),
            Seconds;
        Seconds ->
            Seconds
    end.


-spec check_and_convert_sec_to_ms(Timestamp :: integer()) -> integer().
check_and_convert_sec_to_ms(Timestamp) when is_integer(Timestamp), Timestamp < 0 -> Timestamp;
check_and_convert_sec_to_ms(Timestamp) when is_integer(Timestamp) ->
    case Timestamp of
        %% 1029014873000 is epoch timestamp in ms for august 10th 2002.
        %% any timestamp samller than that is definitely seconds.
        %% else, we assume it is milliseconds.
        Seconds when Seconds < 1029014873000 ->
            MilliSeconds = Seconds * 1000,
            ?INFO("changed timestamp to MilliSeconds: ~p from Seconds: ~p", [MilliSeconds, Seconds]),
            MilliSeconds;
        MilliSeconds ->
            MilliSeconds
    end.


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


-spec is_google_number(Phone :: binary()) -> boolean().
is_google_number(Phone) ->
    case Phone of
        <<"16504992804">> -> true;
        <<"916504992804">> -> true;
        _ -> false
    end.

-spec is_apple_number(Phone :: binary()) -> boolean().
is_apple_number(Phone) ->
    case Phone of
        <<"16693334444">> -> true;
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


-spec ms_to_datetime_string(Ms :: maybe(non_neg_integer())) -> {string(), string()}.
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
        <<"s-test">> -> ?STEST_SHARD_NUM;  %% deprecated naming convention for s-test
        <<"s-test", N/binary>> -> ?STEST_SHARD_NUM + to_integer(N);
        <<"prod", N/binary>> -> to_integer(N);
        _ -> undefined
    end.

-spec get_stest_shard_num() -> non_neg_integer().
get_stest_shard_num() -> ?STEST_SHARD_NUM.

-spec get_payload_type(Packet :: stanza()) -> atom().
get_payload_type(#pb_iq{} = Pkt) -> pb:get_payload_type(Pkt);
get_payload_type(#pb_msg{} = Pkt) -> pb:get_payload_type(Pkt);
get_payload_type(_) -> undefined.


%% Currently, we only set/get timestamps for different message stanzas:
%% chat/group_chat/silent_chat/seen/delivery/playedreceipt stanzas.

-spec set_timestamp(message(), integer()) -> stanza().
set_timestamp(#pb_msg{payload = #pb_group_chat{} = GroupChat} = Msg, T) ->
    Msg#pb_msg{payload = GroupChat#pb_group_chat{timestamp = T}};

set_timestamp(#pb_msg{payload = #pb_group_chat_stanza{} = GroupChatStanza} = Msg, T) ->
    Msg#pb_msg{payload = GroupChatStanza#pb_group_chat_stanza{timestamp = T}};

set_timestamp(#pb_msg{payload = #pb_chat_stanza{} = Chat} = Msg, T) ->
    Msg#pb_msg{payload = Chat#pb_chat_stanza{timestamp = T}};

set_timestamp(#pb_msg{payload = #pb_seen_receipt{} = SeenReceipt} = Msg, T) ->
    Msg#pb_msg{payload = SeenReceipt#pb_seen_receipt{timestamp = T}};

set_timestamp(#pb_msg{payload = #pb_screenshot_receipt{} = ScreenshotReceipt} = Msg, T) ->
    Msg#pb_msg{payload = ScreenshotReceipt#pb_screenshot_receipt{timestamp = T}};

set_timestamp(#pb_msg{payload = #pb_delivery_receipt{} = DeliveryReceipt} = Msg, T) ->
    Msg#pb_msg{payload = DeliveryReceipt#pb_delivery_receipt{timestamp = T}};

set_timestamp(#pb_msg{payload = #pb_silent_chat_stanza{chat_stanza = #pb_chat_stanza{} = Chat} = SilentChat} = Msg, T) ->
    Msg#pb_msg{payload = SilentChat#pb_silent_chat_stanza{chat_stanza = Chat#pb_chat_stanza{timestamp = T}}};

set_timestamp(#pb_msg{payload = #pb_played_receipt{} = PlayedReceipt} = Msg, T) ->
    Msg#pb_msg{payload = PlayedReceipt#pb_played_receipt{timestamp = T}};

set_timestamp(#pb_msg{payload = #pb_saved_receipt{} = SavedReceipt} = Msg, T) ->
    Msg#pb_msg{payload = SavedReceipt#pb_saved_receipt{timestamp = T}};

set_timestamp(Packet, _T) -> Packet.


-spec get_protocol({inet:address(), any()}) -> ipv4 | ipv6.
get_protocol({{_, _, _, _}, _}) ->
    ipv4;
get_protocol({{0, 0, 0, 0, 0, _, _, _}, _}) ->
    ipv4;
get_protocol({{_, _, _, _, _, _, _, _}, _}) ->
    ipv6.


-spec is_ipv4(inet:address()) -> boolean().
is_ipv4(IpAddress) ->
    get_protocol({IpAddress, undefined}) =:= ipv4.


-spec is_ipv6(inet:address()) -> boolean().
is_ipv6(IpAddress) ->
    get_protocol({IpAddress, undefined}) =:= ipv6.


-spec parse_ip_address({inet:address(), inet:port_number()}) -> list().
parse_ip_address({IpAddress, _Port}) ->
    case util:is_ipv4(IpAddress) of
        true -> inet:ntoa(inet:ipv4_mapped_ipv6_address(IpAddress));
        false -> inet:ntoa(IpAddress)
    end.


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



%% takes a map/list of gateway scores and returns normalized scores between 0 & 1
-spec normalize_scores(Scores :: list() | map()) -> list() | map().
normalize_scores(Scores) when is_list(Scores)->
    Sum = lists:sum(Scores),
    NormalizedList = [XX/Sum || XX <- Scores],
    NormalizedList;
normalize_scores(Scores) when is_map(Scores)->
    Sum = lists:sum(maps:values(Scores)),
    NormalizedScores = maps:map(
        fun(_GW, Score) -> Score/Sum end,
        Scores),
    NormalizedScores.

-spec get_machine_name() -> binary().
get_machine_name() ->
    {ok, Name} = inet:gethostname(),
    util:to_binary(Name).


-spec is_machine_stest() -> boolean().
is_machine_stest() ->
    case binary:match(get_machine_name(), <<"s-test">>) of
        nomatch -> false;
        _ -> true
    end.


-spec is_node_stest() -> boolean().
is_node_stest() ->
    is_node_stest(node()).


-spec is_node_stest(Node :: atom()) -> boolean().
is_node_stest(Node) ->
    case binary:match(util:to_binary(Node), <<"s-test">>) of
        nomatch -> false;
        _ -> true
    end.


-spec repair_utf8(Bin :: binary()) -> binary().
repair_utf8(<<>>) -> <<>>;
repair_utf8(Bin) when is_binary(Bin) ->
    NewBin = binary:part(Bin, {0, byte_size(Bin) -1}),
    case unicode:characters_to_nfc_list(NewBin) of
        {error, _, _} -> repair_utf8(NewBin);
        _ -> NewBin
    end.


-spec get_media_type(MediaCounters :: pb_media_counters()) -> maybe(atom()).
get_media_type(undefined) -> undefined;
get_media_type(MediaCounters) ->
    NumImages = MediaCounters#pb_media_counters.num_images,
    NumVideos = MediaCounters#pb_media_counters.num_videos,
    NumAudio = MediaCounters#pb_media_counters.num_audio,

    case {NumImages, NumVideos, NumAudio} of
        {0, 0, 0} -> text;
        {_, _, _} when NumAudio =:= 0 -> album;
        _ -> audio
    end.


-spec get_detailed_media_type(MediaCounters :: pb_media_counters()) -> maybe(atom()).
get_detailed_media_type(undefined) -> undefined;
get_detailed_media_type(MediaCounters) ->
    NumImages = MediaCounters#pb_media_counters.num_images,
    NumVideos = MediaCounters#pb_media_counters.num_videos,
    NumAudio = MediaCounters#pb_media_counters.num_audio,

    case {NumImages, NumVideos, NumAudio} of
        {0, 0, 0} -> text;
        {_, _, _} when NumAudio =:= 0; NumAudio =:= undefined ->
            if
                NumImages =:= 1 andalso NumVideos =:= 0 -> image;
                NumImages > 1 andalso NumVideos =:= 0 -> images;
                NumVideos =:= 1 andalso NumImages =:= 0 -> video;
                NumVideos > 1 andalso NumImages =:= 0 -> videos;
                true -> album
            end;
        _ -> audio
    end.


-spec is_voip_incoming_message(Message :: message()) -> boolean().
is_voip_incoming_message(#pb_msg{} = Message) ->
    case get_payload_type(Message) of
        pb_incoming_call -> true;
        _ -> false
    end.


%% Reverse while loop.
rev_while(0, _F) -> ok;
rev_while(N, F) ->
    erlang:apply(F, [N]),
    rev_while(N - 1, F).


% Useful Map functions that aren't implemented in OTP 23
map_intersect(Map1, Map2) -> map_intersect_with( fun (_, _, V2) -> V2 end, Map1, Map2).
map_intersect_with(Fun, Map1, Map2) ->
    Dupes = maps:filter(fun (Key, _V) -> 
                            maps:is_key(Key, Map2) 
                        end, 
                        Map1),
    maps:map(fun (Key, V1) -> 
                Fun(Key, V1, maps:get(Key, Map2)) 
            end, 
            Dupes).

map_merge_with(Fun, Map1, Map2) ->
    Dupes = maps:filter(fun (Key, _V) -> 
                            maps:is_key(Key, Map2) 
                        end, 
                        Map1),
    UpdatedDupes = maps:map(fun (Key, V1) -> 
                                Fun(Key, V1, maps:get(Key, Map2)) 
                            end, 
                            Dupes),
    Merge1 = maps:merge(Map1, UpdatedDupes),
    maps:merge(Map2, Merge1).

map_from_keys(Keys, Value) ->
    lists:foldl(
        fun (Key, Acc) ->
            maps:put(Key, Value, Acc)
        end,
        #{},
        Keys).

remove_cc_from_langid(RawLangId) when RawLangId =:= undefined ->
    RawLangId;
remove_cc_from_langid(RawLangId) ->
    case binary:match(RawLangId, <<"-">>) of
        nomatch -> RawLangId;
        _ ->
            [LangId, _CC] = binary:split(RawLangId, <<"-">>),
            LangId
    end.


get_monitor_phone() ->
    Digit1 = util:to_binary(random:uniform(9)),
    Digit2 = util:to_binary(random:uniform(9)),
    <<"161755512", Digit1/binary, Digit2/binary>>.


-spec is_monitor_phone(Phone :: binary()) -> boolean().
is_monitor_phone(Phone) ->
    case binary:match(Phone, <<"161755512">>) of
        nomatch -> false;
        _ -> true
    end.


get_nodes() -> nodes().

get_node() -> node().

%% Used whether to run specific jobs or not.
-spec is_main_stest() -> boolean().
is_main_stest() ->
    is_main_stest(node(), nodes()).

is_main_stest(Node, Nodes) ->
    ShardNums = lists:filtermap(
        fun(N) ->
            case is_node_stest(N) of
                false -> false;
                true -> {true, get_shard(N)}
            end
        end, Nodes),
    case length(ShardNums) =:= 0 of
        true ->
            case config:get_hallo_env() of
                localhost -> false;
                _ ->
                    is_node_stest(Node)
            end;
        false ->
            OwnShard = get_shard(Node),
            is_node_stest(Node) andalso OwnShard < lists:min(ShardNums)
    end.


index_of(Item, List) -> index_of(Item, List, 1).

index_of(_, [], _)  -> undefined;
index_of(Item, [Item|_], Index) -> Index;
index_of(Item, [_|Tl], Index) -> index_of(Item, Tl, Index+1).


%% Takes an app_type atom, user agent binary, or uid binary
get_stat_namespace(?HALLOAPP) -> "HA";
get_stat_namespace(?KATCHUP) -> "KA";
get_stat_namespace(AppType) when is_atom(AppType) ->
    ?ERROR("Unexpected AppType: ~p", [AppType]),
    "HA";
get_stat_namespace(Bin) when is_binary(Bin) ->
    case util_uid:looks_like_uid(Bin) of
        true -> get_stat_namespace(util_uid:get_app_type(Bin));
        false ->
            case binary:match(Bin, <<"Katchup">>) of
                nomatch ->
                    case binary:match(Bin, <<"HalloApp">>) of
                        nomatch ->
                            case binary:match(Bin, <<"Android0.">>) of
                                {_D1, _D2} -> "HA";
                                nomatch ->
                                    ?ERROR("Unexpected binary for stat namespace resolution: ~p", [Bin]),
                                    "HA"
                            end;
                        _ -> "HA"
                    end;
                _ -> "KA"
            end
    end;
get_stat_namespace(A) ->
    ?ERROR("Unexpected arg: ~p", [A]).


secs_to_hrs(Secs) ->
    round(Secs / ?HOURS).


%% preserves the order.
uniq(L) when is_list(L) ->
    uniq_1(L, #{}).

uniq_1([X | Xs], M) ->
    case is_map_key(X, M) of
        true ->
            uniq_1(Xs, M);
        false ->
            [X | uniq_1(Xs, M#{X => true})]
    end;
uniq_1([], _) ->
    [].


is_dst_america(AmericaTimestamp) ->
    %% In the US, DST rules are as follows:
    %%   * begins at 2:00am on the second Sunday of March (at 2am the local time time skips ahead to 3am)
    %%   * ends at 2:00am on the first Sunday of November (at 2am the local time becomes 1am and that hour is repeated)
    {{Year, Month, Date}, {_, _, _}} =
        calendar:system_time_to_universal_time(AmericaTimestamp, second),
    if
        Month < 3 orelse Month > 11 ->
            %% Between November and March, there is no DST
            false;
        Month > 3 andalso Month < 11 ->
            %% Between March and November, there is DST
            true;
        Month =:= 3 ->
            %% DST iff Date is on or after 2nd Sunday
            %% Calculate date of second Sunday
            FirstDayNum = calendar:day_of_the_week({Year, Month, 1}),  %% DayNum = 7 is Sunday
            DaysToFirstSunday = 7 - FirstDayNum,
            SecondSundayDate = 7 + DaysToFirstSunday,
            Date >= SecondSundayDate;
        Month =:= 11 ->
            %% DST iff Date is before the 1st Sunday
            %% Calculate date of first Sunday
            FirstDayNum = calendar:day_of_the_week({Year, Month, 1}),  %% DayNum = 7 is Sunday
            DaysToFirstSunday = 7 - FirstDayNum,
            Date < DaysToFirstSunday
    end.


is_dst_europe(EuropeTimestamp) ->
    %% In Europe, DST rules are as follows:
    %%   * begins on the last Sunday of March
    %%   * ends on the last Sunday of October
    {{Year, Month, Day}, {_, _, _}} =
        calendar:system_time_to_universal_time(EuropeTimestamp, second),
    if
        Month < 3 orelse Month > 10 ->
            %% Between October and March, there is no DST
            false;
        Month > 3 andalso Month < 10 ->
            %% Between March and October, there is DST
            true;
        Month =:= 3 ->
            %% DST iff Date is on or last Sunday
            LastDayNum = calendar:day_of_the_week({Year, 3, 31}),  %% DayNum = 7 is Sunday
            LastSundayDay = case LastDayNum of
                7 -> 31;
                _ -> 31 - LastDayNum
            end,
            Day >= LastSundayDay;
        Month =:= 10 ->
            %% DST iff Date is before the last Sunday
            LastDayNum = calendar:day_of_the_week({Year, 10, 31}),  %% DayNum = 7 is Sunday
            LastSundayDay = case LastDayNum of
                7 -> 31;
                _ -> 31 - LastDayNum
            end,
            Day < LastSundayDay
    end.
