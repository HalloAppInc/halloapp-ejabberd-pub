-module(mod_trace).
-author('nikola@halloapp.net').

-behaviour(gen_mod).

-include("logger.hrl").
-include("jid.hrl").
-include("time.hrl").

-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

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
    user_send_packet/1,
    user_receive_packet/1,
    register_user/3,
    remove_user/2
]).

% TODO: In the future this data can be loaded from redis on startup and synced
% every few minutes
% TODO: Allow tracing by phone
-define(UIDS, [
    <<"1000000000773653288">>,
    <<"1000000000349709227">>,
    <<"1000000000118189365">>,
    <<"1000000000386040322">>,
    <<"1000000000281775695">>,
    <<"1000000000779676419">>,
    <<"1000000000561642370">>,
    <<"1000000000751206203">>,
    <<"1000000000159020147">>,
    <<"1000000000210029968">>,
    <<"1000000000642342790">>,
    <<"1000000000510953137">>,
    <<"1000000000546150294">>,
    <<"1000000000354803885">>,
    <<"1000000000045484920">>,
    <<"1000000000257462423">>,
    <<"1000000000477041210">>,
    <<"1000000000223301226">>,
    <<"1000000000969121797">>,
    <<"1000000000749685963">>,
    <<"1000000000739856658">>,
    <<"1000000000332736727">>,
    <<"1000000000893731049">>,
    <<"1000000000648327036">>,
    <<"1000000000734016415">>,
    <<"1000000000408049639">>,
    <<"1000000000777479325">>,
    <<"1000000000379188160">>,
    <<"1000000000185937915">>,
    <<"1000000000519345762">>,
    <<"1000000000162508063">>,
    <<"1000000000235595959">>,
    <<"1000000000748413786">>,
    <<"1000000000029587793">>,
    <<"1000000000649620354">>,
    <<"1000000000894434112">>,
    <<"1000000000042689058">>,
    <<"1000000000110929523">>,
    <<"1000000000562160463">>,
    <<"1000000000354838820">>,
    <<"1000000000433118870">>,
    <<"1000000000936238928">>,
    <<"1000000000362410328">>,
    <<"1000000000155526656">>,
    <<"1000000000216663195">>,
    <<"1000000000841734036">>,
    <<"1000000000376503286">>
]).


start(Host, _Opts) ->
    init(),
    % TODO: register for the hook 'register_user' and check if the phone should be traced.
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 100),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 10),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ok.


stop(Host) ->
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 10),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 100),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ok.


reload(_Host, _NewOpts, _OldOpts) ->
    ok.


depends(_Host, _Opts) ->
    [{model_accounts, hard}].


mod_options(_Host) ->
    [].


init() ->
    xmpp_trace:notice("Start"),
    ets:new(trace_uids, [set, named_table, public]),
    %% TODO: delete this line after the runs once, and the data is in redis.
    lists:foreach(fun model_accounts:add_uid_to_trace/1, ?UIDS),
    timer:apply_interval(10 * ?MINUTES_MS, ?MODULE, refresh_traced, []),
    init_ets(),
    ok.


-spec add_uid(Uid :: binary()) -> ok.
add_uid(Uid) when is_binary(Uid) ->
    ?INFO_MSG("Uid: ~s", [Uid]),
    model_accounts:add_uid_to_trace(Uid),
    ejabberd_cluster:multicall(?MODULE, start_trace, [Uid]),
    ok.


-spec remove_uid(Uid :: binary()) -> ok.
remove_uid(Uid) when is_binary(Uid) ->
    ?INFO_MSG("Uid: ~s", [Uid]),
    model_accounts:remove_uid_to_trace(Uid),
    ejabberd_cluster:multicall(?MODULE, stop_trace, [Uid]),
    ok.


