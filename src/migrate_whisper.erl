%%%-------------------------------------------------------------------
%%% Redis migration related to whisper keys
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_whisper).
-author(murali).

-include("logger.hrl").
-include("time.hrl").
-include("whisper.hrl").
-include("account.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    refresh_otp_keys_run/2,
    check_users_by_whisper_keys/2
]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         refresh otp keys for some accounts                       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Keep until we turn on encryption for all users. Revisit 2021-07-01
refresh_otp_keys_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, Version} = q(ecredis_accounts, ["HGET", FullKey, <<"cv">>]),
            case Version of
                undefined ->
                    ?ERROR("Undefined client version for a uid: ~p", [Uid]);
                _ ->
                    case util_ua:get_client_type(Version) =:= android andalso
                        util_ua:is_version_greater_than(Version, <<"HalloApp/Android0.131">>) of
                        false -> ok;
                        %% refresh otp keys for all android accounts with version > 0.131
                        true ->
                            case DryRun of
                                true ->
                                    ?INFO("Uid: ~p, would refresh keys for: ~p", [Uid, Version]);
                                false ->
                                    ?INFO("Uid: ~p, Version: ~p", [Uid, Version]),
                                    ok = mod_whisper:refresh_otp_keys(Uid)
                            end
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Compute user counts by whisper keys                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_users_by_whisper_keys(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            %% Don't fetch Otp keys.
            {ok, KeySet} = model_whisper_keys:get_key_set_without_otp(Uid),
            case KeySet of
                undefined ->
                    ?INFO("Uid: ~p, Keys undefined, ~s", [Uid, migrate_utils:user_details(Uid)]);
                _ ->
                    #user_whisper_key_set{uid = Uid, identity_key = IdentityKey,
                        signed_key = SignedKey, one_time_key = OneTimeKey} = KeySet,
                    ?assertEqual(OneTimeKey, undefined),
                    case is_invalid_key(IdentityKey) orelse is_invalid_key(SignedKey) of
                        true ->
                            ?INFO("Uid: ~p, Keys invalid, (Identity: ~p), (Signed: ~p), ~s",
                                [Uid, is_invalid_key(IdentityKey), is_invalid_key(SignedKey),
                                    migrate_utils:user_details(Uid)]);
                        _ -> ?INFO("Uid: ~p, Keys ok", [Uid])
                    end
            end;
        _ -> ok
    end,
    State.


is_invalid_key(Key) ->
    Key == undefined orelse not is_binary(Key) orelse byte_size(Key) == 0.


q(Client, Command) -> util_redis:q(Client, Command).
%%qp(Client, Commands) -> util_redis:qp(Client, Commands).

