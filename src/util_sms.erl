%%%----------------------------------------------------------------------
%%% File    : util_sms.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% Implements util functions for SMS gateways.
%%%----------------------------------------------------------------------

-module(util_sms).
-author('vipin').

-include("logger.hrl").

-export([
    init_helper/2,
    lookup_from_phone/1
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

