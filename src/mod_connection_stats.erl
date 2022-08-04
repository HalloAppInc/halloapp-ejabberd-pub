%%%-------------------------------------------------------------------
%%% File: mod_connection_stats
%%%
%%% copyright (C) 2020, HalloApp, Inc.
%%%
%%% Computes stats about users connected to the server.
%%%-------------------------------------------------------------------
-module(mod_connection_stats).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("time.hrl").
-include("jid.hrl").
-include("proc.hrl").
-include("ha_types.hrl").


%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

-export([
    sm_register_connection_hook/4,
    sm_remove_connection_hook/4
]).

%% API
-export([
    compute_counts/0
]).


start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?PROC()),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


%%====================================================================
%% gen server API
%%====================================================================

%% TODO(murali@): If keeping a list of uids in a process memory becomes expensive.
%% Then we need to get rid of connected_users key.
init([Host|_]) ->
    ejabberd_hooks:add(sm_register_connection_hook, Host, ?MODULE, sm_register_connection_hook, 50),
    ejabberd_hooks:add(sm_remove_connection_hook, Host, ?MODULE, sm_remove_connection_hook, 50),
    State = #{
        host => Host,
        count => 0,    %% tracks connected users count.
        connected_users => sets:new(),    %% uids that are connected.
        version_counts => #{}   %% tracks connected_users by version.
    },
    trigger_counts_timer(),
    {ok, State}.


terminate(_Reason, #{host := Host} = _State) ->
    ejabberd_hooks:delete(sm_register_connection_hook, Host, ?MODULE, sm_register_connection_hook, 50),
    ejabberd_hooks:delete(sm_remove_connection_hook, Host, ?MODULE, sm_remove_connection_hook, 50),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call(_Request, _From, State) ->
    ?ERROR("Unknown request: ~p, ~p, ~p", [_Request, _From, State]),
    {reply, {error, invalid_request}, State}.


handle_info(compute_counts, State) ->
    ?INFO("compute_counts"),
    ok = compute_counts(State),
    trigger_counts_timer(),
    {noreply, State};

handle_info(_Request, State) ->
    ?ERROR("Unknown request: ~p, ~p", [_Request, State]),
    {noreply, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast({add_connection, Uid, ClientVersion},
        #{count := Count, connected_users := ConnectedUsers, version_counts := VersionCounts} = State) ->
    ?INFO("add_connection, uid: ~p, version: ~p", [Uid, ClientVersion]),
    NewCount = Count + 1,
    NewConnectedUsers = sets:add_element(Uid, ConnectedUsers),
    ClientVersionCount = maps:get(ClientVersion, VersionCounts, 0),
    NewVersionCounts = VersionCounts#{ClientVersion => ClientVersionCount + 1},
    NewState = State#{
        count => NewCount,
        connected_users => NewConnectedUsers,
        version_counts => NewVersionCounts
    },
    {noreply, NewState};

handle_cast({remove_connection, Uid, ClientVersion},
        #{count := Count, connected_users := ConnectedUsers, version_counts := VersionCounts} = State) ->
    ?INFO("remove_connection, uid: ~p, version: ~p", [Uid, ClientVersion]),
    NewCount = Count - 1,
    NewConnectedUsers = sets:del_element(Uid, ConnectedUsers),
    ClientVersionCount = maps:get(ClientVersion, VersionCounts),
    NewVersionCounts = VersionCounts#{ClientVersion => ClientVersionCount - 1},
    NewState = State#{
        count => NewCount,
        connected_users => NewConnectedUsers,
        version_counts => NewVersionCounts
    },
    {noreply, NewState};

handle_cast(Request, State) ->
    ?ERROR("Unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.


%%====================================================================
%% hooks.
%%====================================================================


-spec sm_register_connection_hook(SID :: ejabberd_sm:sid(),
        JID :: jid(), Mode :: mode(), Info :: ejabberd_sm:info()) -> ok.
sm_register_connection_hook(_SID, #jid{luser = Uid} = _JID, _Mode, Info) ->
    ClientVersion = proplists:get_value(client_version, Info),
    gen_server:cast(?PROC(), {add_connection, Uid, ClientVersion}),
    ok.


-spec sm_remove_connection_hook(SID :: ejabberd_sm:sid(),
        JID :: jid(), Mode :: mode(), Info :: ejabberd_sm:info()) -> ok.
sm_remove_connection_hook(_SID, #jid{luser = Uid} = _JID, _Mode, Info) ->
    ClientVersion = proplists:get_value(client_version, Info),
    gen_server:cast(?PROC(), {remove_connection, Uid, ClientVersion}),
    ok.


%%====================================================================
%% API
%%====================================================================


-spec compute_counts() -> ok.
compute_counts() ->
    gen_server:cast(?PROC(), compute_counts),
    ok.


-spec compute_counts(State :: map()) -> ok.
compute_counts(#{version_counts := VersionCounts} = State) ->
    stat:gauge("HA/connections", "connections", maps:get(count, State)),
    VersionCountsList = maps:to_list(VersionCounts),
    lists:foreach(
        fun({Version, Count}) ->
            stat:gauge("HA/connections", "connections_by_version", Count,
                [{version, Version}, {platform, util_ua:get_client_type(Version)}])
        end, VersionCountsList),
    ok.


-spec trigger_counts_timer() -> ok.
trigger_counts_timer() ->
    erlang:send_after(?MINUTES_MS, self(), compute_counts, []),
    ok.


