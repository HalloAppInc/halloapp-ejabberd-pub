%%%----------------------------------------------------------------------
%%% File    : mod_invites.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This file handles the iq packet queries for the invite system.
%%% For information about specific requests see: server/doc/invites_api.md
%%%
%%%----------------------------------------------------------------------
-module(mod_invites).
-author("josh").
-behavior(gen_mod).

-include("account.hrl").
-include("invites.hrl").
-include("logger.hrl").
-include("time.hrl").
-include("packets.hrl").

-ifdef(TEST).
-export([
    get_time_until_refresh/0,
    get_time_until_refresh/1,
    get_last_sunday_midnight/1,
    get_next_sunday_midnight/1,
    init_pre_invite_string_table/0,
    init_invite_string_table/0
]).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([
    process_local_iq/1,
    get_invites_remaining/1,
    get_invites_remaining2/1,
    register_user/4,
    request_invite/2,
    get_invite_strings/1,
    get_invite_strings_bin/1,
    get_invite_string_id/1,
    lookup_invite_string/1,
    list_of_langids_to_keep_cc/0,
    get_pre_invite_strings/1,
    get_pre_invite_strings_bin/1
]).

-define(NS_INVITE, <<"halloapp:invites">>).
-define(NS_INVITE_STATS, "HA/invite").

-define(INVITE_STRINGS_FILE, "invite_strings.json").
-define(PRE_INVITE_STRINGS_FILE, "pre_invite_strings.json").

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_invites_request, ?MODULE, process_local_iq),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    init_pre_invite_string_table(),
    init_invite_string_table(),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_invites_request),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    try
        ets:delete(?INVITE_STRINGS_TABLE),
        ets:delete(?PRE_INVITE_STRINGS_TABLE)
    catch Error:Reason ->
        ?WARNING("Could not delete ets table ~p: ~p: ~p", [?INVITE_STRINGS_TABLE, Error, Reason])
    end,
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

% type = get
process_local_iq(#pb_iq{from_uid = Uid, type = get} = IQ) ->
    AccExists = model_accounts:account_exists(Uid),
    case AccExists of
        false -> pb:make_error(IQ, util:err(no_account));
        true ->
            InvsRem = get_invites_remaining2(Uid),
            Time = get_time_until_refresh(),
            ?INFO("Uid: ~s has ~p invites left, next invites at ~p", [Uid, InvsRem, Time]),
            Result = #pb_invites_response{
                invites_left = InvsRem,
                time_until_refresh = Time
            },
            pb:make_iq_result(IQ, Result)
    end;

% type = set
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_invites_request{invites = InviteList}} = IQ) ->
    AccExists = model_accounts:account_exists(Uid),
    case AccExists of
        false -> pb:make_error(IQ, util:err(no_account));
        true ->
            PhoneList = [P#pb_invite.phone || P <- InviteList],
            ?INFO("Uid: ~s inviting ~p", [Uid, PhoneList]),
            Results = lists:map(fun(Phone) -> request_invite(Uid, Phone) end, PhoneList),
            NewInviteList = lists:map(
                    fun({Ph, Res, Rea}) ->
                        Result = util:to_binary(Res),
                        Reason = case Rea of
                            undefined -> <<>>;
                            _ -> util:to_binary(Rea)
                        end,
                        #pb_invite{phone = Ph, result = Result, reason = Reason}
                    end, Results),
            Ret = #pb_invites_response{
                invites_left = get_invites_remaining2(Uid),
                time_until_refresh = get_time_until_refresh(),
                invites = NewInviteList
            },
            pb:make_iq_result(IQ, Ret)
    end.


-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
register_user(Uid, _Server, Phone, _CampaignId) ->
    {ok, InvitersList} = model_invites:get_inviters_list(Phone),
    give_back_invite(Uid, Phone, InvitersList),
    send_invitee_notice(Uid, InvitersList),
    ok.


-spec request_invite(FromUid :: uid(), ToPhoneNum :: phone()) -> {ToPhoneNum :: phone(),
    ok | failed, maybe(invalid_number | no_invites_left | existing_user)}.
