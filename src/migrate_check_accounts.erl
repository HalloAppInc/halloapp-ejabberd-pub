%%%-------------------------------------------------------------------
%%% Redis migrations that check the validity of uid -> phone and phone -> uid mappings
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_check_accounts).
-author('murali').

-include("logger.hrl").

-export([
    check_accounts_run/2,
    log_account_info_run/2,
    check_phone_numbers_run/2,
    check_argentina_numbers_run/2
]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all user accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_accounts_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case Phone of
                undefined ->
                    ?ERROR("Uid: ~p, Phone is undefined!", [Uid]);
                _ ->
                    {ok, PhoneUid} = model_phone:get_uid(Phone),
                    case PhoneUid =:= Uid of
                        true -> ok;
                        false ->
                            ?ERROR("uid mismatch for phone map Uid: ~s Phone: ~s PhoneUid: ~s",
                                [Uid, Phone, PhoneUid]),
                            ok
                    end
            end;
        _ -> ok
    end,
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all phone number accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

log_account_info_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case Phone of
                undefined ->
                    ?INFO("Uid: ~p, Phone is undefined!", [Uid]);
                _ ->
                    NumContacts = model_contacts:count_contacts(Uid),
                    {ok, Friends} = model_friends:get_friends(Uid),
                    {ok, Contacts} = model_contacts:get_contacts(Uid),
                    UidContacts = model_phone:get_uids(Contacts),
                    NumUidContacts = length(maps:to_list(UidContacts)),
                    NumFriends = length(Friends),
                    CC = mod_libphonenumber:get_cc(Phone),
                    ?INFO("Account Uid: ~p, Phone: ~p, CC: ~p, NumContacts: ~p, NumUidContacts: ~p, NumFriends: ~p",
                        [Uid, Phone, CC, NumContacts, NumUidContacts, NumFriends])
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all phone number accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_phone_numbers_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            ?INFO("phone number: ~p", [Phone]),
            {ok, Uid} = model_phone:get_uid(Phone),
            case Uid of
                undefined ->
                    ?ERROR("Phone: ~p, Uid is undefined!", [Uid]);
                _ ->
                    {ok, UidPhone} = model_accounts:get_phone(Uid),
                    case UidPhone =/= undefined andalso UidPhone =:= Phone of
                        true -> ok;
                        false ->
                            ?ERROR("phone: ~p, uid: ~p, uidphone: ~p", [Uid, Phone, UidPhone]),
                            ok
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all argentina accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_argentina_numbers_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case Phone of
                undefined ->
                    ?INFO("Uid: ~p, Phone is undefined!", [Uid]);
                <<"549", _Rest/binary>> ->
                    ?INFO("Account uid: ~p, phone: ~p - valid_phone", [Uid, Phone]);
                <<"54", _Rest/binary>> ->
                    ?INFO("Account uid: ~p, phone: ~p - invalid_phone", [Uid, Phone]);
                _ ->
                    ok
            end;
        _ -> ok
    end,
    State.

q(Client, Command) -> util_redis:q(Client, Command).
qp(Client, Commands) -> util_redis:qp(Client, Commands).

