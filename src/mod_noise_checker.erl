%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 30. Jul 2021 11:19 AM
%%%-------------------------------------------------------------------
-module(mod_noise_checker).
-author("josh").

-include("logger.hrl").
-include("monitor.hrl").
-include("proc.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

%% API
-export([
    get_uid/0,
    do_noise_logins/0,
    do_noise_login/2,
    get_state_history/1
]).

-define(OPTS, [
    {ping_interval_ms, ?NOISE_PING_INTERVAL_MS},
    {ping_timeout_ms, ?NOISE_PING_TIMEOUT_MS}
]).

%%====================================================================
%% API
%%====================================================================

do_noise_logins() ->
    gen_server:call(?PROC(), do_noise_logins).


do_noise_login({Name, Host, Port}, Version) ->
    NoiseUid = get_uid(),
    %% Does XX noise login
    KeyPair = {kp, dh25519, get_secret_key(), get_public_key()},
    Options = #{host => Host, port => Port, version => Version, resource => <<"iphone">>, monitor => true},
    try ha_client:connect_and_login(NoiseUid, KeyPair, Options) of
        {ok, Pid} ->
            gen_server:stop(Pid),
            TimestampMs = util:now_ms(),
            model_accounts:set_last_activity(NoiseUid, TimestampMs, available),
            record_state(Host, ?ALIVE_STATE);
        {error, Err} ->
            ?WARNING("Noise login error on ~s (~s): ~p", [Name, Host, Err]),
            record_state(Host, ?FAIL_STATE)
    catch
        _:Rea ->
            ?ERROR("Noise login error on ~s (~s): ~p", [Name, Host, Rea]),
            record_state(Host, ?FAIL_STATE)
    end,
    ok.


-spec get_state_history(Ip :: string()) -> list(proc_state()).
get_state_history(Ip) ->
    util_monitor:get_state_history(?NOISE_TABLE, Ip).

%%====================================================================
%% gen_mod API
%%====================================================================

start(Host, Opts) ->
    case util:get_machine_name() of
        <<"s-test">> -> gen_mod:start_child(?MODULE, Host, Opts, ?PROC());
        _ -> ok
    end.

stop(_Host) ->
    case util:get_machine_name() of
        <<"s-test">> -> gen_mod:stop_child(?PROC());
        _ -> ok
    end.

depends(_Host, _Opts) -> [].

reload(_Host, _NewOpts, _OldOpts) -> ok.

mod_options(_Host) -> [].

%%====================================================================
%% gen_server API
%%====================================================================

init(_) ->
    ets:new(?NOISE_TABLE, [named_table, public]),
    {ok, TRef} = timer:apply_interval(?NOISE_PING_INTERVAL_MS, ?MODULE, do_noise_logins, []),
    {ok, #{client_version => undefined, tref => TRef, mrefs => #{}}}.


terminate(_Reason, #{tref := TRef}) ->
    timer:cancel(TRef),
    ok.


handle_call(do_noise_logins, _From, State) ->
    check_states(),
    State2 = get_client_version(State),
    State3 = do_noise_logins(State2),
    {reply, ok, State3};

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info({'DOWN', Ref , process, _Pid, normal}, #{mrefs := MRefs} = State) ->
    NewMRefs = case maps:get(Ref, MRefs, undefined) of
        undefined ->
            %% since reason is normal, it is okay to ignore this case
            %% it's probably an ha_client process closing
            MRefs;
        _Host ->
            %% this case means a spawned do_noise_login process
            %% closed, in which case record_state has already been called
            maps:remove(Ref, MRefs)
    end,
    {noreply, maps:put(mrefs, NewMRefs, State)};

handle_info({'DOWN', Ref , process, Pid, Reason}, #{mrefs := MRefs} = State) ->
    NewMRefs = case maps:get(Ref, MRefs, undefined) of
        undefined ->
            ?ERROR("Monitored proc ~p is down: ~p", [Pid, Reason]),
            MRefs;
        Host ->
            ?WARNING("Noise login failed for ~p: ~p", [Host, Reason]),
            record_state(Host, ?FAIL_STATE),
            maps:remove(Ref, MRefs)
    end,
    {noreply, maps:put(mrefs, NewMRefs, State)};

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

get_client_version(#{client_version := CV} = State) ->
    case CV of
        undefined ->
            {ok, Versions} = model_client_version:get_versions(30 * ?DAYS, util:now()),
            State#{client_version => {lists:last(Versions), util:now()}};
        {_Version, Ts} ->
            %% update version if it is more than 7 days old
            case (util:now() - Ts) > (7 * ?DAYS) of
                true ->
                    {ok, Versions} = model_client_version:get_versions(30 * ?DAYS, util:now()),
                    maps:put(client_version, {lists:last(Versions), util:now()}, State);
                false -> State
            end
    end.


do_noise_logins(#{mrefs := MRefs} = State) ->
    {Version, _Ts} = maps:get(client_version, State),
    NewMRefs = lists:foldl(
        fun({_Name, Host, _Port} = Args, AccMap) ->
            {_Pid, Monitor} = spawn_monitor(?MODULE, do_noise_login, [Args, Version]),
            maps:put(Monitor, Host, AccMap)
        end,
        MRefs,
        get_all_hosts()),
    maps:put(mrefs, NewMRefs, State).


-spec record_state(Ip :: string(), State :: proc_state()) -> ok.
record_state(Ip, State) ->
    util_monitor:record_state(?NOISE_TABLE, Ip, State, ?OPTS).


send_stats(Name, StateHistory) ->
    Window = ?MINUTES_MS div ?NOISE_PING_INTERVAL_MS,
    SuccessRate = 1 - (util_monitor:get_num_fails(lists:sublist(StateHistory, Window)) / Window),
    stat:gauge(?NS, "noise_uptime", round(SuccessRate * 100), [{host, Name}]),
    ok.

%%====================================================================
%% Checker functions
%%====================================================================

-spec check_consecutive_fails({Name :: string(), Ip :: string()}, StateHistory :: [proc_state()]) -> boolean().
check_consecutive_fails({Name, Ip}, StateHistory) ->
    case util_monitor:check_consecutive_fails(StateHistory) of
        false -> false;
        true ->
            ?ERROR("Sending noise unreachable alert for ~p (~p)", [Name, Ip]),
            BinName = util:to_binary(Name),
            BinNumConsecFails = util:to_binary(?CONSECUTIVE_FAILURE_THRESHOLD),
            Msg = <<BinName/binary, " has failed last ", BinNumConsecFails/binary, " noise login attempts">>,
            alerts:send_noise_unreachable_alert(BinName, Msg),
            true
    end.


-spec check_slow({Name :: string(), Ip :: string()}, StateHistory :: [proc_state()]) -> boolean().
check_slow({Name, Ip}, StateHistory) ->
    case util_monitor:check_slow(StateHistory, ?OPTS) of
        {false, _} -> false;
        {true, PercentFails} ->
            ?ERROR("Sending noise slow alert for ip: ~p", [Ip]),
            BinName = util:to_binary(Name),
            Msg = <<BinName/binary, " failing ", (util:to_binary(PercentFails))/binary ,"% of pings">>,
            alerts:send_noise_slow_alert(BinName, Msg),
            true
    end.


check_states() ->
    %% Check state histories and maybe trigger an alert
    lists:foreach(
        fun({Name, Ip, _Port}) ->
            StateHistory = get_state_history(Ip),
            %% do checks until one returns true (meaning an alert has been sent)
            check_consecutive_fails({Name, Ip}, StateHistory) orelse check_slow({Name, Ip}, StateHistory),
            send_stats(Name, StateHistory)
        end,
        get_all_hosts()),
    ok.

%%====================================================================
%% Getter functions
%%====================================================================

get_load_balancer_hosts() -> [
    {"load_balancer", "s.halloapp.net", 5222}
].


get_all_hosts() ->
    IpsAndPorts = lists:map(fun({Name, Ip}) -> {Name, Ip, 5222} end, mod_aws:get_ejabberd_machines()),
    lists:concat([IpsAndPorts, get_load_balancer_hosts()]).


get_uid() ->
    util:to_binary(mod_aws:get_secret_value(<<"mod_noise_checker">>, <<"uid">>)).


get_public_key() ->
    RawKey = mod_aws:get_secret_value(<<"mod_noise_checker">>, <<"public_ec_key_base64">>),
    base64:decode(RawKey).


get_secret_key() ->
    RawKey = mod_aws:get_secret_value(<<"mod_noise_checker">>, <<"secret_ec_key_base64">>),
    base64:decode(RawKey).

