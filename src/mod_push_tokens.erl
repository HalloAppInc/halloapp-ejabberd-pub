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
    get_push_info/1,
    remove_huawei_token/2,
    remove_android_token/2,
    register_user/4,
    re_register_user/4,
    remove_user/2,
    register_push_info/5,
    is_valid_token_type/1,
    is_appclip_token_type/1
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start", []),
    %% HalloApp
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_push_register, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_notification_prefs, ?MODULE, process_local_iq),
    ejabberd_hooks:add(re_register_user, halloapp, ?MODULE, re_register_user, 10),
    ejabberd_hooks:add(remove_user, halloapp, ?MODULE, remove_user, 10),
    %% Katchup
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_push_register, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_notification_prefs, ?MODULE, process_local_iq),
    ejabberd_hooks:add(register_user, katchup, ?MODULE, register_user, 10),
    ejabberd_hooks:add(re_register_user, katchup, ?MODULE, re_register_user, 10),
    ejabberd_hooks:add(remove_user, katchup, ?MODULE, remove_user, 10),
    ok.


stop(_Host) ->
    ?INFO("stop", []),
    %% HalloApp
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_push_register),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_notification_prefs),
    ejabberd_hooks:delete(re_register_user, halloapp, ?MODULE, re_register_user, 10),
    ejabberd_hooks:delete(remove_user, halloapp, ?MODULE, remove_user, 10),
    %% Katchup
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_push_register),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_notification_prefs),
    ejabberd_hooks:delete(register_user, katchup, ?MODULE, register_user, 10),
    ejabberd_hooks:delete(re_register_user, katchup, ?MODULE, re_register_user, 10),
    ejabberd_hooks:delete(remove_user, katchup, ?MODULE, remove_user, 10),
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

set_default_zone_offset_hr(Uid, Phone) ->
    %% Always set a default zoneoffset for users registering.
    RegionOffsetHr = mod_moment_notification2:get_region_offset_hr(undefined, Phone),
    ZoneOffsetSec = RegionOffsetHr * ?HOURS,
    model_accounts:update_zone_offset_hr_index(Uid, ZoneOffsetSec, undefined),
    ok.

-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
register_user(Uid, _Server, Phone, _CampaignId) ->
    %% Always set a default zoneoffset for users registering.
    set_default_zone_offset_hr(Uid, Phone),
    ok.


-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
re_register_user(Uid, _Server, Phone, _CampaignId) ->
    stat:count("HA/push_tokens", "remove_push_token"),
    %% This will remove all push info including zoneoffset.
    model_accounts:remove_push_info(Uid),
    %% Always set a default zoneoffset for users re-registering.
    set_default_zone_offset_hr(Uid, Phone),
    ok.


-spec remove_user(UserId :: binary(), Server :: binary()) -> ok.
remove_user(UserId, _Server) ->
    stat:count("HA/push_tokens", "remove_push_token"),
    model_accounts:remove_push_info(UserId),
    ok.


