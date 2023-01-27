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
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_search_request),
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
    pb:make_iq_result(IQ, #pb_search_response{result = ok, search_result = SearchResult}).

-spec search_username_prefix(Prefix :: binary(), Uid :: uid()) -> [pb_basic_user_profile()].
search_username_prefix(Prefix, Uid) ->
    {ok, Usernames} = model_accounts:search_username_prefix(Prefix, 20),
    Ouids = maps:values(model_accounts:get_username_uids(Usernames)),
    FilteredOuids = lists:filter(fun(Ouid) -> not (Uid =:= Ouid orelse model_follow:is_blocked_any(Uid, Ouid)) end, Ouids),
    model_accounts:get_basic_user_profiles(Uid, FilteredOuids).