request_invite(FromUid, ToPhoneNum) ->
    stat:count(?NS_INVITE_STATS, "requests"),
    stat:count(?NS_INVITE_STATS, "requests_by_dev", 1, [{is_dev, dev_users:is_dev_uid(FromUid)}]),
    {ok, FromPhone} = model_accounts:get_phone(FromUid),
    FromRegionId = mod_libphonenumber:get_region_id(FromPhone),
    case can_send_invite(FromUid, ToPhoneNum, FromRegionId) of
        {error, already_invited} ->
            ?INFO("Uid: ~s Phone: ~s already_invited", [FromUid, ToPhoneNum]),
            stat:count(?NS_INVITE_STATS, "invite_duplicate"),
            {ToPhoneNum, ok, undefined};
        {error, Reason} ->
            ?INFO("Uid: ~s Phone: ~s error ~p", [FromUid, ToPhoneNum, Reason]),
            stat:count(?NS_INVITE_STATS, "invite_error_" ++ atom_to_list(Reason)),
            {ToPhoneNum, failed, Reason};
        {ok, InvitesLeft, NormalizedPhone} ->
            ?INFO("Uid: ~s Phone: ~s invite successful, ~p invites left",
                [FromUid, ToPhoneNum, InvitesLeft]),
            stat:count(?NS_INVITE_STATS, "invite_success"),
            ToRegionId = mod_libphonenumber:get_region_id(ToPhoneNum),
            stat:count(?NS_INVITE_STATS, "inviter_country", 1, [{country, FromRegionId}]),
            stat:count(?NS_INVITE_STATS, "invited_country", 1, [{country, ToRegionId}]),
            % we used to decrement the invites, not any more
            NumInvitesLeft = InvitesLeft,
            model_invites:record_invite(FromUid, NormalizedPhone, NumInvitesLeft),
            ha_events:log_user_event(FromUid, invite_recorded),
            InviteStringMap = mod_invites:get_invite_strings(FromUid),
            PreInviteStringMap = mod_invites:get_pre_invite_strings(FromUid),
            {ok, LangId1} = model_accounts:get_lang_id(FromUid),
            LangId2 = mod_translate:recast_langid(LangId1),
            LangId3 = case lists:member(LangId2, mod_invites:list_of_langids_to_keep_cc()) of
                true -> LangId2;
                false -> util:remove_cc_from_langid(LangId2)
            end,
            InviteString = case maps:get(LangId3, InviteStringMap, undefined) of
                undefined ->
                    %% Fallback to english
                    maps:get(<<"en">>, InviteStringMap, "");
                InvStr -> InvStr
            end,
            InviteStringId = mod_invites:get_invite_string_id(InviteString),
            PreInviteString = case maps:get(LangId2, PreInviteStringMap, undefined) of
                undefined ->
                    %% Fallback to english
                    maps:get(<<"en">>, PreInviteStringMap, "");
                PreInvStr -> PreInvStr
            end,
            ha_events:log_event(<<"server.invite_sent">>,
                #{
                    uid => FromUid,
                    phone => ToPhoneNum,
                    lang_id => LangId2,
                    invite_string_id => InviteStringId,
                    pre_invite_string => PreInviteString
                }),
            {ToPhoneNum, ok, undefined}
    end.

%%====================================================================
%% Invite string functions
%%====================================================================

-spec get_invite_strings(Uid :: uid()) -> map().
get_invite_strings(Uid) ->
    try
        [{?INVITE_STRINGS_ETS_KEY, InviteStringsMap}] =
            ets:lookup(?INVITE_STRINGS_TABLE, ?INVITE_STRINGS_ETS_KEY),
        InviteStringsMapForCC = rm_invite_strings_by_cc(InviteStringsMap, Uid),
        maps:fold(
            fun(LangId, Strings, Acc) ->
                StringIndex = util:to_integer(Uid) rem length(Strings),
                String = lists:nth(StringIndex + 1, Strings),
                Acc#{LangId => String}
            end,
            #{},
            InviteStringsMapForCC)
    catch
        Class: Reason: Stacktrace  ->
            ?ERROR("Failed to get invite strings for ~s: ~p | ~p | ~p",
                [Uid, Class, Reason, Stacktrace]),
            #{}
    end.


