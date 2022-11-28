%%%---------------------------------------------------------------------------------
%%% File    : mod_export.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%% Implement export functionality to allow users to export their data stored on our service.
%%% We will try to export all data that does not automatically expire in 31 days.
%%%---------------------------------------------------------------------------------

-module(mod_export).
-author(nikola).
-behaviour(gen_mod).

-include("logger.hrl").
-include("account.hrl").
-include("groups.hrl").
-include("whisper.hrl").
-include("packets.hrl").
-include("time.hrl").


-ifdef(TEST).
-export([format_privacy_list/1]).
-endif.

%% gen_mod API.
%% IQ handlers and hooks.
-export([
    start/2,
    stop/1,
    reload/3,
    depends/2,
    mod_options/1,
    process_local_iq/1,
    export_bucket/0
]).


-define(EXPORT_WAIT, 3 * ?DAYS).
-define(DEV_EXPORT_WAIT, 1 * ?MINUTES).
-define(S3_EXPORT_BUCKET, "halloapp-export").
-define(AVATAR_CDN, "https://avatar-cdn.halloapp.net/").


start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_export_data, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_export_data),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% iq handlers
%%====================================================================

process_local_iq(#pb_iq{from_uid = Uid, type = get,
    payload = #pb_export_data{}} = IQ) ->
    ?INFO("Uid: ~s, export iq GET", [Uid]),
    ExportWait = get_export_wait(Uid),
    case model_accounts:get_export(Uid) of
        {ok, StartTs, ExportId, TTL} ->
            Payload = make_export_status(ExportId, StartTs, TTL, ExportWait),
            pb:make_iq_result(IQ, Payload);
        {error, missing} ->
            Payload = IQ#pb_iq.payload#pb_export_data{
                status = not_started},
            pb:make_iq_result(IQ, Payload)
    end;

process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_export_data{}} = IQ) ->
    ?INFO("Uid: ~s, export iq SET", [Uid]),
    ExportWait = get_export_wait(Uid),
    case model_accounts:get_export(Uid) of
        {ok, StartTs, ExportId, TTL} ->
            Payload = make_export_status(ExportId, StartTs, TTL, ExportWait),
            pb:make_iq_result(IQ, Payload);
        {error, missing} ->
            {ok, StartTs} = start_export(Uid),
            Payload = IQ#pb_iq.payload#pb_export_data{
                data_ready_ts = StartTs + ExportWait,
                status = pending},
            pb:make_iq_result(IQ, Payload)
    end.

-spec export_bucket() -> string().
export_bucket() ->
    ?S3_EXPORT_BUCKET.

get_export_wait(Uid) ->
    case dev_users:is_dev_uid(Uid) of
        true -> ?DEV_EXPORT_WAIT;
        false -> ?EXPORT_WAIT
    end.


%%====================================================================
%% internal functions
%%====================================================================

make_export_status(ExportId, StartTs, TTL, ExportWait) ->
    case StartTs + ExportWait < util:now() of
        true ->
            #pb_export_data{
                status = ready,
                available_until_ts = util:now() + TTL,
                data_url = get_url(ExportId)};
        false ->
            #pb_export_data{
                data_ready_ts = StartTs + ExportWait,
                status = pending}
    end.


start_export(Uid) ->
    ExportId = util:random_str(32),
    % TODO: handle the error case
    {ok, Ts} = model_accounts:start_export(Uid, ExportId),
    DataMap = export_data(Uid),
    Data = encode_data(DataMap),
    ok = upload_data(ExportId, Data),
    {ok, Ts}.


-spec export_data(Uid :: uid()) -> map().
export_data(Uid) ->
    {ok, Acc} = model_accounts:get_account(Uid),

    Account = #{
        user_id => Acc#account.uid,
        phone => Acc#account.phone,
        name  => Acc#account.name,
        created_at_ms => Acc#account.creation_ts_ms,
        signup_device => Acc#account.signup_user_agent,
        client_version => Acc#account.client_version,
        last_activity_ts_ms => Acc#account.last_activity_ts_ms,
        device => Acc#account.device,
        os_version => Acc#account.os_version
    },
    Account2 = case model_accounts:get_avatar_id_binary(Uid) of
        <<>> -> Account;
        AvatarId -> Account#{avatar => ?AVATAR_CDN ++ binary_to_list(AvatarId)}
    end,

    PushInfo = get_push_info(Uid),
    Invites = get_invites(Uid),

    {ok, Contacts} = model_contacts:get_contacts(Uid),

    Gids = model_groups:get_groups(Uid),
    Groups = lists:map(fun get_group/1, Gids),

    PrivacyLists = get_privacy_lists(Uid),
    WhisperKeys = get_whisper_keys(Uid),
    ?INFO("WP: ~p", [WhisperKeys]),

    AllData = #{
        account => Account2,
        contacts => Contacts,
        groups => Groups,
        invites => Invites,
        push_info => PushInfo,
        privacy_lists => PrivacyLists,
        whisper_keys => WhisperKeys
    },
    AllData.


-spec encode_data(DataMap :: map()) -> iodata().
encode_data(DataMap) ->
    jiffy:encode(DataMap, [pretty]).


