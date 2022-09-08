%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% A purposefully bad process meant to test the functionality of ejabberd_monitor
%%% @end
%%% Created : 29. Jun 2021 3:23 PM
%%%-------------------------------------------------------------------
-module(ha_bad_process).
-author("josh").

-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").
-include("monitor.hrl").
-include("proc.hrl").

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).
%% API
-export([
    be_normal/0,
    be_slow/0,
    be_mostly_slow/0,
    kill/0,
    %% for tests
    get/1,
    put/1
]).

%%====================================================================
%% API
%%====================================================================

be_normal() ->
    ok = gen_server:call(?PROC(), {update_behavior, normal}).

be_slow() ->
    ok = gen_server:call(?PROC(), {update_behavior, slow}).

be_mostly_slow() ->
    ok = gen_server:call(?PROC(), {update_behavior, mostly_slow}).

kill() ->
    try gen_server:call(?PROC(), {update_behavior, kill}) of
        _ -> error(failed_to_kill)
    catch
        exit:{killed, _} -> ok
    end.

get(Key) ->
    gen_server:call(?PROC(), {get, Key}).

put(Key) ->
    gen_server:call(?PROC(), {put, Key}, 10 * ?SECONDS_MS).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, Opts) ->
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ok.

stop(_Host) ->
    gen_mod:stop_child(?PROC()),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_) ->
    ?INFO("Starting ~p", [?MODULE]),
    {ok, #{state => normal, msgs => #{}}}.


terminate(_Reason, _State) ->
    ok.


handle_call({update_behavior, Behavior}, _From, State) ->
    case Behavior of
        kill -> {stop, killed, State};
        _ -> {reply, ok, State#{state := Behavior}}
    end;
handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    case maps:get(state, State, undefined) of
        normal -> util_monitor:send_ack(self(), From, {ack, Id, Ts, self()});
        slow ->
            timer:sleep(?PING_TIMEOUT_MS + 1 * ?SECONDS_MS),
            util_monitor:send_ack(self(), From, {ack, Id, Ts, self()});
        mostly_slow ->
            %% Make sure we are slow 60% of the time to test process slow alert
            case rand:uniform() > 0.4 of
                true -> timer:sleep(?PING_TIMEOUT_MS + 1 * ?SECONDS_MS);
                false -> ok
            end,
            util_monitor:send_ack(self(), From, {ack, Id, Ts, self()});
        _ -> ?WARNING("Unexpected state: ~p", [maps:get(state, State)])
    end,
    {noreply, State};
handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