-spec add_phone(Phone :: binary()) -> ok.
add_phone(Phone) ->
    ?INFO_MSG("Phone: ~s", [Phone]),
    {ok, Uid} = model_phone:get_uid(Phone),
    ?INFO_MSG("currently we have Uid: ~s registered with Phone: ~s", [Uid, Phone]),
    model_accounts:add_phone_to_trace(Phone),
    case Uid of
        undefined -> ok;
        Uid ->
            model_accounts:add_uid_to_trace(Uid),
            ejabberd_cluster:multicall(?MODULE, start_trace, [Uid])
    end,
    ok.


-spec remove_phone(Phone :: binary()) -> ok.
remove_phone(Phone) ->
    ?INFO_MSG("Phone: ~s", [Phone]),
    {ok, Uid} = model_phone:get_uid(Phone),
    ?INFO_MSG("currently we have Uid: ~s registered with Phone: ~s", [Uid, Phone]),
    model_accounts:remove_phone_to_trace(Phone),
    case Uid of
        undefined -> ok;
        Uid ->
            model_accounts:remove_uid_from_trace(Uid),
            ejabberd_cluster:multicall(?MODULE, stop_trace, [Uid])
    end,
    ok.


-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
register_user(Uid, _Server, Phone) ->
    % TODO: Build ets table for phones traced,
    % Otherwise every registration is being checked agains this key.
    case model_accounts:is_phone_traced(Phone) of
        false -> ok;
        true ->
            ?INFO_MSG("activiating trace for Uid: ~s because Phone: ~s is traced", [Uid, Phone]),
            % spawn new process because we don't want to block the register_user hook
            % while we wait for all nodes in the cluster to ack
            spawn(fun () -> add_uid(Uid) end),
            ok
    end.


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    case is_uid_traced(Uid) of
        false -> ok;
        true ->
            ?INFO_MSG("traced Uid: ~s is being deleted", [Uid]),
            % spawn new process because we don't want to block the remove_user hook
            % while we wait for all nodes in the cluster to ack
            spawn(fun () -> remove_uid(Uid) end),
            ok
    end.

user_send_packet({Packet, #{jid := JID} = State}) ->
    #jid{luser = Uid} = JID,
    trace_packet(Uid, send, Packet),
    {Packet, State}.


user_receive_packet({Packet, #{jid := JID} = State}) ->
    #jid{luser = Uid} = JID,
    trace_packet(Uid, recv, Packet),
    {Packet, State}.


start_trace(Uid) ->
    ets:insert(trace_uids, {Uid}).


stop_trace(Uid) ->
    ets:delete(trace_uids, Uid).


is_uid_traced(Uid) ->
    case ets:lookup(trace_uids, Uid) of
        [{Uid}] -> true;
        _ -> false
    end.


trace_packet(Uid, Direction, Packet) ->
    case is_uid_traced(Uid) of
        true ->
            xmpp_trace:info("Uid:~s ~s === ~s",
                [Uid, Direction, fxml:element_to_binary(xmpp:encode(Packet))]);
        false -> ok
    end.


init_ets() ->
    {ok, RedisUids} = model_accounts:get_traced_uids(),
    init_ets(RedisUids).


init_ets(Uids) ->
    ets:delete_all_objects(trace_uids),
    lists:foreach(fun start_trace/1, Uids),
    ?INFO_MSG("tracing ~p Uids", [length(Uids)]).


refresh_traced() ->
    ?INFO_MSG("refreshing traced", []),
    CurrentUids = lists:map(fun ([Uid]) -> Uid end, ets:match(trace_uids, {'$1'})),
    CurrentSet = sets:from_list(CurrentUids),
    {ok, RedisUids} = model_accounts:get_traced_uids(),
    FutureSet = sets:from_list(RedisUids),
    RemoveList = sets:to_list(sets:subtract(CurrentSet, FutureSet)),
    AddList = sets:to_list(sets:subtract(FutureSet, CurrentSet)),
    case {RemoveList, AddList} of
        {[], []} ->
            ?INFO_MSG("all in sync", []);
        _ ->
            ?ERROR_MSG("uids removed ~p", [RemoveList]),
            ?ERROR_MSG("uids added ~p", [AddList]),
            % TODO: We should check if those accounts still exist
            init_ets(RedisUids)
    end,
    ok.
