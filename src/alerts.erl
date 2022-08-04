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
    send_iam_role_change_alert/2,
    send_noise_slow_alert/2,
    send_noise_unreachable_alert/2,
    send_port_slow_alert/2,
    send_port_unreachable_alert/2,
    send_process_down_alert/2,
    send_process_slow_alert/2,
    send_process_unreachable_alert/2,
    send_alert/4
]).

-include("logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(ALERTS_MANAGER_URL, "http://m1.ha:9093/api/v1/alerts").

%%====================================================================
%% API
%%====================================================================
%% TODO@murali: add counters here

-spec send_iam_role_change_alert(Host :: binary(), Message :: binary()) -> ok.
send_iam_role_change_alert(Host, Message) ->
    send_alert(<<Host/binary, " IAM role change">>, Host, <<"critical">>, Message).


-spec send_noise_slow_alert(Host :: binary(), Message :: binary()) -> ok.
send_noise_slow_alert(Host, Message) ->
    send_alert(<<Host/binary, " noise slow">>, Host, <<"critical">>, Message).


-spec send_noise_unreachable_alert(Proc :: binary(), Message :: binary()) -> ok.
send_noise_unreachable_alert(Host, Message) ->
    send_alert(<<Host/binary, " noise unreachable">>, Host, <<"critical">>, Message).


-spec send_port_slow_alert(Host :: binary(), Message :: binary()) -> ok.
send_port_slow_alert(Host, Message) ->
    send_alert(<<Host/binary, "'s /api/_ok page is slow">>, Host, <<"critical">>, Message).


-spec send_port_unreachable_alert(Proc :: binary(), Message :: binary()) -> ok.
send_port_unreachable_alert(Host, Message) ->
    send_alert(<<Host/binary, "'s /api/_ok page unreachable">>, Host, <<"critical">>, Message).


-spec send_process_down_alert(Proc :: binary(), Message :: binary()) -> ok.
send_process_down_alert(Proc, Message) ->
    send_alert(<<"Process Down: ", Proc/binary>>, Proc, <<"critical">>, Message).


-spec send_process_slow_alert(Proc :: binary(), Message :: binary()) -> ok.
send_process_slow_alert(Proc, Message) ->
    send_alert(<<"Process Slow: ", Proc/binary>>, Proc, <<"critical">>, Message).


-spec send_process_unreachable_alert(Proc :: binary(), Message :: binary()) -> ok.
send_process_unreachable_alert(Proc, Message) ->
    send_alert(<<"Process Unreachable: ", Proc/binary>>, Proc, <<"critical">>, Message).


% TODO(nikola): this API would be better if doesn't only accept binaries
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
        test -> ?debugFmt("~s alert: service = ~s, severity = ~s, message = ~s",
            [Alertname, Service, Severity, Message]);
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

