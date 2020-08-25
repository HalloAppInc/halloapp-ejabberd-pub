%%%----------------------------------------------------------------------
%%% File    : util_parser.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles utility functions related to parser modules.
%%%----------------------------------------------------------------------

-module(util_parser).
-author('murali').

-export([
    xmpp_to_proto_uid/1,
    proto_to_xmpp_uid/1,
    maybe_convert_to_binary/1
]).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.


xmpp_to_proto_uid(XmppUid) ->
	case XmppUid of
        undefined -> undefined;
        <<>> -> 0;
        U -> binary_to_integer(U)
    end.


proto_to_xmpp_uid(PbUid) ->
	case PbUid of
        undefined -> undefined;
        0 -> <<>>;
        U -> integer_to_binary(U)
    end.


maybe_convert_to_binary(undefined) -> undefined;
maybe_convert_to_binary(Data) -> util:to_binary(Data).

