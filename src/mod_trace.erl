-module(mod_trace).
-author('nikola@halloapp.net').

-behaviour(gen_mod).

-include("logger.hrl").
-include("jid.hrl").

-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

-export([
    user_send_packet/1,
    user_receive_packet/1,
    start_trace/1,
    stop_trace/1,
    is_uid_traced/1
]).

% TODO: In the future this data can be loaded from redis on startup and synced
% every few minutes
% TODO: Allow tracing by phone
-define(UIDS, [
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
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 100),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ok.


stop(Host) ->
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
    {ok, Uids} = model_accounts:get_traced_uids(),
    lists:foreach(fun start_trace/1, Uids),
    ?INFO_MSG("tracing ~p uids", [length(Uids)]),
    ok.


user_send_packet({Packet, #{lserver := ServerHost, jid := JID} = State}) ->
    #jid{luser = Uid} = JID,
    trace_packet(Uid, send, Packet),
    {Packet, State}.


user_receive_packet({Packet, #{lserver := ServerHost, jid := JID} = State}) ->
    #jid{luser = Uid} = JID,
    trace_packet(Uid, recv, Packet),
    {Packet, State}.


start_trace(Uid) ->
    ?DEBUG("start tracing Uid:~s", [Uid]),
    ets:insert(trace_uids, {Uid}).


stop_trace(Uid) ->
    ?DEBUG("stop tracing Uid:~s", [Uid]),
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

