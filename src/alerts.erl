%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% Send alerts to Alerts Manager
%%% @end
%%% Created : 09. Jul 2021 4:13 PM
%%%-------------------------------------------------------------------
-module(alerts).
-author("josh").

%% API
-export([
    send_process_down_alert/2,
    send_unreachable_process_alert/2,
    send_slow_process_alert/2,
    send_alert/4
]).

-include("logger.hrl").

-define(ALERTS_MANAGER_URL, "http://m1.ha:9093/api/v1/alerts").

%%====================================================================
%% API
%%====================================================================

%% TODO(murali@): add counters here.
-spec send_process_down_alert(Proc :: binary(), Message :: binary()) -> ok.
send_process_down_alert(Proc, Message) ->
    send_alert(<<"Process Down: ", Proc/binary>>, Proc, <<"critical">>, Message).

-spec send_unreachable_process_alert(Proc :: binary(), Message :: binary()) -> ok.
send_unreachable_process_alert(Proc, Message) ->
    send_alert(<<"Process Unreachable: ", Proc/binary>>, Proc, <<"critical">>, Message).

-spec send_slow_process_alert(Proc :: binary(), Message :: binary()) -> ok.
send_slow_process_alert(Proc, Message) ->
    send_alert(<<"Process Slow: ", Proc/binary>>, Proc, <<"critical">>, Message).

-spec send_alert(Alertname :: binary(), Service :: binary(), Severity :: binary(), Message :: binary()) -> ok.
send_alert(Alertname, Service, Severity, Message) ->
    URL = ?ALERTS_MANAGER_URL,
    Headers = [],
    Type = "application/json",
    Body = compose_alerts_body(Alertname, Service, Severity, Message),
    HTTPOptions = [],
    Options = [],
    ?DEBUG("alerts_url : ~p", [URL]),
    case config:get_hallo_env() of
        localhost -> ?CRITICAL("~s alert: service = ~s, severity = ~s, message = ~s",
            [Alertname, Service, Severity, Message]);
        _ ->
            Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
            case Response of
                {ok, {{_, 200, _}, _ResHeaders, _ResBody}} ->
                    ?INFO("Sent an alert successfully.", []);
                _ ->
                    ?CRITICAL("Failed to send ~p alert: service = ~s, severity = ~s, message = ~s, resp: ~p",
                        [Alertname, Service, Severity, Message, Response])
            end
    end,
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

compose_alerts_body(Alertname, Service, Severity, Message) ->
    jiffy:encode([#{
        <<"status">> => <<"firing">>,
        <<"labels">> => #{
            <<"alertname">> => Alertname,
            <<"service">> => Service,
            <<"severity">> => Severity,
            <<"instance">> => util:to_binary(node()),
            <<"message">> => Message
        }
    }]).

