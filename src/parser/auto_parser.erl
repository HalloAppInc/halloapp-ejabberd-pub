%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 14. Aug 2020 2:43 PM
%%%-------------------------------------------------------------------
-module(auto_parser).
-author("nikola").

%% API
-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).

-define(X2P, #{
    client_log_st => pb_client_log,
    count_st => pb_count,
    pb_event => pb_event,  % we use the pb_event without translation
    dim_st => pb_dim
}).

-define(P2X, #{
    pb_client_log => client_log_st,
    pb_count => count_st,
    pb_event => pb_event,  % we use the pb_event without translation
    pb_dim => dim_st
}).


xmpp_to_proto(X) when is_list(X) ->
    lists:map(fun xmpp_to_proto/1, X);
xmpp_to_proto(X) when is_tuple(X) ->
    L = tuple_to_list(X),
    L2 = lists:map(fun xmpp_to_proto/1, L),
    list_to_tuple(L2);
xmpp_to_proto(X) when is_atom(X) ->
    case maps:get(X, ?X2P, undefined) of
        undefined -> X;
        NewX -> NewX
    end;
xmpp_to_proto(X) ->
    X.


proto_to_xmpp(X) when is_list(X) ->
    lists:map(fun proto_to_xmpp/1, X);
proto_to_xmpp(X) when is_tuple(X) ->
    L = tuple_to_list(X),
    L2 = lists:map(fun proto_to_xmpp/1, L),
    list_to_tuple(L2);
proto_to_xmpp(X) when is_atom(X) ->
    case maps:get(X, ?P2X, undefined) of
        undefined -> X;
        NewX -> NewX
    end;
proto_to_xmpp(X) ->
    X.
