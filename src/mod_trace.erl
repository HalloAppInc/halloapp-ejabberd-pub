-module(mod_trace).
-author('nikola@halloapp.net').

-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("time.hrl").
-include("ha_types.hrl").
-include("proc.hrl").

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

% API
-export([
    add_uid/1,
    remove_uid/1,
    add_phone/1,
    remove_phone/1,
    start_trace/1,
    stop_trace/1,
    is_uid_traced/1,
    refresh_traced/0

]).

% hooks
-export([
    register_user/4,
    remove_user/2,
    c2s_handle_recv/3,
    c2s_handle_send/4,
    c2s_session_opened/1,
    c2s_session_closed/1
]).


start(Host, Opts) ->
    ?INFO("starting", []),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ejabberd_hooks:add(c2s_session_opened, halloapp, ?MODULE, c2s_session_opened, 0),
    ejabberd_hooks:add(c2s_session_closed, halloapp, ?MODULE, c2s_session_closed, 0),
    ejabberd_hooks:add(c2s_handle_recv, halloapp, ?MODULE, c2s_handle_recv, 0),
    ejabberd_hooks:add(c2s_handle_send, halloapp, ?MODULE, c2s_handle_send, 0),
    ejabberd_hooks:add(register_user, halloapp, ?MODULE, register_user, 10),
    ejabberd_hooks:add(remove_user, halloapp, ?MODULE, remove_user, 50),
    ok.


