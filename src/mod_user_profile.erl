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
-include("feed.hrl").
-include("account.hrl").
-include("packets.hrl").
-include("password.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    process_local_iq/1,
    account_name_updated/2,
    user_avatar_published/3,
    username_updated/3,
    broadcast_profile_update/1,
    compose_user_profile_result/2
]).

-define(MAX_BIO_LENGTH, 150).
-define(VALID_LINK_TYPES, [user_defined, tiktok, snapchat, instagram]).

%%====================================================================
%% gen_mod API
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_set_bio_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_set_link_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_user_profile_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_archive_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_geo_tag_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_register_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_halloapp_profile_request, ?MODULE, process_local_iq),
    ejabberd_hooks:add(account_name_updated, katchup, ?MODULE, account_name_updated, 50),
    ejabberd_hooks:add(user_avatar_published, katchup, ?MODULE, user_avatar_published, 50),
    ejabberd_hooks:add(username_updated, katchup, ?MODULE, username_updated, 50),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_set_bio_request),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_set_link_request),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_user_profile_request),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_archive_request),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_geo_tag_request),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_register_request),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_halloapp_profile_request),
    ejabberd_hooks:delete(account_name_updated, katchup, ?MODULE, account_name_updated, 50),
    ejabberd_hooks:delete(user_avatar_published, katchup, ?MODULE, user_avatar_published, 50),
    ejabberd_hooks:delete(username_updated, katchup, ?MODULE, username_updated, 50),
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

