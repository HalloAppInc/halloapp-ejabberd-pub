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
-include("packets.hrl").
-include("ha_types.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

%% API
-export([
    get_uid/0,
    do_noise_checks/0,
    do_noise_login/2,
    do_noise_register/2,
    reassign_jobs/0
]).

-define(OPTS, [
    {ping_interval_ms, ?NOISE_PING_INTERVAL_MS},
    {ping_timeout_ms, ?NOISE_PING_TIMEOUT_MS}
]).

%%====================================================================
%% API
%%====================================================================

do_noise_checks() ->
    gen_server:call(?PROC(), do_noise_checks).


do_noise_login({Name, Host}, Version) ->
    NoiseUid = get_uid(),
    %% Does XX noise login
    KeyPair = {kp, dh25519, get_secret_key(), get_public_key()},
    IpProtocol = case string:find(Name, "ipv6") of
        nomatch -> inet;
        _ -> inet6
    end,
    Options = #{host => Host, port => ?NOISE_LOGIN_PORT, version => Version,
        resource => <<"iphone">>, monitor => true, ip_protocol => IpProtocol},
    try ha_client:connect_and_login(NoiseUid, KeyPair, Options) of
        {ok, Pid} ->
            gen_server:stop(Pid),
            TimestampMs = util:now_ms(),
            model_accounts:set_last_activity(NoiseUid, TimestampMs, available),
            record_state(Host, login, ?ALIVE_STATE);
        {error, Err} ->
            ?WARNING("Noise login error on ~s (~s): ~p", [Name, Host, Err]),
            record_state(Host, login, ?FAIL_STATE)
    catch
        _:Reason ->
            ?ERROR("Noise login error on ~s (~s): ~p", [Name, Host, Reason]),
            record_state(Host, login, ?FAIL_STATE)
    end,
    ok.

do_noise_register({Name, Host}, Version) ->
    IpProtocol = case string:find(Name, "ipv6") of
        nomatch -> inet;
        _ -> inet6
    end,
    Options = #{host => Host, port => ?NOISE_REGISTER_PORT, user_agent => Version, ip_protocol => IpProtocol},
    MonitorPhone = util:get_monitor_phone(),
    try registration_client:hashcash_register(Name, MonitorPhone, Options) of
        ok -> record_state(Host, register, ?ALIVE_STATE);
        {error, Err} -> 
            ?WARNING("Noise register error on ~s (~s): ~p", [Name, Host, Err]),
            record_state(Host, register, ?FAIL_STATE)
    catch
        _:Reason:Stacktrace ->
            ?ERROR("Noise register error on ~s (~s): ~p ~p", [Name, Host, Reason, Stacktrace]),
            record_state(Host, register, ?FAIL_STATE)
    end,
    ok.


-spec get_state_history(Ip :: string(), CheckType :: atom()) -> list(proc_state()).
get_state_history(Ip, login) ->
    util_monitor:get_state_history(?NOISE_LOGIN_TABLE, Ip);
get_state_history(Ip, register) ->
    util_monitor:get_state_history(?NOISE_REGISTER_TABLE, Ip).


reassign_jobs() ->
    case util:is_main_stest() of
        true ->
            {Host, Opts} = persistent_term:get({?MODULE, gen_mod_start_args}),
            gen_mod:start_child(?MODULE, Host, Opts, ?PROC());
        false ->
            EjabberdProcs = lists:map(
                fun({ProcName, _Pid, _, _}) -> ProcName end,
                supervisor3:which_children(ejabberd_gen_mod_sup)
            ),
            case lists:member(?PROC(), EjabberdProcs) of
                true -> gen_mod:stop_child(?PROC());
                false -> ok
            end,
            ok
    end.

%%====================================================================
%% gen_mod API
%%====================================================================

start(Host, Opts) ->
    persistent_term:put({?MODULE, gen_mod_start_args}, {Host, Opts}),
    ejabberd_hooks:add(node_up, ?MODULE, reassign_jobs, 5),
    case util:is_main_stest() of
        true -> gen_mod:start_child(?MODULE, Host, Opts, ?PROC());
        false -> ok
    end.

stop(_Host) ->
    ejabberd_hooks:delete(node_up, ?MODULE, reassign_jobs, 5),
    case util:is_main_stest() of
        true -> gen_mod:stop_child(?PROC());
        false -> ok
    end.

depends(_Host, _Opts) -> [].

reload(_Host, _NewOpts, _OldOpts) -> ok.

mod_options(_Host) -> [].

%%====================================================================
%% gen_server API
%%====================================================================