-spec process_local_iq(IQ :: iq()) -> iq().
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_push_register{lang_id = LangId, zoneOffset = ZoneOffset,
        push_token = #pb_push_token{token_type = TokenTypeAtom, token = Token}}} = IQ) ->
    ?INFO("Uid: ~s, set_push_token, TokenType: ~p, LangId: ~p, ZoneOffset: ~p", [Uid, TokenTypeAtom, LangId, ZoneOffset]),
    %% TODO: switch to using atoms everywhere.
    TokenType = util:to_binary(TokenTypeAtom),
    IsValidTokenType = is_valid_token_type(TokenType),
    if
        Token =:= <<>> ->
            ?WARNING("Uid: ~s, received push token is empty!", [Uid]),
            pb:make_error(IQ, util:err(invalid_push_token));
        IsValidTokenType =:= false ->
            ?WARNING("Uid: ~s, invalid token_type attribute: ~s!", [Uid, TokenType]),
            pb:make_error(IQ, util:err(invalid_token_type));
        true ->
            ok = register_push_info(Uid, TokenType, Token, LangId, ZoneOffset),
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


%% We only store them for now and dont do much with it yet.
%% We could have the clients fetch this info again on re-registration.
%% But we dont support that yet - so just storing them for now and counting.
-spec update_push_pref(Uid :: binary(), pb_push_pref()) -> ok.
update_push_pref(Uid, #pb_push_pref{name = post, value = Value}) ->
    StatNamespace = util:get_stat_namespace(Uid),
    stat:count(StatNamespace ++ "/push_prefs", "set_push_post_pref"),
    ?INFO("set_push_post_pref ~s's to be: ~s", [Uid, Value]),
    model_accounts:set_push_post_pref(Uid, Value);

update_push_pref(Uid, #pb_push_pref{name = comment, value = Value}) ->
    StatNamespace = util:get_stat_namespace(Uid),
    stat:count(StatNamespace ++ "/push_prefs", "set_push_comment_pref"),
    ?INFO("set_push_comment_pref ~s's to be: ~s", [Uid, Value]),
    model_accounts:set_push_comment_pref(Uid, Value);

update_push_pref(Uid, #pb_push_pref{name = mentions, value = Value}) ->
    StatNamespace = util:get_stat_namespace(Uid),
    stat:count(StatNamespace ++ "/push_prefs", "set_push_mention_pref"),
    ?INFO("set_push_mention_pref ~s's to be: ~s", [Uid, Value]),
    model_accounts:set_push_mention_pref(Uid, Value);

update_push_pref(Uid, #pb_push_pref{name = on_fire, value = Value}) ->
    StatNamespace = util:get_stat_namespace(Uid),
    stat:count(StatNamespace ++ "/push_prefs", "set_push_fire_pref"),
    ?INFO("set_push_fire_pref ~s's to be: ~s", [Uid, Value]),
    model_accounts:set_push_fire_pref(Uid, Value);

update_push_pref(Uid, #pb_push_pref{name = new_users, value = Value}) ->
    StatNamespace = util:get_stat_namespace(Uid),
    stat:count(StatNamespace ++ "/push_prefs", "set_push_new_user_pref"),
    ?INFO("set_push_new_user_pref ~s's to be: ~s", [Uid, Value]),
    model_accounts:set_push_new_user_pref(Uid, Value);

update_push_pref(Uid, #pb_push_pref{name = followers, value = Value}) ->
    StatNamespace = util:get_stat_namespace(Uid),
    stat:count(StatNamespace ++ "/push_prefs", "set_push_follower_pref"),
    ?INFO("set_push_follower_pref ~s's to be: ~s", [Uid, Value]),
    model_accounts:set_push_follower_pref(Uid, Value).


%% TODO(murali@): add counters by push languageId.
-spec register_push_info(Uid :: binary(), TokenType :: binary(),
        Token :: binary(), LangId :: binary(), ZoneOffset :: integer()) -> ok.
register_push_info(Uid, TokenType, Token, LangId, ZoneOffset) when TokenType =:= ?IOS_VOIP_TOKEN_TYPE ->
    LanguageId = get_language_id(LangId),
    TimestampMs = util:now_ms(),
    ok = model_accounts:set_voip_token(Uid, Token, TimestampMs, LanguageId, ZoneOffset),
    stat:count("HA/push_tokens", "set_voip_token"),
    ok;
register_push_info(Uid, TokenType, Token, LangId, ZoneOffset) when TokenType =:= ?ANDROID_HUAWEI_TOKEN_TYPE ->
    LanguageId = get_language_id(LangId),
    TimestampMs = util:now_ms(),
    ok = model_accounts:set_huawei_token(Uid, Token, TimestampMs, LanguageId, ZoneOffset),
    stat:count("HA/push_tokens", "set_huawei_token"),
    ok;
register_push_info(Uid, TokenType, Token, LangId, ZoneOffset) ->
    LanguageId = get_language_id(LangId),
    TimestampMs = util:now_ms(),
    ok = model_accounts:set_push_token(Uid, TokenType, Token, TimestampMs, LanguageId, ZoneOffset),
    stat:count("HA/push_tokens", "set_push_token"),
    ok.


-spec get_push_info(Uid :: binary()) -> push_info().
get_push_info(Uid) ->
    {ok, RedisPushInfo} = model_accounts:get_push_info(Uid),
    RedisPushInfo.


-spec remove_android_token(Uid :: binary(), Server :: binary()) -> ok.
remove_android_token(Uid, _Server) ->
    ok = model_accounts:remove_android_token(Uid),
    ok.


-spec remove_huawei_token(Uid :: binary(), Server :: binary()) -> ok.
remove_huawei_token(Uid, _Server) ->
    ok = model_accounts:remove_huawei_token(Uid),
    ok.


-spec get_language_id(LangId :: undefined | binary()) -> binary().
get_language_id(undefined) -> <<"en-US">>;
get_language_id(LangId) -> LangId.


-spec is_valid_token_type(TokenType :: binary()) -> boolean().
is_valid_token_type(TokenType) ->
    case TokenType of
        ?IOS_TOKEN_TYPE -> true;
        ?IOS_DEV_TOKEN_TYPE -> true;
        ?IOS_APPCLIP_TOKEN_TYPE -> true;
        ?IOS_VOIP_TOKEN_TYPE -> true;
        ?ANDROID_TOKEN_TYPE -> true;
        ?ANDROID_HUAWEI_TOKEN_TYPE -> true;
        _ -> false
    end.


-spec is_appclip_token_type(TokenType :: binary()) -> boolean().
is_appclip_token_type(?IOS_APPCLIP_TOKEN_TYPE) -> true;
is_appclip_token_type(_) -> false.

