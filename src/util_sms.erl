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
    get_mbird_response_code/1,
    get_response_code/1,
    get_sms_message/3,
    is_google_request/3,
    is_hashcash_enabled/2
]).

-spec init_helper(GWOptions :: atom(), FromPhoneList :: [string() | binary()]) -> ok.
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


-spec lookup_from_phone(GWOptions :: atom()) -> string() | binary().
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


-spec get_mbird_response_code(ResBody :: iolist()) -> integer() | undefined.
get_mbird_response_code(ResBody) ->
    try
        Json = jiffy:decode(ResBody, [return_maps]),
        Errors = maps:get(<<"errors">>, Json, undefined),
        case Errors of
            undefined -> undefined;
            _ ->
                [ErrMp] = Errors,
                maps:get(<<"code">>, ErrMp, undefined)
        end
    catch Class : Reason : St ->
        ?ERROR("failed to parse response : ~s, exception: ~s",
            [ResBody, lager:pr_stacktrace(St, {Class, Reason})]),
        undefined
    end.


-spec get_response_code(ResBody :: iolist()) -> integer() | undefined.
get_response_code(ResBody) ->
    try
        Json = jiffy:decode(ResBody, [return_maps]),
        maps:get(<<"code">>, Json, undefined)
    catch Class : Reason : St ->
        ?ERROR("failed to parse response : ~s, exception: ~s",
            [ResBody, lager:pr_stacktrace(St, {Class, Reason})]),
        undefined
    end.


-spec get_sms_message(UserAgent :: binary(), Code :: binary(), LangId :: binary()) 
        -> {Msg :: io_lib:chars(), TranslatedLangId :: binary()}.
get_sms_message(UserAgent, Code, LangId) ->
    {SmsMsgBin, TranslatedLangId} = mod_translate:translate(<<"server.sms.verification">>, LangId),
    AppHash = util_ua:get_app_hash(UserAgent),
    Msg = io_lib:format("~ts: ~s~n~n~n~s", [SmsMsgBin, Code, AppHash]),
    {Msg, TranslatedLangId}.

-spec is_google_request(Phone :: binary(), IP :: binary(), Protocol :: atom()) -> boolean().
is_google_request(Phone, IP, Protocol) ->
    Result1 = util:is_google_number(Phone),
    Result2 = case inet:parse_address(util:to_list(IP)) of
        {ok, {108,177,6,_}} -> true;
        {ok, {108,177,7,_}} -> true;
        {ok, {70,32,147,_}} -> true;
        _ -> true
    end,
    case {Result1, Result2, Protocol} of
        {true, true, noise} -> true;
        _ -> false
    end.


is_hashcash_enabled(UserAgent, _Solution) ->
    ClientType = util_ua:get_client_type(UserAgent),
    case ClientType of
        android -> util_ua:is_version_greater_than(UserAgent, <<"HalloApp/Android1.42">>);
        ios -> util_ua:is_version_greater_than(UserAgent, <<"HalloApp/iOS1.20.261">>);
        undefined -> false
    end.
 