-spec get_invite_strings_bin(Uid :: uid()) -> binary().
get_invite_strings_bin(Uid) ->
    InviteStringsMap = get_invite_strings(Uid),
    jiffy:encode(InviteStringsMap).


%% Returns encoded hash that is used to identify invite string later
-spec get_invite_string_id(InvStr :: string()) -> binary().
get_invite_string_id(InvStr) ->
    <<HashValue:?INVITE_STRING_ID_SHA_HASH_LENGTH_BYTES/binary, _Rest/binary>> =
        crypto:hash(sha256, InvStr),
    base64:encode(HashValue).


%% for `h get-invite-string`
-spec lookup_invite_string(HashId :: binary()) -> ok.
lookup_invite_string(HashId) ->
    try
        case ets:lookup(?INVITE_STRINGS_TABLE, HashId) of
            [{HashId, {LangId, String}}] ->
                io:format("~s: ~s~n", [LangId, String]),
                String;
            [] -> io:format("Invalid Version ID~n", [])
        end
    catch Error : Reason ->
        io:format("Error (~p): ~p~n", [Error, Reason])
    end.


list_of_langids_to_keep_cc() ->
    %% Here we will maintain a list of LangIds that need to keep the CC attached
    %% placeholder value is to appease dialyzer and has no chance of matching on a lang id
    %% if this list is empty, dialyzer will complain due to some lists:member checks that can
    %% never return false
    [<<"placeholder">>].


-spec get_pre_invite_strings(Uid :: uid()) -> map().
get_pre_invite_strings(Uid) ->
    try
        [{?PRE_INVITE_STRINGS_ETS_KEY, PreInviteStringsMap}] =
            ets:lookup(?PRE_INVITE_STRINGS_TABLE, ?PRE_INVITE_STRINGS_ETS_KEY),
        maps:fold(
            fun(LangId, Strings, Acc) ->
                StringIndex = get_pre_invite_str_index(Uid, length(Strings)),
                String = lists:nth(StringIndex + 1, Strings),
                Acc#{LangId => String}
            end,
            #{},
            PreInviteStringsMap)
    catch
        Class: Reason: Stacktrace  ->
            ?ERROR("Failed to get pre invite strings for ~s: ~p | ~p | ~p",
                [Uid, Class, Reason, Stacktrace]),
            #{}
    end.


-spec get_pre_invite_strings_bin(Uid :: uid()) -> binary().
get_pre_invite_strings_bin(Uid) ->
    PreInviteStringsMap = get_pre_invite_strings(Uid),
    jiffy:encode(PreInviteStringsMap).

%%====================================================================
%% Internal functions
%%====================================================================

-spec give_back_invite(Uid :: binary(), Phone :: binary(), InvitersList :: [{binary(), integer()}]) -> ok.
give_back_invite(Uid, Phone, InvitersList) ->
    lists:foreach(
        fun({InviterUid, _Ts}) ->
            ?INFO("Uid: ~p, Phone: ~p accepted invite. InviterUid: ~p", [Uid, Phone, InviterUid]),
            ha_events:log_user_event(InviterUid, invite_accepted),
            InvitesRem = get_invites_remaining(InviterUid),
            FinalNumInvsLeft = min(InvitesRem +1, ?MAX_NUM_INVITES),
            ok = model_invites:set_invites_left(InviterUid, FinalNumInvsLeft)
        end, InvitersList),
    ok.


