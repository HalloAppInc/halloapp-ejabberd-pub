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
    check_phone_numbers_run/2
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

q(Client, Command) -> util_redis:q(Client, Command).
qp(Client, Commands) -> util_redis:qp(Client, Commands).
