%%%-------------------------------------------------------------------
%%% @author michelle
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 28. May 2020 11:14 AM
%%%-------------------------------------------------------------------
-module(test_users).
-author("michelle").

-include("ha_types.hrl").

%% API
-export([
    get_test_uids/0,
    is_test_uid/1
]).

%%====================================================================
%% API
%%====================================================================

-spec get_test_uids() -> [uid()].
get_test_uids()->
        [
            <<"1000000000412793778">>, %% beatriz-spanish translator
            <<"1000000000833818186">>  %% sandra - german translator
        ] ++
        dev_users:get_dev_uids()      
    .

-spec is_test_uid(Uid :: uid()) -> boolean().
is_test_uid(Uid) ->
    IsUIDDev = lists:member(Uid, get_test_uids()),
    case model_accounts:get_phone(Uid) of
        {error, missing} ->
            IsUIDDev;
        {ok, Phone} ->
            util:is_test_number(Phone) orelse IsUIDDev
    end.

