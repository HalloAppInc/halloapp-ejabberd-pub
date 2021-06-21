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


%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
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
-define(S3_EXPORT_BUCKET, "halloapp-export").
-define(AVATAR_CDN, "https://avatar-cdn.halloapp.net/").


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_export_data, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_export_data),
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

process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_export_data{}} = IQ) ->
    ?INFO("Uid: ~s, export iq", [Uid]),
    case model_accounts:get_export(Uid) of
        {ok, StartTs, ExportId} ->
            case StartTs + ?EXPORT_WAIT < util:now() of
                true ->
                    Payload = IQ#pb_iq.payload#pb_export_data{
                        status = ready,
                        data_url = get_url(ExportId)},
                    pb:make_iq_result(IQ, Payload);
                false ->
                    Payload = IQ#pb_iq.payload#pb_export_data{
                        data_ready_ts = StartTs + ?EXPORT_WAIT,
                        status = pending},
                    pb:make_iq_result(IQ, Payload)
            end;
        {error, missing} ->
            {ok, StartTs} = start_export(Uid),
            Payload = IQ#pb_iq.payload#pb_export_data{
                data_ready_ts = StartTs + ?EXPORT_WAIT,
                status = pending},
            pb:make_iq_result(IQ, Payload)
    end.

-spec export_bucket() -> string().
export_bucket() ->
    ?S3_EXPORT_BUCKET.


%%====================================================================
%% internal functions
%%====================================================================

start_export(Uid) ->
    ExportId = util:random_str(32),
    {ok, Ts} = model_accounts:start_export(Uid, ExportId),
    DataMap = export_data(Uid),
    Data = encode_data(DataMap),
    ok = upload_data(ExportId, Data),
    {ok, Ts}.


-spec export_data(Uid :: uid()) -> ok.
export_data(Uid) ->
    {ok, Acc} = model_accounts:get_account(Uid),

    Account = #{
        user_id => Acc#account.uid,
        phone => Acc#account.phone,
        name  => Acc#account.name,
        created_at_ms => Acc#account.creation_ts_ms,
        signup_device => Acc#account.signup_user_agent,
        client_version => Acc#account.client_version,
        last_activity_ts_ms => Acc#account.last_activity_ts_ms
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

-spec upload_s3(atom(), list(), binary()) -> ok.
upload_s3(prod, ObjectKey, Data) ->
    Result = erlcloud_s3:put_object(
        ?S3_EXPORT_BUCKET, ObjectKey, Data),
    ?INFO("ObjectName: ~s, Result: ~p", [ObjectKey, Result]),
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
    {ok, PrivacyType} = model_privacy:get_privacy_type(Uid),

    #{
        active_type => PrivacyType,
        only_list => OnlyList,
        except_list => ExceptList,
        blocked_list => BlockedList,
        mute_list => MuteList
    }.