-spec send_invitee_notice(Uid :: binary(), InvitersList :: [{binary(), integer()}]) -> ok.
send_invitee_notice(Uid, InvitersList) ->
    PbInviters = lists:foldl(
        fun({InviterUid, TimestampBin}, Acc) ->
            case model_accounts:get_account(InviterUid) of
                {ok, Account} ->
                    PbInviter = #pb_inviter{
                        uid = InviterUid,
                        name = Account#account.name,
                        phone = Account#account.phone,
                        timestamp = util:to_integer(TimestampBin)
                    },
                    [PbInviter | Acc];
                _ -> Acc
            end
        end, [], InvitersList),
    Packet = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = Uid,
        type = normal,
        payload = #pb_invitee_notice{
            inviters = PbInviters
        }
    },
    ?INFO("Uid: ~p, MsgId: ~p", [Uid, Packet#pb_msg.id]),
    ejabberd_router:route(Packet),
    ok.


%% Only use this function to poll current invites left
%% Do not use info from this function to do anything except relay info to the user
-spec get_invites_remaining(Uid :: binary()) -> integer().
get_invites_remaining(Uid) ->
    MidnightSunday = get_last_sunday_midnight(),
    {ok, Num, Ts} = model_invites:get_invites_remaining(Uid),
    if
        Ts == undefined -> ?MAX_NUM_INVITES;
        MidnightSunday > Ts -> ?MAX_NUM_INVITES;
        MidnightSunday =< Ts -> Num
    end.

-spec get_invites_remaining2(Uid :: binary()) -> integer().
get_invites_remaining2(_Uid) ->
    ?INF_INVITES.

-spec get_time_until_refresh() -> integer().
get_time_until_refresh() ->
    get_time_until_refresh(util:now()).

get_time_until_refresh(CurrEpochTime) ->
    get_next_sunday_midnight(CurrEpochTime) - CurrEpochTime.


can_send_invite(FromUid, ToPhone, RegionId) ->
    %% Clients are expected to send us the normalized version of the phone number that server
    %% sent them during contact sync.
    %% So we re-add the plus sign and check if the number is valid.
    AppType = util_uid:get_app_type(FromUid),
    NormPhone = mod_libphonenumber:normalized_number(mod_libphonenumber:prepend_plus(ToPhone), RegionId),
    case NormPhone of
        undefined -> {error, invalid_number};
        _ ->
            case model_phone:get_uid(NormPhone, AppType) of
                {ok, undefined} ->
                    IsInvited = model_invites:is_invited_by(NormPhone, FromUid),
                    case IsInvited of
                        true -> {error, already_invited};
                        false ->
                            InvsRem = get_invites_remaining(FromUid),
                            {ok, InvsRem, NormPhone}
                    end;
                {ok, _} -> {error, existing_user}
            end
    end.


% returns timestamp (in seconds) for either the most recent of the upcoming Sunday at 00:00 GMT
% if it is currently sunday at midnight, then get_last_sunday_midnight() == CurrentTime
-spec get_last_sunday_midnight() -> integer().
get_last_sunday_midnight() ->
    get_last_sunday_midnight(util:now()).
get_last_sunday_midnight(CurrTime) ->
    % Jan 1, 1970 was a Thursday, which was 3 days away from Sunday 00:00
    Offset = 3 * ?DAYS,
    Offset + ((CurrTime - Offset) div ?WEEKS) * ?WEEKS.


-spec get_next_sunday_midnight(CurrTime :: non_neg_integer()) -> non_neg_integer().
get_next_sunday_midnight(CurrTime) ->
    get_last_sunday_midnight(CurrTime) + ?WEEKS.


init_pre_invite_string_table() ->
    %% Load invite strings into ets
    try
        ?INFO("Trying to create table for pre invite strings in ets", []),
        ets:new(?PRE_INVITE_STRINGS_TABLE, [named_table, public, {read_concurrency, true}]),
        % load and store invite strings in ets
        % to refresh the invite strings json file, run `make pre-invite-strings`
        Filename = filename:join(misc:data_dir(), ?PRE_INVITE_STRINGS_FILE),
        {ok, Bin} = file:read_file(Filename),
        PreInviteStringsMap = jiffy:decode(Bin, [return_maps]),
        %% en localization strings dont appear with other languages in ios repo for some reason.
        %% TODO: need to fix this in the ios repo.
        %% If adding strings here for a specific country, make sure the LangId for this
        %% appears in the list_of_langids_to_keep_cc function above
        PreInviteStringsMap1 = PreInviteStringsMap#{
            <<"en">> => [
                <<"">>,
                <<"%d contacts on HalloApp">>
            ]
        },
        ets:insert(?PRE_INVITE_STRINGS_TABLE, {?PRE_INVITE_STRINGS_ETS_KEY, PreInviteStringsMap1})
    catch Error:Reason ->
        ?WARNING("Failed to create a table for pre invite strings in ets: ~p: ~p", [Error, Reason])
    end,
    ok.


init_invite_string_table() ->
    %% Load invite strings into ets
    try
        ?INFO("Trying to create table for invite strings in ets", []),
        ets:new(?INVITE_STRINGS_TABLE, [named_table, public, {read_concurrency, true}]),
        % load and store invite strings in ets
        % to refresh the invite strings json file, run `make invite-strings`
        Filename = filename:join(misc:data_dir(), ?INVITE_STRINGS_FILE),
        {ok, Bin} = file:read_file(Filename),
        InviteStringsMap = jiffy:decode(Bin, [return_maps]),
        %% en localization strings dont appear with other languages in ios repo for some reason.
        %% TODO: need to fix this in the ios repo.
        InviteStringsMap1 = InviteStringsMap#{
            <<"en">> => [
                <<"I’m inviting you to join me on HalloApp. It is a private and secure app to share pictures, chat and call your friends. Get it at https://halloapp.com/get"/utf8>>,
                <<"Hey %1$@, I have an invite for you to join me on HalloApp - a real-relationship network for those closest to me. Use %2$@ to register. Get it at https://halloapp.com/dl"/utf8>>,
                <<"Join me on HalloApp – a simple, private, and secure way to stay in touch with friends and family. Get it at https://halloapp.com/dl"/utf8>>,
                <<"Hey %@, I’m on HalloApp. Download to join me https://halloapp.com/install"/utf8>>,
                <<"Hey %@, let’s keep in touch on HalloApp. Download at https://halloapp.com/kit (HalloApp is a new, private social app for close friends and family, with no ads or algorithms)."/utf8>>,
                <<"I am inviting you to install HalloApp. Download for free here: https://halloapp.com/free"/utf8>>,
                <<"Hey %@! Join me on HalloApp, and share real moments with real friends. Check it out: https://halloapp.com/new"/utf8>>
            ]
        },
        ets:insert(?INVITE_STRINGS_TABLE, {?INVITE_STRINGS_ETS_KEY, InviteStringsMap1}),
        %% store shortened hash of each string to identify it later
        %% TODO: use maps:foreach here after upgrade to otp 24
        lists:foreach(
            fun({LangId, Strings}) ->
                lists:foreach(
                    fun(String) ->
                        InviteStringId = get_invite_string_id(String),
                        ets:insert(?INVITE_STRINGS_TABLE, {InviteStringId, {LangId, String}})
                    end,
                    Strings)
            end,
            maps:to_list(InviteStringsMap1))
    catch Error:Reason ->
        ?WARNING("Failed to create a table for invite strings in ets: ~p: ~p", [Error, Reason])
    end,
    ok.


