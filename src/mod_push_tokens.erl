%%%-----------------------------------------------------------------------------------
%%% File    : mod_push_tokens.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all iq-queries of type set and get for push_tokens for users.
%%%
%%%-----------------------------------------------------------------------------------

-module(mod_push_tokens).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("account.hrl").

-define(NS_PUSH, <<"halloapp:push:notifications">>).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% iq handler and API.
-export([
    process_local_iq/1,
    get_push_info/2,
    remove_push_token/2
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO_MSG("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_PUSH, ?MODULE, process_local_iq),
    ok.


stop(Host) ->
    ?INFO_MSG("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_PUSH),
    ok.


depends(_Host, _Opts) ->
    [].


reload(_Host, _NewOpts, _OldOpts) ->
    ok.


mod_options(_Host) ->
    [].


%%====================================================================
%% hooks.
%%====================================================================

-spec process_local_iq(IQ :: iq()) -> iq().
process_local_iq(#iq{from = #jid{luser = Uid, lserver = Server}, type = set, lang = Lang,
        to = _Host, sub_els = [#push_register{push_token = {Os, Token}}]} = IQ) ->
    ?INFO_MSG("Uid: ~s, set-iq for push_token", [Uid]),
    IsValidOs = is_valid_push_os(Os),
    if
        Token =:= <<>> ->
            ?WARNING_MSG("Uid: ~s, received push token is empty!", [Uid]),
            Txt = ?T("Invalid value for token."),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        IsValidOs =:= false ->
            ?WARNING_MSG("Uid: ~s, invalid os attribute: ~s!", [Uid, Os]),
            Txt = ?T("Invalid os attribute: ios/ios_dev/android expected."),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        true ->
            ok = register_push_info(Uid, Server, Os, Token),
            xmpp:make_iq_result(IQ)
    end;
process_local_iq(#iq{lang = Lang} = IQ) ->
    Txt = ?T("Unable to handle this IQ"),
    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang)).



-spec register_push_info(Uid :: binary(), Server :: binary(),
        Os :: binary(), Token :: binary()) -> ok.
register_push_info(Uid, Server, Os, Token) ->
    TimestampMs = util:now_ms(),
    ok = model_accounts:set_push_token(Uid, Os, Token, TimestampMs),
    stat:count("HA/push_tokens", "set_push_token"),
    ok.


-spec get_push_info(Uid :: binary(), Server :: binary()) -> undefined | push_info().
get_push_info(Uid, Server) ->
    {ok, RedisPushInfo} = model_accounts:get_push_info(Uid),
    RedisPushInfo.


-spec remove_push_token(Uid :: binary(), Server :: binary()) -> ok.
remove_push_token(Uid, Server) ->
    ok = model_accounts:remove_push_token(Uid),
    stat:count("HA/push_tokens", "remove_push_token"),
    ok.


%% TODO(murali@): remove this function after successful migration.
-spec compare_push_info_result(Uid :: binary(), RedisPushInfo :: push_info(),
        MnesiaPushInfo :: push_info()) -> boolean().
compare_push_info_result(Uid, RedisPushInfo, MnesiaPushInfo) ->
    case RedisPushInfo =:= MnesiaPushInfo of
        true -> ?INFO_MSG("Uid: ~s push tokens match on mnesia and redis", [Uid]);
        false -> ?ERROR_MSG("Uid: ~s, push tokens do not match on mnesia: ~p and redis: ~p",
                [Uid, MnesiaPushInfo, RedisPushInfo])
    end.


-spec is_valid_push_os(Os :: binary()) -> boolean().
is_valid_push_os(<<"ios">>) ->
    true;
is_valid_push_os(<<"ios_dev">>) ->
    true;
is_valid_push_os(<<"android">>) ->
    true;
is_valid_push_os(_) ->
    false.