%% SetBioRequest
process_local_iq(#pb_iq{type = set, from_uid = Uid, payload = #pb_set_bio_request{text = undefined}} = Iq) ->
    ok = model_accounts:set_bio(Uid, <<>>),
    pb:make_iq_result(Iq, #pb_set_bio_result{result = ok});

process_local_iq(#pb_iq{type = set, from_uid = Uid, payload = #pb_set_bio_request{text = Text}} = Iq) ->
    Ret = case string:length(Text) > ?MAX_BIO_LENGTH of
        true ->
            #pb_set_bio_result{
                result = fail,
                reason = too_long
            };
        false ->
            ok = model_accounts:set_bio(Uid, Text),
            #pb_set_bio_result{result = ok}
    end,
    pb:make_iq_result(Iq, Ret);


%% SetLinkRequest
process_local_iq(#pb_iq{type = set, from_uid = Uid,
        payload = #pb_set_link_request{link = #pb_link{type = BinType, text = Text}}} = Iq) ->
    Type = util:to_atom(BinType),
    Ret = case lists:member(Type, ?VALID_LINK_TYPES) of
        true ->
            LinkMap = model_accounts:get_links(Uid),
            case Text of
                undefined ->
                    ok = model_accounts:set_links(Uid, LinkMap#{Type => <<>>});
                _ ->
                    ok = model_accounts:set_links(Uid, LinkMap#{Type => Text})
            end,
            #pb_set_link_result{result = ok};
        false ->
            #pb_set_link_result{result = fail, reason = bad_type}
    end,
    pb:make_iq_result(Iq, Ret);


%% UserProfileRequest for uid
process_local_iq(#pb_iq{type = get, from_uid = Uid,
        payload = #pb_user_profile_request{uid = Ouid}} = Iq) when Ouid =/= undefined andalso Ouid =/= <<>> ->
    process_user_profile_request(Uid, Ouid, Iq);

%% UserProfileRequest for username
process_local_iq(#pb_iq{type = get, from_uid = Uid,
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
    pb:make_iq_result(Iq, Ret);

%% UserProfileRequest for uid
process_local_iq(#pb_iq{type = get, from_uid = Uid,
        payload = #pb_archive_request{uid = Ouid}} = Iq) when Ouid =/= undefined andalso Ouid =/= <<>> ->
    process_user_archive_request(Uid, Ouid, Iq);

%% UserProfileRequest (invalid)
process_local_iq(#pb_iq{payload = #pb_archive_request{}} = Iq) ->
    Ret = #pb_archive_result{
        result = fail,
        reason = invalid_user
    },
    pb:make_iq_result(Iq, Ret);


%% UserProfileRequest (invalid)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_geo_tag_request{action = Action, gps_location = GpsLocation, geo_tag = GeoTag}} = Iq) ->
    process_geo_tag_request(Uid, Action, GpsLocation, GeoTag, Iq);


%% RegisterRequest
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_register_request{} = Payload} = Iq) ->
    process_register_request(Uid, Payload, Iq);


%% HalloappProfileRequest for uid
process_local_iq(#pb_iq{type = get, from_uid = Uid,
        payload = #pb_halloapp_profile_request{uid = Ouid}} = Iq) when Ouid =/= undefined andalso Ouid =/= <<>> ->
    process_halloapp_profile_request(Uid, Ouid, Iq);

%% HalloappProfileRequest for username
process_local_iq(#pb_iq{type = get, from_uid = Uid,
        payload = #pb_halloapp_profile_request{username = Username}} = Iq)
        when Username =/= undefined andalso Username =/= <<>> ->
    {ok, Ouid} = model_accounts:get_username_uid(Username),
    process_halloapp_profile_request(Uid, Ouid, Iq);

%% HalloappProfileRequest (invalid)
process_local_iq(#pb_iq{payload = #pb_halloapp_profile_request{}} = Iq) ->
    Ret = #pb_halloapp_profile_result{
        result = fail,
        reason = unknown_reason
    },
    pb:make_iq_result(Iq, Ret).


%%====================================================================
%% Hooks
%%====================================================================

-spec account_name_updated(Uid :: binary(), Name :: binary()) -> ok.
account_name_updated(Uid, _Name) ->
    ?INFO("Uid: ~p", [Uid]),
    broadcast_profile_update(Uid),
    ok.


-spec user_avatar_published(Uid :: binary(), Server :: binary(), AvatarId :: binary()) -> ok.
user_avatar_published(Uid, _Server, _AvatarId) ->
    ?INFO("Uid: ~p", [Uid]),
    broadcast_profile_update(Uid),
    ok.


-spec username_updated(Uid :: binary(), Username :: binary(), IsFirstTime :: boolean()) -> ok.
username_updated(Uid, _Username, _IsFirstTime) ->
    ?INFO("Uid: ~p", [Uid]),
    broadcast_profile_update(Uid),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

process_user_profile_request(Uid, Ouid, Iq) ->
    Ret = case model_accounts:account_exists(Ouid) andalso not model_follow:is_blocked_any(Uid, Ouid) of
        true -> compose_user_profile_result(Uid, Ouid);
        false ->
            #pb_user_profile_result{
                result = fail,
                reason = no_user
            }
    end,
    pb:make_iq_result(Iq, Ret).


compose_user_profile_result(Uid, Ouid) ->
    UserProfile = model_accounts:get_user_profiles(Uid, Ouid),
    RawRecentPosts = model_feed:get_recent_user_posts(Ouid),
    AccountName = model_accounts:get_name_binary(Ouid),
    AccountUsername = model_accounts:get_username_binary(Ouid),
    RecentPosts = lists:map(
        fun(#post{id = PostId, payload = PayloadBase64, ts_ms = TimestampMs, tag = PostTag, moment_info = MomentInfo} = Post) ->
            #pb_post{
                id = PostId,
                publisher_uid = Ouid,
                publisher_name = AccountName,
                publisher_username = AccountUsername,
                payload = base64:decode(PayloadBase64),
                timestamp = util:ms_to_sec(TimestampMs),
                moment_info = MomentInfo,
                tag = PostTag,
                is_expired = Post#post.expired
            }
        end, RawRecentPosts),
    #pb_user_profile_result{
        result = ok,
        profile = UserProfile,
        recent_posts = RecentPosts
    }.


process_halloapp_profile_request(Uid, Ouid, Iq) ->
    Ret = case model_accounts:account_exists(Ouid) andalso not model_halloapp_friends:is_blocked_any2(Uid, Ouid) of
        true ->
            HalloappUserProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
            #pb_halloapp_profile_result{
                result = ok,
                profile = HalloappUserProfile
            };
        false ->
            #pb_halloapp_profile_result{
                result = fail,
                reason = no_user
            }
    end,
    pb:make_iq_result(Iq, Ret).


process_user_archive_request(Uid, Ouid, Iq) ->
    Ret = case model_accounts:account_exists(Ouid) andalso not model_follow:is_blocked_any(Uid, Ouid) of
        true -> compose_user_archive_result(Uid, Ouid);
        false ->
            #pb_archive_result{
                result = fail,
                reason = invalid_user
            }
    end,
    pb:make_iq_result(Iq, Ret).


compose_user_archive_result(_Uid, Ouid) ->
    {ok, Items} = model_feed:get_entire_user_feed(Ouid),
    {Posts, _Comments} = lists:partition(fun(Item) -> is_record(Item, post) end, Items),
    ArchiveFeedItems = lists:map(fun mod_feed:convert_posts_to_feed_items/1, Posts),
    ArchivePostStanzas = lists:map(fun(FeedItem) -> FeedItem#pb_feed_item.item end, ArchiveFeedItems),
    StartDate = util:time_to_prettydatestring(util:now_ms() - ?POST_TTL_MS),
    #pb_archive_result{
        result = ok,
        uid = Ouid,
        posts = ArchivePostStanzas,
        start_date = StartDate
    }.


process_geo_tag_request(Uid, Action, GpsLocation, UserInputGeoTag, Iq) ->
    CurrentGeoTag = model_accounts:get_latest_geo_tag(Uid),
    {Ret, SendBroadcast} = case Action of
        get ->
            LocationGeoTag = mod_location:get_geo_tag(Uid, GpsLocation),
            ok = model_accounts:add_geo_tag(Uid, LocationGeoTag, util:now()),
            LatestGeoTag = model_accounts:get_latest_geo_tag(Uid),
            GeoTags = case LatestGeoTag of
                undefined -> [];
                _ ->
                    [util:to_binary(LatestGeoTag)]
            end,
            {
                #pb_geo_tag_response{
                    result = ok,
                    geo_tags = GeoTags
                },
                CurrentGeoTag =/= LatestGeoTag
            };
        block ->
            case UserInputGeoTag of
                undefined ->
                    {
                        #pb_geo_tag_response{
                            result = fail,
                            reason = invalid_request
                        },
                        false
                    };
                _ ->
                    ok = model_accounts:block_geo_tag(Uid, UserInputGeoTag),
                    {
                        #pb_geo_tag_response{
                            result = ok
                        },
                        true
                    }
            end;
        force_add ->
            LocationGeoTag = mod_location:get_geo_tag(Uid, GpsLocation, false),
            ok = model_accounts:add_geo_tag(Uid, LocationGeoTag, util:now()),
            LatestGeoTag = model_accounts:get_latest_geo_tag(Uid),
            GeoTags = case LatestGeoTag of
                undefined -> [];
                _ ->
                    [util:to_binary(LatestGeoTag)]
            end,
            {
                #pb_geo_tag_response{
                    result = ok,
                    geo_tags = GeoTags
                },
                CurrentGeoTag =/= LatestGeoTag
            }
    end,
    case SendBroadcast of
        true -> broadcast_profile_update(Uid);
        _ -> ok
    end,
    pb:make_iq_result(Iq, Ret).


