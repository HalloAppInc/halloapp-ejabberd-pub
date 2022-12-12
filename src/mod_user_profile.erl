%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_user_profile).
-author("josh").

-include("ha_types.hrl").
-include("logger.hrl").
-include("packets.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    process_local_iq/1
]).

%%====================================================================
%% gen_mod API
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_user_profile_request, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_user_profile_request),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% IQ handlers
%%====================================================================

%% UserProfileRequest for uid
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_user_profile_request{uid = Ouid}} = Iq) when Ouid =/= undefined andalso Ouid =/= <<>> ->
    process_user_profile_request(Uid, Ouid, Iq);

%% UserProfileRequest for username
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_user_profile_request{username = Username}} = Iq)
        when Username =/= undefined andalso Username =/= <<>> ->
    {ok, Ouid} = model_accounts:get_username_uid(Username),
    process_user_profile_request(Uid, Ouid, Iq);

%% UserProfileRequest (invalid)
process_local_iq(#pb_iq{payload = #pb_user_profile_request{}} = Iq) ->
    Ret = #pb_user_profile_result{
        result = fail,
        reason = unknown_reason
    },
    pb:make_iq_result(Iq, Ret).

%%====================================================================
%% Internal functions
%%====================================================================

process_user_profile_request(Uid, Ouid, Iq) ->
    Ret = case model_accounts:account_exists(Ouid) andalso not model_follow:is_blocked_any(Uid, Ouid) of
        true ->
            UserProfile = model_accounts:get_user_profiles(Uid, Ouid),
            #pb_user_profile_result{
                result = ok,
                profile = UserProfile
            };
        false ->
            #pb_user_profile_result{
                result = fail,
                reason = no_user
            }
    end,
    pb:make_iq_result(Iq, Ret).

