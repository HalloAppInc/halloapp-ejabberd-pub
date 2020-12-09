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
    process_local_iq/1,
    process_client_count_log_st/3
]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ha_types.hrl").
-include("packets.hrl").


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
process_local_iq(#iq{type = set, from = #jid{luser = Uid, lresource = Resource},
        sub_els = [#client_log_st{} = ClientLogsSt]} = IQ) ->
    try
        Platform = util_ua:resource_to_client_type(Resource),
        case process_client_count_log_st(Uid, ClientLogsSt, Platform) of
            ok ->
                xmpp:make_iq_result(IQ);
            error ->
                xmpp:make_error(IQ, util:err(bad_request))
        end
    catch
        Class : Reason : Stacktrace ->
            ?ERROR("client log error: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            xmpp:make_error(IQ, util:err(server_error))
    end;

process_local_iq(#iq{} = IQ) ->
    xmpp:make_error(IQ, util:err(bad_request)).

-spec process_client_count_log_st(Uid :: uid() | undefined, ClientLogSt :: client_log_st(),
        Platform :: maybe(client_type())) -> ok | error.
process_client_count_log_st(Uid, ClientLogsSt, Platform) ->
    ServerDims = [{"platform", atom_to_list(Platform)}],
    Counts = ClientLogsSt#client_log_st.counts,
    Events = ClientLogsSt#client_log_st.events,
    ?INFO("Uid: ~s counts: ~p, events: ~p", [Uid, length(Counts), length(Events)]),
    CountResults = process_counts(Uid, Counts, ServerDims),
    EventResults = process_events(Uid, Events),
    CountError = lists:any(fun has_error/1, CountResults),
    EventError = lists:any(fun has_error/1, EventResults),
    case CountError or EventError of
        true -> error;
        false -> ok
    end.


-spec process_counts(Uid :: uid(), Counts :: [count_st()], ServerDims :: stat:tags()) -> [result()].
process_counts(Uid, Counts, ServerDims) ->
    lists:map(
        fun (C) ->
            process_count(Uid, C, ServerDims)
        end, Counts).


% TODO: validate the number of dims is < 6
% TODO: validate the name and value of each dimension
-spec process_count(Uid :: uid(), Counts :: count_st(), ServerTags :: stat:tags()) -> result() .
process_count(Uid, #count_st{namespace = Namespace, metric = Metric, count = Count, dims = DimsSt},
        ServerTags) ->
    try
        FullNamespace = full_namespace(Namespace),
        validate_namespace(FullNamespace),
        Tags = dims_st_to_tags(DimsSt),
        Tags2 = Tags ++ ServerTags, 
        % TODO: make sure to override duplicate keys in Tags with ServerTags
        ?INFO("~s, ~s, ~p", [FullNamespace, Uid, Tags2]),
        stat:count(binary_to_list(FullNamespace), binary_to_list(Metric), Count, Tags2),
        ok
    catch
        error : bad_namespace : _ ->
            {error, bad_namespace};
        Class : Reason : Stacktrace ->
            ?ERROR("client count error: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, badarg}
    end.


-spec process_events(Uid :: uid(), Events :: [pb_event_data()]) -> [result()].
process_events(Uid, Events) ->
    lists:map(
        fun(Event) ->
            process_event(Uid, Event)
        end,
        Events).


-spec process_event(Uid :: uid(), Event :: pb_event_data()) -> ok.
process_event(Uid, #pb_event_data{edata = Edata} = Event) ->
    try
        Namespace = get_namespace(Edata),
        FullNamespace = full_namespace(Namespace),
        validate_namespace(FullNamespace),
        Ts = util:now_ms(),
        Event2 = Event#pb_event_data{uid = binary_to_integer(Uid)},
        case enif_protobuf:encode(Event2) of
            {error, Reason1} ->
                ?ERROR("Failed to process event ~p, Event: ~p", [Reason1, Event]),
                {error, bad_arg};
            Data when is_binary(Data) ->
                ?INFO("~s, ~s, ~p, ~p", [FullNamespace, Uid, Ts, Data]),
                ok
        end
        % TODO: log the event into CloudWatch Log or Kinesis Stream or S3
    catch
        error : bad_edata : _ ->
            ?WARNING("bad_edata Uid: ~s Event: ~p", [Uid, Event]),
            {error, bad_edata};
        error : bad_namespace : _ ->
            {error, bad_namespace};
        Class : Reason : Stacktrace ->
            ?ERROR("client event error: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, badarg}
    end.


get_namespace(Edata) when is_tuple(Edata) ->
    Namespace1 = atom_to_list(element(1, Edata)),
    % removing the "pb_"
    Namespace2 = case string:sub_string(Namespace1, 1, 3) of
        "pb_" -> string:sub_string(Namespace1, 4);
        _ -> Namespace1
    end,
    list_to_binary(Namespace2);
get_namespace(_Edata) ->
    error(bad_edata).


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
            ?WARNING("Invalid namespace ~p", [Namespace]),
            erlang:error(bad_namespace)
    end.


-spec full_namespace(Namespace :: binary()) -> binary().
full_namespace(Namespace) ->
    <<?CLIENT_NS/binary, Namespace/binary>>.


dims_st_to_tags(DimsSt) ->
    lists:map(
        fun (#dim_st{name = Name, value = Value}) ->
            {binary_to_list(Name), fix_tag_value(binary_to_list(Value))}
        end,
        DimsSt
    ).

fix_tag_value(Value) ->
    lists:flatten(string:replace(Value, " ", "_", all)).


-spec has_error(Result :: result()) -> boolean().
has_error(Result) ->
    case Result of
        ok -> false;
        {error, _} -> true
    end.