-spec get_url(ExportId :: binary()) -> string().
get_url(ExportId) ->
    %% mod_http_export will redirect to s3
    %% "https://" ++ ?S3_EXPORT_BUCKET ++ ".s3.amazonaws.com/"
    URL = "https://halloapp.com/export/" ++ binary_to_list(ExportId),
    URL.

-spec upload_data(ExportId :: binary(), Data :: iodata()) -> ok.
upload_data(ExportId, Data) ->
    ok = upload_s3(ExportId, Data).


upload_s3(ObjectKey, Data) ->
    upload_s3(config:get_hallo_env(), ObjectKey, Data),
    ok.

-spec upload_s3(atom(), binary(), binary()) -> ok.
upload_s3(prod, ObjectKey, Data) ->
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),
    Result = erlcloud_s3:put_object(
        ?S3_EXPORT_BUCKET, binary_to_list(ObjectKey), Data),
    ?INFO("ObjectName: ~p, Result: ~p", [ObjectKey, Result]),
    ok;
upload_s3(_, ObjectKey, Data) ->
    ?INFO("would have uploaded: ~p with data: ~p", [ObjectKey, Data]),
    ok.


-spec get_push_info(Uid :: uid()) -> map().
get_push_info(Uid) ->
    {ok, PushInfo} = model_accounts:get_push_info(Uid),
    #{
        os => PushInfo#push_info.os,
        token => PushInfo#push_info.token,
        voip_token => PushInfo#push_info.voip_token,
        timestamp_ms => PushInfo#push_info.timestamp_ms,
        push_post_pref => PushInfo#push_info.post_pref,
        push_comment_pref => PushInfo#push_info.comment_pref,
        client_version => PushInfo#push_info.client_version,
        lang_id => PushInfo#push_info.lang_id
    }.

-spec get_invites(Uid :: uid()) -> map().
get_invites(Uid) ->
    {ok, NumInvites, _InvTs} = model_invites:get_invites_remaining(Uid),
    {ok, InvitedPhones} = model_invites:get_sent_invites(Uid),
    #{
        num_invites => NumInvites,
        invited_phones => InvitedPhones
    }.

-spec get_group(Gid :: gid()) -> map().
get_group(Gid) ->
    case model_groups:get_group(Gid) of
        undefined -> undefined;
        #group{} = G ->
            #{
                gid => G#group.gid,
                name => G#group.name
                % Not export more then the names of the group for now.
%%                % TODO: convert to url
%%                avatar => G#group.avatar,
%%                % TODO: background
%%                creation_ts_ms => G#group.creation_ts_ms,
%%                members => get_members(G#group.members)
            }
    end.

%%-spec get_members(Members :: [group_member()]) -> [map()].
%%get_members(Members) ->
%%    Uids = [M#group_member.uid || M <- Members],
%%    NamesMap = model_accounts:get_names(Uids),
%%    lists:map(
%%        fun(Member) ->
%%            #{
%%                uid => Member#group_member.uid,
%%                name => maps:get(Member#group_member.uid, NamesMap, unknown),
%%                type => Member#group_member.type,
%%                joined_ts_ms => Member#group_member.joined_ts_ms
%%            }
%%        end,
%%        Members
%%    ).

-spec get_whisper_keys(Uid :: uid()) -> map().
get_whisper_keys(Uid) ->
    {ok, IdentityKey, SignedPreKey, OTKs} = model_whisper_keys:export_keys(Uid),
    #{
        identity_key => IdentityKey,
        signed_key => SignedPreKey,
        one_time_keys => OTKs
    }.

-spec get_privacy_lists(Uid :: uid()) -> map().
get_privacy_lists(Uid) ->
    {ok, OnlyList} = model_privacy:get_only_uids(Uid),
    {ok, ExceptList} = model_privacy:get_except_uids(Uid),
    {ok, BlockedList} = model_privacy:get_blocked_uids(Uid),
    {ok, MuteList} = model_privacy:get_mutelist_uids(Uid),

    {ok, OnlyPhonesList} = model_privacy:get_only_phones(Uid),
    {ok, ExceptPhonesList} = model_privacy:get_except_phones(Uid),
    {ok, BlockedPhonesList} = model_privacy:get_blocked_phones(Uid),
    {ok, MutePhonesList} = model_privacy:get_mutelist_phones(Uid),

    {ok, PrivacyType} = model_privacy:get_privacy_type(Uid),

    #{
        active_type => PrivacyType,
        only_list => format_privacy_list(OnlyList),
        except_list => format_privacy_list(ExceptList),
        blocked_list => format_privacy_list(BlockedList),
        mute_list => format_privacy_list(MuteList),
        only_phones_list => format_privacy_list2(OnlyPhonesList),
        except_phones_list => format_privacy_list2(ExceptPhonesList),
        blocked_phones_list => format_privacy_list2(BlockedPhonesList),
        mute_phones_list => format_privacy_list2(MutePhonesList)
    }.

format_privacy_list(Uids) ->
    Phones = model_accounts:get_phones(Uids),
    lists:map(
        fun
            ({Uid, undefined}) ->
                #{uid => Uid, phone => undefined};
            ({Uid, Phone}) ->
                #{uid => Uid, phone => mod_libphonenumber:prepend_plus(Phone)}
        end,
        lists:zip(Uids, Phones)).

format_privacy_list2(Phones) ->
    lists:map(
        fun (Phone) ->
                #{phone => mod_libphonenumber:prepend_plus(Phone)}
        end, Phones).

