%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 08. Jun 2020 1:30 PM
%%%-------------------------------------------------------------------
-module(util_redis).
-author("nikola").

-include("util_redis.hrl").

%% API
-export([
    parse_info/1,
    decode_ts/1,
    decode_int/1,
    decode_maybe_binary/1,
    encode_maybe_binary/1,
    q/2,
    qp/2,
    decode_binary/1,
    eredis_hash/1,
    encode_boolean/1,
    decode_boolean/1,
    decode_boolean/2,
    encode_b64/1,
    decode_b64/1,
    parse_zrange_with_scores/1,
    run_qmn/2,
    verify_ok/1
]).


%% for parsing INFO command results
-spec parse_info(RawResult :: binary()) -> [{Name :: binary(), Value :: binary()}].
parse_info(RawResult) ->
    Terms = binary:split(RawResult, <<"\r\n">>, [global, trim_all]),
    lists:map(
        fun(Term) ->
            case binary:split(Term, <<":">>, [global]) of
                [Name, Value] -> {Name, Value};
                _ -> {undefined, undefined}
            end
        end,
        Terms).


%% TODO(murali@): Update to use this util function in other redis model files.
eredis_hash(Key) when is_list(Key) ->
    crc16_redis:hash(Key) rem ?NUM_SLOTS;
eredis_hash(Key) when is_binary(Key) ->
    crc16_redis:hash(binary_to_list(Key)) rem ?NUM_SLOTS.


decode_ts(TsMsBinary) ->
    decode_int(TsMsBinary).


decode_int(Bin) ->
    case Bin of
        undefined -> undefined;
        <<"undefined">> -> undefined;
        _ -> binary_to_integer(Bin)
    end.


decode_binary(<<"undefined">>) -> undefined;
decode_binary(Bin) -> Bin.


-spec decode_maybe_binary(Bin :: binary()) -> undefined | binary().
decode_maybe_binary(<<>>) -> undefined;
decode_maybe_binary(Bin) -> Bin.


-spec encode_maybe_binary(Bin :: undefined | binary()) -> binary().
encode_maybe_binary(undefined) -> <<>>;
encode_maybe_binary(Bin) -> Bin.


q(Client, Command) -> ecredis:q(Client, Command).
qp(Client, Commands) -> ecredis:qp(Client, Commands).
qmn(Client, Commands) -> ecredis:qmn(Client, Commands).


encode_boolean(true) -> <<"1">>;
encode_boolean(false) -> <<"0">>.

decode_boolean(<<"1">>) -> true;
decode_boolean(<<"0">>) -> false.

decode_boolean(<<"1">>, _DefaultValue) -> true;
decode_boolean(<<"0">>, _DefaultValue) -> false;
decode_boolean(_, DefaultValue) -> DefaultValue.

encode_b64(undefined) -> undefined;
encode_b64(Value) -> base64url:encode(Value).

decode_b64(undefined) -> undefined;
decode_b64(Value) -> base64url:decode(Value).


-spec parse_zrange_with_scores(L :: []) -> [{term(), term()}].
parse_zrange_with_scores(L) ->
    parse_zrange_with_scores(L, []).

parse_zrange_with_scores([], Res) ->
    lists:reverse(Res);
parse_zrange_with_scores([El, Score | Rest], Res) ->
    parse_zrange_with_scores(Rest, [{El, Score} | Res]).


-spec run_qmn(Client :: atom(), Commands :: list()) -> list().
run_qmn(Client, Commands) ->
    Responses = qmn(Client, Commands),
    lists:foreach(fun(Response) -> {ok, _} = Response end, Responses),
    Responses.


-spec verify_ok(Result :: {error, any()} | term() | [{error, any()} | term()]) -> ok | {error, any()}.
verify_ok([]) -> ok;
verify_ok([{error, _Reason} = Err | _Rest]) -> Err;
verify_ok([_Okay | Rest]) -> verify_ok(Rest);
verify_ok({error, _Reason} = Err) -> Err;
verify_ok(_Success) -> ok.
