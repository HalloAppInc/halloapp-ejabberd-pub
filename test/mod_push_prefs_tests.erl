%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 04. Aug 2020 12:32 PM
%%%-------------------------------------------------------------------
-module(mod_push_prefs_tests).
-author("yexin").

-include("ha_types.hrl").
-include("account.hrl").
-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").

%% -------------------------------------------- %%
%% define push preferences constants
%% -------------------------------------------- %%

-define(SERVER, <<"s.halloapp.net">>).
-define(UID1, <<"10000000003765032">>).
-define(PHONE1, <<"14703381473">>).
-define(UA1, <<"ios">>).
-define(NAME1, <<"alice">>).

-define(UID2, <<"20000000003765036">>).
-define(PHONE2, <<"14203381473">>).
-define(UA2, <<"ios">>).
-define(NAME2, <<"john">>).

-define(UID3, <<"30000000003765036">>).
-define(PHONE3, <<"14783381473">>).
-define(UA3, <<"ios">>).
-define(NAME3, <<"kelly">>).

-define(POST_PREF,
    #pb_push_pref{
        name = post,
        value = false
    }
).

-define(COMMENT_PREF,
    #pb_push_pref{
        name = comment,
        value = false
    }
).


%% -------------------------------------------- %%
%% helper functions
%% -------------------------------------------- %%


setup() ->
    tutil:setup(),
    stringprep:start(),
    ha_redis:start(),
    clear(),
    ok.

clear() ->
  tutil:cleardb(redis_accounts).

create_set_pref_iq(Uid, PushPrefs) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = #pb_notification_prefs{push_prefs = PushPrefs}
    }.

setup_accounts(Accounts) ->
    lists:foreach(
        fun([Uid, Phone, Name, UserAgent]) ->
            AppType = util_uid:get_app_type(Uid),
            ok = model_accounts:create_account(Uid, Phone, Name, UserAgent),
            ok = model_phone:add_phone(Phone, AppType, Uid)
        end, Accounts),
    ok.


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


post_pref_test() ->
    setup(),
    setup_accounts([[?UID1, ?PHONE1, ?NAME1, ?UA1]]),
    PushInfo1 = mod_push_tokens:get_push_info(?UID1),
    ?assertEqual(true, PushInfo1#push_info.post_pref),
    mod_push_tokens:process_local_iq(create_set_pref_iq(?UID1, [?POST_PREF])),
    PushInfo2 = mod_push_tokens:get_push_info(?UID1),
    ?assertEqual(false, PushInfo2#push_info.post_pref).


comment_pref_test() ->
    setup(),
    setup_accounts([
        [?UID2, ?PHONE2, ?NAME2, ?UA2]]),
    PushInfo1 = mod_push_tokens:get_push_info(?UID2),
    ?assertEqual(true, PushInfo1#push_info.comment_pref),
    mod_push_tokens:process_local_iq(create_set_pref_iq(?UID2, [?COMMENT_PREF])),
    PushInfo2 = mod_push_tokens:get_push_info(?UID2),
    ?assertEqual(false, PushInfo2#push_info.comment_pref).


post_and_comment_pref_test() ->
    setup(),
    setup_accounts([
        [?UID3, ?PHONE3, ?NAME3, ?UA3]]),
    PushInfo1 = mod_push_tokens:get_push_info(?UID3),
    ?assertEqual(true, PushInfo1#push_info.post_pref),
    ?assertEqual(true, PushInfo1#push_info.comment_pref),
    mod_push_tokens:process_local_iq(create_set_pref_iq(?UID3, [?POST_PREF, ?COMMENT_PREF])),
    PushInfo2 = mod_push_tokens:get_push_info(?UID3),
    ?assertEqual(false, PushInfo2#push_info.post_pref),
    ?assertEqual(false, PushInfo2#push_info.comment_pref).