%% Broadcasts profile update to followers.
%% TODO: Send this to contactUids who have this number.
-spec broadcast_profile_update(Uid :: binary()) -> ok.
broadcast_profile_update(Uid) ->
    ?INFO("Broadcasting update Uid: ~p", [Uid]),
    Followers = model_follow:get_all_followers(Uid),
    mod_follow:notify_profile_update(Uid, Followers),
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%% Register request
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


process_register_request(Uid, #pb_register_request{request = #pb_hashcash_request{} = HashcashRequest}, Iq) ->
    AppType = util_uid:get_app_type(Uid),
    StatNamespace = util:get_stat_namespace(AppType),
    stat:count(StatNamespace++"/registration", "request_hashcash", 1, [{protocol, "noise"}]),
    CC = HashcashRequest#pb_hashcash_request.country_code,
    %% TODO: Need to add ip in the future, currently it is not used.
    RequestData = #{
        cc => CC,
        ip => <<>>,
        raw_data => HashcashRequest,
        protocol => noise
    },
    {ok, HashcashChallenge} = mod_halloapp_http_api:process_hashcash_request(RequestData),
    stat:count(StatNamespace++"/registration", "request_hashcash_success", 1, [{protocol, "noise"}]),
    HashcashResponse = #pb_hashcash_response{
        hashcash_challenge = HashcashChallenge
    },
    pb:make_iq_result(Iq, #pb_register_response{response = HashcashResponse});

process_register_request(Uid, #pb_register_request{request = #pb_otp_request{} = OtpRequest}, Iq) ->
    AppType = util_uid:get_app_type(Uid),
    StatNamespace = util:get_stat_namespace(AppType),
    stat:count(StatNamespace ++ "/registration", "request_otp_request", 1, [{protocol, "noise"}]),
    RawPhone = OtpRequest#pb_otp_request.phone,
    MethodBin = util:to_binary(OtpRequest#pb_otp_request.method),
    LangId = OtpRequest#pb_otp_request.lang_id,
    GroupInviteToken = OtpRequest#pb_otp_request.group_invite_token,
    UserAgent = OtpRequest#pb_otp_request.user_agent,
    HashcashSolution = OtpRequest#pb_otp_request.hashcash_solution,
    HashcashSolutionTimeTakenMs = OtpRequest#pb_otp_request.hashcash_solution_time_taken_ms,
    CampaignId = OtpRequest#pb_otp_request.campaign_id,
    {ok, SPubRecord} = model_auth:get_spub(Uid),
    RemoteStaticKey = SPubRecord#s_pub.s_pub,
    RequestData = #{raw_phone => RawPhone, lang_id => LangId, ua => UserAgent, method => MethodBin,
        ip => <<>>, group_invite_token => GroupInviteToken, raw_data => OtpRequest,
        protocol => noise, remote_static_key => RemoteStaticKey,
        hashcash_solution => HashcashSolution,
        hashcash_solution_time_taken_ms => HashcashSolutionTimeTakenMs,
        campaign_id => CampaignId
    },
    OtpResponse = case mod_halloapp_http_api:process_otp_request(RequestData) of
        {ok, Phone, RetryAfterSecs, IsPastUndelivered} ->
            stat:count(StatNamespace ++"/registration", "request_otp_success", 1, [{protocol, "noise"}]),
            #pb_otp_response{
                phone = Phone,
                result = success,
                retry_after_secs = RetryAfterSecs,
                should_verify_number = IsPastUndelivered
            };
        {error, retried_too_soon, Phone, RetryAfterSecs} ->
            #pb_otp_response{
                phone = Phone,
                result = failure,
                reason = retried_too_soon,
                retry_after_secs = RetryAfterSecs
            };
        {error, dropped, Phone, RetryAfterSecs} ->
            #pb_otp_response{
                phone = Phone,
                result = success,
                retry_after_secs = RetryAfterSecs
            };
        {error, internal_server_error} ->
            #pb_otp_response{
                result = failure,
                reason = internal_server_error
            };
        {error, ip_blocked} ->
            #pb_otp_response{
                result = failure,
                reason = bad_request
            };
        {error, bad_user_agent} ->
            #pb_otp_response{
                result = failure,
                reason = bad_request
            };
        {error, Reason} ->
            #pb_otp_response{
                result = failure,
                reason = Reason
            }
    end,
    pb:make_iq_result(Iq, #pb_register_response{response = OtpResponse});

process_register_request(Uid, #pb_register_request{request = #pb_verify_otp_request{} = VerifyOtpRequest}, Iq) ->
    RawPhone = VerifyOtpRequest#pb_verify_otp_request.phone,
    Name = VerifyOtpRequest#pb_verify_otp_request.name,
    Code = VerifyOtpRequest#pb_verify_otp_request.code,
    SEdPubB64 = base64:encode(VerifyOtpRequest#pb_verify_otp_request.static_key),
    SignedPhraseB64 = base64:encode(VerifyOtpRequest#pb_verify_otp_request.signed_phrase),
    IdentityKeyB64 = base64:encode(VerifyOtpRequest#pb_verify_otp_request.identity_key),
    SignedKeyB64 = base64:encode(VerifyOtpRequest#pb_verify_otp_request.signed_key),
    OneTimeKeysB64 = lists:map(fun base64:encode/1, VerifyOtpRequest#pb_verify_otp_request.one_time_keys),
    PushPayload = case VerifyOtpRequest#pb_verify_otp_request.push_register of
        undefined -> #{};
        #pb_push_register{push_token = #pb_push_token{} = PbPushToken, lang_id = LangId} ->
            #{
                <<"lang_id">> => LangId,
                <<"push_token">> => PbPushToken#pb_push_token.token,
                <<"push_os">> => PbPushToken#pb_push_token.token_type
            }
    end,
    GroupInviteToken = VerifyOtpRequest#pb_verify_otp_request.group_invite_token,
    UserAgent = VerifyOtpRequest#pb_verify_otp_request.user_agent,
    CampaignId = case VerifyOtpRequest#pb_verify_otp_request.campaign_id of
        undefined -> "undefined";
        [] -> "undefined";
        <<>> -> "undefined";
        SomeList when is_list(SomeList) ->
            case SomeList of
                [] ->
                    ?INFO("Weird campaign_id is empty-list"),
                    "undefined";
                SomethingElse -> SomethingElse
            end;
        SomeBin when is_binary(SomeBin) ->
            case util:to_list(SomeBin) of
                [] ->
                    ?INFO("Weird campaign_id is empty-bin"),
                    "undefined";
                SomethingElse -> SomethingElse
            end;
        _ -> "undefined"
    end,
    HashcashSolution = VerifyOtpRequest#pb_verify_otp_request.hashcash_solution,
    HashcashSolutionTimeTakenMs = VerifyOtpRequest#pb_verify_otp_request.hashcash_solution_time_taken_ms,
    StatNamespace = util:get_stat_namespace(UserAgent),
    stat:count(StatNamespace ++ "/registration", "verify_otp_request", 1, [{protocol, "noise"}]),
    stat:count(StatNamespace ++ "/registration", "verify_otp_request_by_campaign_id", 1, [{campaign_id, CampaignId}]),
    {ok, SPubRecord} = model_auth:get_spub(Uid),
    RemoteStaticKey = SPubRecord#s_pub.s_pub,
    RequestData = #{
        raw_phone => RawPhone, name => Name, ua => UserAgent, code => Code,
        ip => <<>>, group_invite_token => GroupInviteToken, s_ed_pub => SEdPubB64,
        signed_phrase => SignedPhraseB64, id_key => IdentityKeyB64, sd_key => SignedKeyB64,
        otp_keys => OneTimeKeysB64, push_payload => PushPayload, raw_data => VerifyOtpRequest,
        protocol => noise, remote_static_key => RemoteStaticKey,
        campaign_id => CampaignId,
        hashcash_solution => HashcashSolution,
        hashcash_solution_time_taken_ms => HashcashSolutionTimeTakenMs,
        client_uid => VerifyOtpRequest#pb_verify_otp_request.uid
    },
    VerifyOtpResponse = case mod_halloapp_http_api:process_register_request(RequestData) of
        {ok, Result} ->
            stat:count(util:get_stat_namespace(UserAgent) ++ "/registration",
                "verify_otp_success", 1, [{protocol, "noise"}]),
            #pb_verify_otp_response{
                uid = maps:get(uid, Result),
                phone = maps:get(phone, Result),
                name = maps:get(name, Result),
                username = maps:get(username, Result),
                result = success,
                group_invite_result = util:to_binary(maps:get(group_invite_result, Result, ''))
            };
        {error, internal_server_error} ->
            #pb_verify_otp_response{
                result = failure,
                reason = internal_server_error
            };
        {error, bad_user_agent} ->
            #pb_verify_otp_response{
                result = failure,
                reason = bad_request
            };
        {error, Reason} ->
            #pb_verify_otp_response{
                result = failure,
                reason = Reason
            }
    end,
    pb:make_iq_result(Iq, #pb_register_response{response = VerifyOtpResponse});

process_register_request(Uid, _, Iq) ->
    ?ERROR("Invalid packet received, Uid: ~p Iq: ~p", [Uid, Iq]),
    pb:make_error(Iq, util:err(invalid_packet)).