rm_invite_strings_by_cc(InviteStringMap, Uid) ->
    {ok, RawLangId} = model_accounts:get_lang_id(Uid),
    case RawLangId of
        undefined -> InviteStringMap;
        _ ->
            case binary:split(RawLangId, <<"-">>) of
                [RawLangId] -> InviteStringMap;
                [_LangId, CC] ->
                    InvStrsToRm = mod_props:get_invite_strings_to_rm_by_cc(CC),
                    maps:map(
                        fun(LangId, Strings) ->
                            InvStrsToRmForLangId = maps:get(LangId, InvStrsToRm, []),
                            lists:filter(
                                fun(S) -> not lists:member(S, InvStrsToRmForLangId) end,
                                Strings)
                        end,
                        InviteStringMap);
                _ -> ?WARNING("Unexpected LangId for ~s: ~p", [Uid, RawLangId])
            end
    end.


get_pre_invite_str_index(Uid, NumBuckets) ->
    hash_to_bucket(Uid, NumBuckets, <<"pre_inv_str">>).


hash_to_bucket(Uid, NumBuckets, Salt) ->
    Sha = crypto:hash(sha256, <<Uid/binary, Salt/binary>>),
    FirstSize = byte_size(Sha) - 8,
    <<_Rest:FirstSize/binary, Last8:8/binary>> = Sha,
    <<LastInt:64>> = Last8,
    LastInt rem NumBuckets.

