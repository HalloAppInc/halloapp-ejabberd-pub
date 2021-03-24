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
-include("account.hrl").
-include("packets.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% iq handler and API.
-export([
    process_local_iq/1,
    get_push_info/2,
    remove_push_token/2,
    re_register_user/3,
    remove_user/2,
    register_push_info/5
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_push_register, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_notification_prefs, ?MODULE, process_local_iq),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 10),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 10),
    ok.


stop(Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_push_register),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_notification_prefs),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 10),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 10),
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

-spec re_register_user(UserId :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(UserId, Server, _Phone) ->
    remove_push_token(UserId, Server).


-spec remove_user(UserId :: binary(), Server :: binary()) -> ok.
remove_user(UserId, Server) ->
    remove_push_token(UserId, Server).


-spec process_local_iq(IQ :: pb_iq()) -> pb_iq().
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_push_register{lang_id = LangId,
        push_token = #pb_push_token{os = OsAtom, token = Token}}} = IQ) ->
    Server = util:get_host(),
    ?INFO("Uid: ~s, set-iq for push_token", [Uid]),
    Os = util:to_binary(OsAtom),
    IsValidOs = is_valid_push_os(Os),
    if
        Token =:= <<>> ->
            ?WARNING("Uid: ~s, received push token is empty!", [Uid]),
            pb:make_error(IQ, util:err(invalid_push_token));
        IsValidOs =:= false ->
            ?WARNING("Uid: ~s, invalid os attribute: ~s!", [Uid, Os]),
            pb:make_error(IQ, util:err(invalid_os));
        true ->
            ok = register_push_info(Uid, Server, Os, Token, LangId),
            pb:make_iq_result(IQ)
    end;

process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_notification_prefs{push_prefs = PushPrefs}} = IQ) ->
    ?INFO("Uid: ~s, set-iq for push preferences", [Uid]),
    case PushPrefs of
        [] ->
            ?WARNING("Uid: ~s, push pref list is empty!", [Uid]),
            pb:make_error(IQ, util:err(invalid_prefs));
        _ ->
            lists:foreach(
                fun(PushPref) ->
                    update_push_pref(Uid, PushPref)
                end,
            PushPrefs),
            pb:make_iq_result(IQ)
    end;

process_local_iq(#pb_iq{} = IQ) ->
    ?ERROR("Invalid iq: ~p", [IQ]),
    pb:make_error(IQ, util:err(invalid_iq)).


-spec update_push_pref(Uid :: binary(), pb_push_pref()) -> ok.
update_push_pref(Uid, #pb_push_pref{name = post, value = Value}) ->
    stat:count("HA/push_prefs", "set_push_post_pref"),
    ?INFO("set ~s's push post pref to be: ~s", [Uid, Value]),
    model_accounts:set_push_post_pref(Uid, Value);
update_push_pref(Uid, #pb_push_pref{name = comment, value = Value}) ->
    stat:count("HA/push_prefs", "set_push_comment_pref"),
    ?INFO("set ~s's push comment pref to be: ~s", [Uid, Value]),
    model_accounts:set_push_comment_pref(Uid, Value).


%% TODO(murali@): add counters by push languageId.
-spec register_push_info(Uid :: binary(), Server :: binary(),
        Os :: binary(), Token :: binary(), LangId :: binary()) -> ok.
register_push_info(Uid, _Server, Os, Token, LangId) ->
    LanguageId = get_language_id(LangId),
    TimestampMs = util:now_ms(),
    ok = model_accounts:set_push_token(Uid, Os, Token, TimestampMs, LanguageId),
    stat:count("HA/push_tokens", "set_push_token"),
    ok.


-spec get_push_info(Uid :: binary(), Server :: binary()) -> undefined | push_info().
get_push_info(Uid, _Server) ->
    {ok, RedisPushInfo} = model_accounts:get_push_info(Uid),
    RedisPushInfo.


-spec remove_push_token(Uid :: binary(), Server :: binary()) -> ok.
remove_push_token(Uid, _Server) ->
    ok = model_accounts:remove_push_token(Uid),
    stat:count("HA/push_tokens", "remove_push_token"),
    ok.


-spec get_language_id(LangId :: undefined | binary()) -> binary().
get_language_id(undefined) -> <<"en-US">>;
get_language_id(LangId) -> LangId.


-spec is_valid_push_os(Os :: binary()) -> boolean().
is_valid_push_os(<<"ios">>) ->
    true;
is_valid_push_os(<<"ios_dev">>) ->
    true;
is_valid_push_os(<<"android">>) ->
    true;
is_valid_push_os(_) ->
    false.

