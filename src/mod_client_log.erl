%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%% Module to handle client request to log events and counts.
%%% Spec: https://github.com/HalloAppInc/server/blob/master/doc/client_event_logger.md
%%% @end
%%% Created : 12. Aug 2020 10:00 AM
%%%-------------------------------------------------------------------
-module(mod_client_log).

-author('nikola').

-behaviour(gen_mod).

-export([start/2, stop/1, mod_options/1, depends/2]).

-export([
    process_local_iq/1
]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ha_types.hrl").

-define(NS_CLIENT_LOG, <<"halloapp:client_log">>).
-define(CLIENT_NS, <<"client.">>).

-define(VALID_NAMESPACE_RE, "^[a-zA-Z][a-zA-Z0-9.\-/_]*$").

-type result() :: ok | {error, any()}.


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_CLIENT_LOG, ?MODULE, process_local_iq).

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_CLIENT_LOG).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


% client_log
-spec process_local_iq(iq()) -> iq().
process_local_iq(#iq{type = set, from = #jid{luser = Uid},
        sub_els = [#client_log_st{} = ClientLogsSt]} = IQ) ->
    try
        Counts = ClientLogsSt#client_log_st.counts,
        Events = ClientLogsSt#client_log_st.events,
        ?INFO_MSG("Uid: ~s counts: ~p, events: ~p", [Uid, length(Counts), length(Events)]),
        CountResults = process_counts(Counts),
        EventResults = process_events(Uid, Events),
        CountError = lists:any(fun has_error/1, CountResults),
        EventError = lists:any(fun has_error/1, EventResults),
        case CountError or EventError of
            true ->
                xmpp:make_error(IQ, util:err(bad_request));
            false ->
                xmpp:make_iq_result(IQ)
        end
    catch
        Class : Reason : Stacktrace ->
            ?ERROR_MSG("client log error: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            xmpp:make_error(IQ, util:err(server_error))
    end;

process_local_iq(#iq{} = IQ) ->
    xmpp:make_error(IQ, util:err(bad_request)).


-spec process_counts(Counts :: [count_st()]) -> [result()].
process_counts(Counts) ->
    lists:map(fun process_count/1, Counts).


% TODO: validate the number of dims is < 6
% TODO: validate the name and value of each dimension
-spec process_count(Counts :: count_st()) -> result() .
process_count(#count_st{namespace = Namespace, metric = Metric, count = Count, dims = DimsSt}) ->
    try
        FullNamespace = full_namespace(Namespace),
        validate_namespace(FullNamespace),
        Tags = dims_st_to_tags(DimsSt),
        stat:count_d(FullNamespace, Metric, Count, Tags),
        ok
    catch
        error : bad_namespace : _ ->
            {error, bad_namespace};
        Class : Reason : Stacktrace ->
            ?ERROR_MSG("client count error: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, badarg}
    end.


-spec process_events(Uid :: uid(), Events :: [event_st()]) -> [result()].
process_events(Uid, Events) ->
    lists:map(
        fun(Event) ->
            process_event(Uid, Event)
        end,
        Events).


-spec process_event(Uid :: uid(), Event :: event_st()) -> ok.
process_event(Uid, #event_st{namespace = Namespace, event = EventData}) ->
    try
        FullNamespace = full_namespace(Namespace),
        validate_namespace(FullNamespace),
        Ts = util:now_ms(),
        EventJson = jiffy:decode(EventData, [return_maps]),
        EventJson2 = EventJson#{<<"uid">> => Uid},
        EventData2 = jiffy:encode(EventJson2),
        ?INFO_MSG("~s, ~s, ~p, ~s", [FullNamespace, Uid, Ts, EventData2]),
        ok
        % TODO: log the event into CloudWatch Log
    catch
        error : bad_namespace : _ ->
            {error, bad_namespace};
        Class : Reason : Stacktrace ->
            ?ERROR_MSG("client event error: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, badarg}
    end.


-spec is_valid_namespace(Namespace :: binary()) -> boolean().
is_valid_namespace(Namespace) ->
    case re:run(Namespace, ?VALID_NAMESPACE_RE, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.


-spec validate_namespace(Namespace :: binary()) -> ok. % or error bad_namespace
validate_namespace(Namespace) ->
    case is_valid_namespace(Namespace) of
        true ->
            ok;
        false ->
            ?WARNING_MSG("Invalid namespace ~p", [Namespace]),
            erlang:error(bad_namespace)
    end.


-spec full_namespace(Namespace :: binary()) -> binary().
full_namespace(Namespace) ->
    <<?CLIENT_NS/binary, Namespace/binary>>.


dims_st_to_tags(DimsSt) ->
    lists:map(
        fun (#dim_st{name = Name, value = Value}) ->
            {binary_to_list(Name), binary_to_list(Value)}
        end,
        DimsSt
    ).


-spec has_error(Result :: result()) -> boolean().
has_error(Result) ->
    case Result of
        ok -> false;
        {error, _} -> true
    end.