init(_) ->
    ets:new(?NOISE_LOGIN_TABLE, [named_table, public]),
    ets:new(?NOISE_REGISTER_TABLE, [named_table, public]),
    {ok, TRef} = timer:apply_interval(?NOISE_PING_INTERVAL_MS, ?MODULE, do_noise_checks, []),
    {ok, #{client_version => undefined, tref => TRef, mrefs => #{}}}.


terminate(_Reason, #{tref := TRef}) ->
    timer:cancel(TRef),
    ok.


handle_call(do_noise_checks, _From, State) ->
    check_states(),
    State2 = get_client_version(State),
    State3 = do_noise_logins(State2),
    State4 = do_noise_registers(State3),
    {reply, ok, State4};

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
        {_Host, _CheckType} ->
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
        {Host, CheckType} ->
            ?WARNING("Noise ~p failed for ~p: ~p", [CheckType, Host, Reason]),
            record_state(Host, CheckType, ?FAIL_STATE),
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
        fun({_Name, Host} = Args, AccMap) ->
            {_Pid, Monitor} = spawn_monitor(?MODULE, do_noise_login, [Args, Version]),
            maps:put(Monitor, {Host, login}, AccMap)
        end,
        MRefs,
        get_all_hosts()),
    maps:put(mrefs, NewMRefs, State).

do_noise_registers(#{mrefs := MRefs} = State) ->
    {Version, _Ts} = maps:get(client_version, State),
    NewMRefs = lists:foldl(
        fun({_Name, Host} = Args, AccMap) ->
            {_Pid, Monitor} = spawn_monitor(?MODULE, do_noise_register, [Args, Version]),
            maps:put(Monitor, {Host, register}, AccMap)
        end,
        MRefs,
        get_all_hosts()),
    maps:put(mrefs, NewMRefs, State).

-spec record_state(Ip :: string(), CheckType :: atom(), State :: proc_state()) -> ok.
record_state(Ip, login, State) ->
    util_monitor:record_state(?NOISE_LOGIN_TABLE, Ip, State, ?OPTS);
record_state(Ip, register, State) ->
    util_monitor:record_state(?NOISE_REGISTER_TABLE, Ip, State, ?OPTS).

send_stats(Name, StateHistory, login) ->
    Window = ?MINUTES_MS div ?NOISE_PING_INTERVAL_MS,
    SuccessRate = 1 - (util_monitor:get_num_fails(lists:sublist(StateHistory, Window)) / Window),
    stat:gauge(?NS, "noise_login_uptime", round(SuccessRate * 100), [{host, Name}]),
    ok;
send_stats(Name, StateHistory, register) ->
    Window = ?MINUTES_MS div ?NOISE_PING_INTERVAL_MS,
    SuccessRate = 1 - (util_monitor:get_num_fails(lists:sublist(StateHistory, Window)) / Window),
    stat:gauge(?NS, "noise_register_uptime", round(SuccessRate * 100), [{host, Name}]),
    ok.

%%====================================================================
%% Checker functions
%%====================================================================

-spec check_consecutive_fails({Name :: string(), Ip :: string()}, StateHistory :: [proc_state()], CheckType :: atom()) -> boolean().
check_consecutive_fails({Name, Ip}, StateHistory, CheckType) ->
    case util_monitor:check_consecutive_fails(StateHistory) of
        false -> false;
        true ->
            ?ERROR("Sending noise ~p unreachable alert for ~p (~p)", [CheckType, Name, Ip]),
            BinName = util:to_binary(Name),
            BinNumConsecFails = util:to_binary(?CONSECUTIVE_FAILURE_THRESHOLD),
            BinCheckType = util:to_binary(CheckType),
            Msg = <<BinName/binary, " has failed last ", BinNumConsecFails/binary, " noise ", BinCheckType/binary, " attempts">>,
            alerts:send_noise_unreachable_alert(BinName, BinCheckType, Msg),
            true
    end.


-spec check_slow({Name :: string(), Ip :: string()}, StateHistory :: [proc_state()], CheckType :: atom()) -> boolean().
check_slow({Name, Ip}, StateHistory, CheckType) ->
    case util_monitor:check_slow(StateHistory, ?OPTS) of
        {false, _} -> false;
        {true, PercentFails} ->
            ?ERROR("Sending noise ~p slow alert for ip: ~p", [CheckType, Ip]),
            BinName = util:to_binary(Name),
            BinCheckType = util:to_binary(CheckType),
            Msg = <<BinName/binary, " failing ", (util:to_binary(PercentFails))/binary ,"% of noise ", BinCheckType/binary ," pings">>,
            alerts:send_noise_slow_alert(BinName, BinCheckType, Msg),
            true
    end.


check_states() ->
    %% Check state histories and maybe trigger an alert
    check_states(login),
    check_states(register).
check_states(CheckType) ->
    lists:foreach(
        fun({Name, Ip}) ->
            CheckHistory = get_state_history(Ip, CheckType),
            %% do checks until one returns true (meaning an alert has been sent)
            check_consecutive_fails({Name, Ip}, CheckHistory, CheckType) orelse check_slow({Name, Ip}, CheckHistory, CheckType),
            send_stats(Name, CheckHistory, CheckType)
        end,
        get_all_hosts()),
    ok.


%%====================================================================
%% Getter functions
%%====================================================================

get_load_balancer_hosts() -> [
    {"load_balancer_ipv4", "s.halloapp.net"},
    {"load_balancer_ipv6", "s.halloapp.net"},
    {"stest_load_balancer_ipv4", "s-test.halloapp.net"},
    {"stest_load_balancer_ipv6", "s-test.halloapp.net"}
].


get_all_hosts() ->
    IpsAndPorts = mod_aws:get_ejabberd_machines(),
    IpsAndPorts ++ get_load_balancer_hosts().


get_uid() ->
    util:to_binary(mod_aws:get_secret_value(<<"mod_noise_checker">>, <<"uid">>)).


get_public_key() ->
    RawKey = mod_aws:get_secret_value(<<"mod_noise_checker">>, <<"public_ec_key_base64">>),
    base64:decode(RawKey).


get_secret_key() ->
    RawKey = mod_aws:get_secret_value(<<"mod_noise_checker">>, <<"secret_ec_key_base64">>),
    base64:decode(RawKey).

