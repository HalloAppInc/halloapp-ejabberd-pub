%%%----------------------------------------------------------------------
%%% File    : mod_search.erl
%%%
%%% Copyright (C) 2022 HalloApp Inc.
%%%
%%% This file manages search for username prefix.
%%% TODO: support search for additional fields in future
%%%----------------------------------------------------------------------

-module(mod_search).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% hooks and api.
-export([
    process_local_iq/1,
    search_username_prefix/2
]).


%%====================================================================
%% gen_mod api
%%====================================================================

start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_search_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_halloapp_search_request, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_search_request),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_halloapp_search_request),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% iq handlers and api
%%====================================================================

process_local_iq(
    #pb_iq{from_uid = Uid, type = get, payload = #pb_search_request{
        username_string = Prefix}} = IQ) ->
    ?INFO("Uid: ~p, username prefix ~p", [Uid, Prefix]),
    stat:count("KA/search", "username_prefix"),
    SearchResult = search_username_prefix(Prefix, Uid),
    pb:make_iq_result(IQ, #pb_search_response{result = ok, search_result = SearchResult});

process_local_iq(
    #pb_iq{from_uid = Uid, type = get, payload = #pb_halloapp_search_request{
        username_string = Prefix}} = IQ) ->
    ?INFO("Uid: ~p, username prefix ~p", [Uid, Prefix]),
    stat:count("HA/search", "username_prefix"),
    SearchResult = search_username_prefix(Prefix, Uid),
    pb:make_iq_result(IQ, #pb_halloapp_search_response{result = ok, search_result = SearchResult}).

-spec search_username_prefix(Prefix :: binary(), Uid :: uid()) -> [pb_basic_user_profile()].
search_username_prefix(Prefix, Uid) ->
    AppType = util_uid:get_app_type(Uid),
    Ouids = model_accounts:search_index_results(Prefix, 20),
    case AppType of
        katchup ->
            %% Filter out uids based off app type.
            FilteredOuids = lists:filter(
                fun(Ouid) ->
                    not (Uid =:= Ouid orelse model_follow:is_blocked_any(Uid, Ouid) orelse util_uid:get_app_type(Ouid) =/= AppType)
                end, Ouids),
            BasicProfiles = model_accounts:get_basic_user_profiles(Uid, FilteredOuids),
            %% Filter out profiles that don't have name or username set
            lists:filter(
                fun
                    (#pb_basic_user_profile{name = undefined}) -> false;
                    (#pb_basic_user_profile{username = undefined}) -> false;
                    (_) -> true
                end,
                BasicProfiles);
        halloapp ->
            %% Filter out uids based off app type.
            FilteredOuids = lists:filter(
                fun(Ouid) ->
                    not (Uid =:= Ouid orelse model_halloapp_friends:is_blocked_any2(Uid, Ouid) orelse util_uid:get_app_type(Ouid) =/= AppType)
                end, Ouids),
            HalloappProfiles = model_accounts:get_halloapp_user_profiles(Uid, FilteredOuids),
            %% Filter out profiles that don't have name or username set
            lists:filter(
                fun
                    (#pb_halloapp_user_profile{name = undefined}) -> false;
                    (#pb_halloapp_user_profile{username = undefined}) -> false;
                    (_) -> true
                end,
                HalloappProfiles)
    end.

