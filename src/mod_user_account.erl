%%%-----------------------------------------------------------------------------------
%%% File    : mod_user_account.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-----------------------------------------------------------------------------------

-module(mod_user_account).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("account.hrl").
-include("packets.hrl").
-include("ejabberd_sm.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% iq handler and API.
-export([
    process_local_iq/1
]).

-define(MAX_FEEDBACK_SIZE, 1000).   %% 1000 utf8 characters


%%====================================================================
%% gen_mod API.
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_delete_account, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_delete_account, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_delete_account),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_delete_account),
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
%% This phone must be sent with the country code.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_delete_account{phone = RawPhone, reason = Reason, feedback = Feedback, username = Username}} = IQ) when RawPhone =/= undefined orelse Username =/= undefined ->
    Server = util:get_host(),
    Feedback2 = case Feedback of
        undefined -> Feedback;
        _ -> string:slice(Feedback, 0, ?MAX_FEEDBACK_SIZE)
    end,
    case Feedback =:= Feedback2 of
        false ->
            ?WARNING("Truncating feedback to |~s| size was: ~p",
                [Feedback2, byte_size(Feedback)]);
        true ->
            ok
    end,
    ?INFO("delete_account Uid: ~s, raw_phone: ~p, username ~p, reason: ~p, feedback: ~s",
        [Uid, RawPhone, Username, Reason, Feedback2]),
    case model_accounts:get_account(Uid) of
        {ok, Account} ->
            %% We now normalize against the user's own region.
            %% So user need not enter their own country code in order to delete their account.
            UidPhone = Account#account.phone,
            CountryCode = mod_libphonenumber:get_cc(UidPhone),
            NormPhone = mod_libphonenumber:normalized_number(RawPhone, CountryCode),
            NormPhoneBin = util:to_binary(NormPhone),
            UidUsername = Account#account.username,
            case UidPhone =:= NormPhoneBin orelse UidUsername =:= Username of
                false ->
                    ?INFO("delete_account failed Uid: ~s", [Uid]),
                    pb:make_error(IQ, util:err(invalid_phone_and_username));
                true ->
                    log_delete_account(Account, Reason, Feedback2),
                    ok = ejabberd_auth:remove_user(Uid, Server),
                    ResponseIq = pb:make_iq_result(IQ, #pb_delete_account{}),
                    ejabberd_router:route(ResponseIq),
                    ok = ejabberd_sm:disconnect_removed_user(Uid, Server),
                    ?INFO("delete_account success Uid: ~s", [Uid]),
                    ignore
            end;
        _ ->
            ?INFO("delete_account failed Uid: ~s", [Uid]),
            pb:make_error(IQ, util:err(invalid_phone_and_username))
    end;

process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_delete_account{phone = undefined, username = undefined}} = IQ) ->
    ?INFO("delete_account, Uid: ~s, raw_phone and username is undefined", [Uid]),
    pb:make_error(IQ, util:err(invalid_phone_and_username));

process_local_iq(#pb_iq{} = IQ) ->
    pb:make_error(IQ, util:err(invalid_request)).


%%====================================================================
%% internal functions.
%%====================================================================


log_delete_account(Account, Reason, Feedback) ->
    Platform = Account#account.client_version,
    Uid = Account#account.uid,
    AppType = util_uid:get_app_type(Uid),
    Phone = Account#account.phone,
    {ok, Friends} = model_friends:get_friends(Uid),
    {ok, Contacts} = model_contacts:get_contacts(Uid),
    UidContacts = model_phone:get_uids(Contacts, AppType),
    NumContacts = length(Contacts),
    NumUidContacts = length(maps:to_list(UidContacts)),
    NumFriends = length(Friends),
    CC = mod_libphonenumber:get_cc(Phone),
    ha_events:log_event(<<"server.deleted_accounts">>, #{
        creation_ts_ms => Account#account.creation_ts_ms,
        last_activity => Account#account.last_activity_ts_ms,
        signup_version => Account#account.signup_user_agent,
        signup_platform => util_ua:get_client_type(Account#account.signup_user_agent),
        cc => CC,
        lang_id => Account#account.lang_id,
        device => Account#account.device,
        os_version => Account#account.os_version,
        num_contacts => NumContacts,
        num_uid_contacts => NumUidContacts,
        num_friends => NumFriends,
        reason => Reason,
        feedback => Feedback,
        uid => Uid
    }),
    stat:count(util:get_stat_namespace(AppType) ++ "/account", "delete", 1, [{cc, CC}, {platform, Platform}]).


