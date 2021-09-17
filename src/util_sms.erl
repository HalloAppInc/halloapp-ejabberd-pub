%%%----------------------------------------------------------------------
%%% File    : util_sms.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% Implements util functions for SMS gateways.
%%%----------------------------------------------------------------------

-module(util_sms).
-author('vipin').

-include_lib("stdlib/include/assert.hrl").
-include("logger.hrl").
-include("time.hrl").

-export([
    init_helper/2,
    lookup_from_phone/1,
    good_next_ts_diff/1,
    get_response_code/1,
    get_sms_message/3
]).

-spec init_helper(GWOptions :: atom(), FromPhoneList :: [list()]) -> ok.
init_helper(GWOptions, FromPhoneList) ->
    ets:new(GWOptions,
        [named_table, set, public, {write_concurrency, true}, {read_concurrency, true}]),
    ListWithIndex = lists:zip(lists:seq(1, length(FromPhoneList)), FromPhoneList),
    [ets:insert(GWOptions, {"from_phone_" ++ integer_to_list(Index), PhoneNo})
        || {Index, PhoneNo} <- ListWithIndex],
    ets:insert(GWOptions, {from_phone_list_length, length(FromPhoneList)}),
    StartingIndex = rand:uniform(length(FromPhoneList)),
    ets:insert(GWOptions, {from_phone_index, StartingIndex}),
    ?INFO("~p, starting index: ~p", [GWOptions, StartingIndex]),
    ok.


-spec lookup_from_phone(GWOptions :: atom()) -> list().
lookup_from_phone(GWOptions) ->
    [{_, ListLength}] = ets:lookup(GWOptions, from_phone_list_length),
    PhoneIndex = ets:update_counter(GWOptions, from_phone_index, 1) rem ListLength,
    [{_, FromPhone}] = ets:lookup(GWOptions, "from_phone_" ++ integer_to_list(PhoneIndex + 1)),
    FromPhone.


%% 0 -> 30 seconds -> 60 seconds -> 120 seconds -> 240 seconds ... capped at 24H
-spec good_next_ts_diff(NumFailedAttempts :: integer()) -> integer().
good_next_ts_diff(NumFailedAttempts) ->
    ?assert(NumFailedAttempts > 0),
    CappedFailedAttempts = min(NumFailedAttempts - 1, 13),
    Diff = 30 * ?SECONDS * trunc(math:pow(2, CappedFailedAttempts)),
    min(Diff, 24 * ?HOURS).


-spec get_response_code(ResBody :: iolist()) -> integer().
get_response_code(ResBody) ->
    Json = jiffy:decode(ResBody, [return_maps]),
    ErrCode = maps:get(<<"code">>, Json, undefined),
    ErrCode.


-spec get_sms_message(UserAgent :: binary(), Code :: binary(), LangId :: binary()) 
        -> {Msg :: binary(), TranslatedLangId :: binary()}.
get_sms_message(UserAgent, Code, LangId) ->
    {SmsMsgBin, TranslatedLangId} = mod_translate:translate(<<"server.sms.verification">>, LangId),
    AppHash = util_ua:get_app_hash(UserAgent),
    Msg = io_lib:format("~s: ~s~n~n~n~s", [SmsMsgBin, Code, AppHash]),
    {Msg, TranslatedLangId}.

