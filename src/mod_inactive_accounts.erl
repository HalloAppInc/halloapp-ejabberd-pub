%%%-------------------------------------------------------------------
%%% File: mod_inactive_accounts.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module to manage inactive accounts.
%%%
%%%-------------------------------------------------------------------
-module(mod_inactive_accounts).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1, depends/2]).

-export([
    manage/0
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% api
%%====================================================================

-spec manage() -> ok.
manage() ->
    {Date, _Time} = calendar:local_time(),
    case calendar:day_of_the_week(Date) of
        1 ->
            %% Find accounts to delete on Monday.
            ?INFO("On Monday, create list of inactive Uids", []),
            model_accounts:cleanup_to_delete_uids_keys(),
            redis_migrate:start_migration("Find Inactive Accounts", redis_accounts,
                find_inactive_accounts, [{dry_run, false}, {execute, sequential}]);
        3 ->
            ?INFO("On Wednesday, Start deletion of inactive Uids using above list", []),
            %% TODO(vipin): Start deletion of accouts on Wednesday.
            ok;
        _ ->
            ok
    end,
    ok.