stop(_Host) ->
    ?INFO("stopping", []),
    gen_mod:stop_child(?PROC()),
    ejabberd_hooks:delete(remove_user, halloapp, ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(register_user, halloapp, ?MODULE, register_user, 10),
    ejabberd_hooks:delete(c2s_handle_send, halloapp, ?MODULE, c2s_handle_send, 0),
    ejabberd_hooks:delete(c2s_handle_recv, halloapp, ?MODULE, c2s_handle_recv, 0),
    ejabberd_hooks:delete(c2s_session_closed, halloapp, ?MODULE, c2s_session_closed, 0),
    ejabberd_hooks:delete(c2s_session_opened, halloapp, ?MODULE, c2s_session_opened, 0),
    ok.


reload(_Host, _NewOpts, _OldOpts) ->
    ok.


depends(_Host, _Opts) ->
    [].


mod_options(_Host) ->
    [].


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================


init([_Host, _Opts]) ->
    ?INFO("Start ~p", [?MODULE]),
    trace:info("Start"),
    ets:new(trace_uids, [set, named_table, protected]),
    ?INFO("creating trace_uids ets table", []),
    timer:apply_interval(10 * ?MINUTES_MS, ?MODULE, refresh_traced, []),
    init_ets(),
    {ok, #{}}.

code_change(_OldVsn, State, _Extra) ->
    ?INFO("code_change", []),
    {ok, State}.

terminate(Reason, State) ->
    ?INFO("Reason: ~p State: ~p", [Reason, State]),
    ok.

handle_call({add_uid, Uid}, _From, State) ->
    add_uid_internal(Uid),
    {reply, ok, State};

handle_call({remove_uid, Uid}, _From, State) ->
    remove_uid_internal(Uid),
    {reply, ok, State};

handle_call({add_phone, Phone}, _From, State) ->
    add_phone_internal(Phone, halloapp),
    add_phone_internal(Phone, katchup),
    {reply, ok, State};

handle_call({remove_phone, Phone}, _From, State) ->
    remove_phone_internal(Phone, halloapp),
    remove_phone_internal(Phone, katchup),
    {reply, ok, State};

handle_call({start_trace, Uid}, _From, State) ->
    start_trace_internal(Uid),
    {reply, ok, State};

handle_call({stop_trace, Uid}, _From, State) ->
    stop_trace_internal(Uid),
    {reply, ok, State};

handle_call(Request, _From, State) ->
    ?INFO("invalid request: ~p", [Request]),
    {reply, {error, bad_arg}, State}.

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast({add_uid, Uid}, State) ->
    add_uid_internal(Uid),
    {noreply, State};

handle_cast({remove_uid, Uid}, State) ->
    remove_uid_internal(Uid),
    {noreply, State};

handle_cast({start_trace, Uid}, State) ->
    start_trace_internal(Uid),
    {noreply, State};

handle_cast({stop_trace, Uid}, State) ->
    stop_trace_internal(Uid),
    {noreply, State};

handle_cast(Request, State) ->
    ?INFO("invalid request: ~p", [Request]),
    {noreply, State}.

handle_info(Request, State) ->
    ?INFO("invalid request: ~p", [Request]),
    {noreply, State}.


-spec add_uid(Uid :: uid()) -> ok.
add_uid(Uid) when is_binary(Uid) ->
    gen_server:call(?PROC(), {add_uid, Uid}).

add_uid_internal(Uid) ->
    ?INFO("add_uid Uid: ~s", [Uid]),
    model_accounts:add_uid_to_trace(Uid),
    % TODO: ideally we will do our start_trace_internal and then tell other nodes to do start_trace
    ejabberd_cluster:abcast(?PROC(), {start_trace, Uid}),
    ok.


-spec remove_uid(Uid :: binary()) -> ok.
remove_uid(Uid) when is_binary(Uid) ->
    gen_server:call(?PROC(), {remove_uid, Uid}).

remove_uid_internal(Uid) ->
    ?INFO("remove_uid Uid: ~s", [Uid]),
    model_accounts:remove_uid_from_trace(Uid),
    % TODO: ideally we will do our stop_trace_internal and then tell other nodes to do stop_trace
    ejabberd_cluster:abcast(?PROC(), {stop_trace, Uid}),
    ok.


-spec add_phone(Phone :: binary()) -> ok.
add_phone(Phone) ->
    gen_server:call(?PROC(), {add_phone, Phone}).

add_phone_internal(Phone, AppType) ->
    ?INFO("Phone: ~s", [Phone]),
    {ok, Uid} = model_phone:get_uid(Phone, AppType),
    ?INFO("currently we have Uid: ~s registered with Phone: ~s, AppType: ~s", [Uid, Phone, AppType]),
    model_accounts:add_phone_to_trace(Phone),
    case Uid of
        undefined ->
            ok;
        Uid ->
            add_uid_internal(Uid)
    end.

-spec remove_phone(Phone :: binary()) -> ok.
remove_phone(Phone) ->
    gen_server:call(?PROC(), {remove_phone, Phone}).

remove_phone_internal(Phone, AppType) ->
    ?INFO("Phone: ~s", [Phone]),
    {ok, Uid} = model_phone:get_uid(Phone, AppType),
    ?INFO("currently we have Uid: ~s registered with Phone: ~s, AppType: ~p", [Uid, Phone, AppType]),
    model_accounts:remove_phone_from_trace(Phone),
    case Uid of
        undefined ->
            ok;
        Uid ->
            remove_uid_internal(Uid)
    end.

-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
register_user(Uid, _Server, Phone, _CampaignId) ->
    % TODO: Build ets table for phones traced,
    % Otherwise every registration is being checked agains this key.
    case model_accounts:is_phone_traced(Phone) of
        false ->
            ok;
        true ->
            ?INFO("activiating trace for Uid: ~s because Phone: ~s is traced", [Uid, Phone]),
            % we use cast because we don't want to block the registration
            % while we wait for all nodes in the cluster to ack
            gen_server:cast(?PROC(), {add_uid, Uid}),
            ok
    end.


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    case is_uid_traced(Uid) of
        false -> ok;
        true ->
            ?INFO("traced Uid: ~s is being deleted", [Uid]),
            % cast because we don't want to block the remove_user hook
            % while we wait for all nodes in the cluster to ack
            gen_server:cast(?PROC(), {remove_uid, Uid}),
            ok
    end.

c2s_handle_recv(#{user := Uid} = State, Bin, Pkt) ->
    trace_pb_packet(Uid, recv, Pkt, Bin),
    State.

c2s_handle_send(#{user := Uid} = State, Bin, Pkt, _SendResult) ->
    % TODO: maybe we should only log packets we send successfully
    trace_pb_packet(Uid, send, Pkt, Bin),
    State.


c2s_session_opened(#{user := Uid} = State) ->
    trace_pb_packet(Uid, session_opened, <<>>, <<>>),
    State.


c2s_session_closed(#{user := Uid} = State) ->
    trace_pb_packet(Uid, session_closed, <<>>, <<>>),
    State.


start_trace(Uid) ->
    ?INFO("Uid ~p", [Uid]),
    gen_server:call(?PROC(), {start_trace, Uid}).


start_trace_internal(Uid) ->
    ?INFO("Uid ~p", [Uid]),
    ets:insert(trace_uids, {Uid}).


stop_trace(Uid) ->
    ?INFO("Uid ~p", [Uid]),
    gen_server:call(?PROC(), {stop_trace, Uid}).


stop_trace_internal(Uid) ->
    ?INFO("Uid ~p", [Uid]),
    ets:delete(trace_uids, Uid).


is_uid_traced(Uid) ->
    try
        case ets:lookup(trace_uids, Uid) of
            [{Uid}] -> true;
            _ ->
                dev_users:is_dev_uid(Uid)
        end
    catch
        % This could happen if the table does not exist.
        Class : Reason : Stacktrace ->
            ?ERROR("is_uid_traced failed: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            false
    end.


trace_pb_packet(Uid, Direction, Packet, BinPacket) ->
    try
        case is_uid_traced(Uid) of
            true ->
                trace:info("Uid:~s ~p ~s === ~p | ~s",
                    [Uid, self(), Direction, Packet, base64:encode(BinPacket)]);
            false -> ok
        end
    catch
        error : Reason ->
            ?WARNING("Error encoding packet: ~p, reason: ~p", [Packet, Reason])
    end.


init_ets() ->
    {ok, RedisUids} = model_accounts:get_traced_uids(),
    init_ets(RedisUids).


init_ets(Uids) ->
    ets:delete_all_objects(trace_uids),
    lists:foreach(fun start_trace_internal/1, Uids),
    ?INFO("tracing ~p Uids", [length(Uids)]).


refresh_traced() ->
    ?INFO("refreshing traced", []),
    CurrentUids = lists:map(fun ([Uid]) -> Uid end, ets:match(trace_uids, {'$1'})),
    CurrentSet = sets:from_list(CurrentUids),
    {ok, RedisUids} = model_accounts:get_traced_uids(),
    FutureSet = sets:from_list(RedisUids),
    RemoveList = sets:to_list(sets:subtract(CurrentSet, FutureSet)),
    AddList = sets:to_list(sets:subtract(FutureSet, CurrentSet)),
    case {RemoveList, AddList} of
        {[], []} ->
            ?INFO("all in sync", []);
        _ ->
            ?ERROR("uids removed ~p", [RemoveList]),
            ?ERROR("uids added ~p", [AddList]),
            % TODO: We should check if those accounts still exist
            init_ets(RedisUids)
    end,
    ok.
