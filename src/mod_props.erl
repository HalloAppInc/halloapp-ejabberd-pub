%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_props).
-author("josh").
-behaviour(gen_mod).

-include("ha_types.hrl").
-include("logger.hrl").
-include("props.hrl").
-include("packets.hrl").
-include("groups.hrl").
-include("time.hrl").

-define(INVITE_STRINGS_FILE, "invite_strings.json").

-ifdef(TEST).
-export([
    generate_hash/1,
    make_response/3    
]).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process_local_iq/2]).

%% API
-export([
    get_hash/2,
    get_props/2    %% debug only
]).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_props, ?MODULE, process_local_iq, 2),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_props),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% IQ handler
%%====================================================================

process_local_iq(#pb_iq{from_uid = Uid, type = get} = IQ,
        #{client_version := ClientVersion} = _C2SState) ->
    IsDev = dev_users:is_dev_uid(Uid),
    {Hash, SortedProplist} = get_props_and_hash(Uid, ClientVersion),
    ?INFO("Uid:~s (dev = ~s) requesting props. hash = ~s, proplist = ~p",
        [Uid, IsDev, Hash, SortedProplist]),
    make_response(IQ, SortedProplist, Hash).

%%====================================================================
%% API
%%====================================================================

-spec get_hash(Uid :: binary(), ClientVersion :: binary()) -> binary().
get_hash(Uid, ClientVersion) ->
    try
        {Hash, _} = get_props_and_hash(Uid, ClientVersion),
        Hash
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            ?INFO("Unable to fetch props hash Uid: ~s ClientVersion: ~p", [Uid, ClientVersion]),
            <<>>
    end.


-spec get_props(Uid :: binary(), ClientVersion :: binary()) -> proplist().
get_props(Uid, ClientVersion) ->
    PropMap1 = #{
        dev => false, %% whether the client is dev or not.
        contact_sync_frequency => 1 * ?DAYS, %% how often should clients sync all contacts.
        max_group_size => ?MAX_GROUP_SIZE, %% max limit on the group size.
        max_post_media_items => 10, %% max number of media_items client can post.
        max_chat_media_items => 30, %% max number of media_items client can share in a chat message.
        group_chat => false, %% whether the client can access group_chat or not.
        max_feed_video_duration => 600, %% duration in seconds for videos on feed.
        max_chat_video_duration => 600, %% duration in seconds for videos in chats.
        private_reactions => false, %% whether client can send private reactions.
        group_sync_time => 1 * ?WEEKS, %% how often should clients sync group metadata
        max_video_bit_rate => 4000000, %% max_video_bit_rate set to 4Mbps.
        audio_note_bit_rate => 96000, %% audio_note_bit_rate set to 96Kbps.
        voice_notes => false, %% enables voice notes in 1-1 messages on client.
        media_comments => true,  %% enables media comments.
        cleartext_group_feed => true, %% whether client must send unencrypted content in group_feed.
        use_cleartext_group_feed => true, %% whether clients must rely on unencrypted content in group_feed.
        cleartext_home_feed => true, %% whether client must send unencrypted content in home_feed.
        use_cleartext_home_feed => true, %% whether clients must rely on unencrypted content in home_feed.
        audio_calls => true, %% whether clients can make audio calls.
        video_calls => true, %% whether clients can make video calls.
        call_wait_timeout => 60, %% time (sec) to wait before ending the call on timeout when remote party is not responding.
        streaming_upload_chunk_size =>  65536, %% size of media streaming upload chunk size, 64KB.
        streaming_initial_download_size => 5242880, %% size of intial download while media streaming, 5MB.
        streaming_sending_enabled => false, %% whether streaming is enabled.
        flat_comments => true, %% whether clients display a flat comment structure similar to chat.
        voice_posts => true, %% whether to enable voice posts.
        emoji_version => 2, %% emoji version for clients to use.
        call_hold => false, %% allow calls to be on hold
        call_rerequest => false, %% controls if clients will respond to call-rerequests and also wait for them
        external_sharing => false, %% enables external sharing on clients
        group_max_for_showing_invite_sheet => 5, %% max members to show the invite link after group flow.
        draw_media => false,
        privacy_label => false,
        krisp_noise_suppression => false,
        group_comments_notification => true, %% notifications for group comments by friends on group posts.
        home_feed_comment_notifications => false, %% notifications for home feed comments by friends.
        nse_runtime_sec => 17, %% ios-nse needs 3 secs to cleanup, we want our nse to run =< 20 secs.
        moments => true,   %% clients are capable of sending moments.
        file_sharing => false,   %% clients are capable of sending files.
        invite_strings => get_invite_strings_bin(), %% json string with invite text.
        new_chat_ui => false,   %% turn on new chat ui on ios.
        is_psa_admin => false, %% is client allowed to post PSA Moment
        group_expiry => false, %% whether group expiry option is turned on for clients.
        default_krisp_noise_suppression => false,  %% Should client use noise suppression by default
        enable_sentry_perf_tracking => false, %% Enable Sentry perf tracking on iOS clients
        enable_groups_grid => false %% enables the new group grid experience on iOS clients
    },
    PropMap2 = get_uid_based_props(PropMap1, Uid),
    ClientType = util_ua:get_client_type(ClientVersion),
    PropMap3 = get_client_based_props(PropMap2, ClientType, ClientVersion),
    Proplist = maps:to_list(PropMap3),
    lists:keysort(1, Proplist).


-spec get_uid_based_props(PropMap :: map(), Uid :: binary()) -> map().
get_uid_based_props(PropMap, Uid) ->
    ResPropMap = case dev_users:is_dev_uid(Uid) of
        false ->
            PropMap;
        true ->
            % Set dev to be true.
            PropMap1 = maps:update(dev, true, PropMap),
            PropMap2 = maps:update(streaming_sending_enabled, true, PropMap1),
            PropMap3 = maps:update(call_hold, true, PropMap2),
            PropMap4 = maps:update(external_sharing, true, PropMap3),
            PropMap5 = maps:update(draw_media, true, PropMap4),
            PropMap6 = maps:update(privacy_label, true, PropMap5),
            PropMap7 = maps:update(krisp_noise_suppression, true, PropMap6),
            PropMap8 = maps:update(home_feed_comment_notifications, false, PropMap7),
            PropMap9 = maps:update(file_sharing, true, PropMap8),
            PropMap10 = maps:update(use_cleartext_group_feed, false, PropMap9),
            PropMap11 = maps:update(new_chat_ui, true, PropMap10),
            PropMap12 = maps:update(default_krisp_noise_suppression, true, PropMap11),
            PropMap13 = maps:update(enable_sentry_perf_tracking, true, PropMap12),
            PropMap14 = maps:update(group_expiry, true, PropMap13),
            PropMap15 = maps:update(enable_groups_grid, true, PropMap14),
            PropMap15
    end,
    apply_uid_prop_overrides(Uid, ResPropMap).


-spec get_client_based_props(PropMap :: map(),
        ClientType :: atom(), ClientVersion :: binary()) -> map().
get_client_based_props(PropMap, android, ClientVersion) ->
    %% All android versions starting v0.197
    Result1 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android0.196">>),
    PropMap1 = maps:update(voice_notes, Result1, PropMap),
    Result2 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android1.4">>),
    PropMap2 = maps:update(voice_posts, Result2, PropMap1),
    Result3 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android1.31">>),
    PropMap3 = maps:update(external_sharing, Result3, PropMap2),
    PropMap3;

get_client_based_props(PropMap, ios, ClientVersion) ->
    %% All ios versions starting v1.10.167
    Result = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.10.166">>),
    PropMap1 = maps:update(voice_notes, Result, PropMap),
    Result2 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.16.237">>),
    PropMap2 = maps:update(external_sharing, Result2, PropMap1),
    PropMap2;

get_client_based_props(PropMap, undefined, _) ->
    maps:update(groups, false, PropMap).

%%====================================================================
%% Internal functions
%%====================================================================

apply_uid_prop_overrides(Uid, PropMap) ->
    maps:map(
        fun (K, V) ->
            case uid_prop_override(Uid, K) of
                undef -> V;
                NewV -> NewV
            end
        end,
        PropMap).

-spec uid_prop_override(Uid :: uid(), Prop :: atom()) -> undef | term().
uid_prop_override(<<"1000000000490675850">>, use_cleartext_group_feed) -> false;  %% Murali (groupe2e)
uid_prop_override(<<"1000000000212763494">>, use_cleartext_group_feed) -> false;  %% Murali (groupe2e)
uid_prop_override(Uid, krisp_noise_suppression) ->
    is_krisp_on(Uid);
uid_prop_override(Uid, is_psa_admin) ->
    dev_users:is_psa_admin(Uid);
uid_prop_override(Uid, default_krisp_noise_suppression) ->
    is_krisp_on(Uid);
uid_prop_override(_Uid, _Prop) ->
    undef.

is_krisp_on(Uid) ->
    case is_krisp_on_uid(Uid) of
        true -> true;
        false -> is_krisp_on_for_contact(Uid)
    end.

is_krisp_on_uid(Uid) ->
    case gb_sets:is_element(Uid, reach_out_users()) of
        true -> true;
        false -> is_uid_in_half_set(Uid)
    end.

is_uid_in_half_set(Uid) ->
    crc16_redis:crc16(util:to_list(Uid)) rem 2 =:= 0.

is_krisp_on_for_contact(Uid) ->
    {ok, Phone} = model_accounts:get_phone(Uid),
    {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
    case is_krisp_on_for_contact_list(ContactUids) of
        true -> true;
        false -> undef  %% Don't override the noise suppression prop
    end.

is_krisp_on_for_contact_list([Uid|T]) ->
    case is_krisp_on(Uid) of
        true -> true;
        false -> is_krisp_on_for_contact_list(T)
    end;
is_krisp_on_for_contact_list([]) -> false.


%% English speaking android users that have received calls from >= 2 unique users
%% total call time >= 30 seconds.
reach_out_users() ->
    gb_sets:from_list([
        <<"1000000000986912824">>,
        <<"1000000000595131504">>,
        <<"1000000000185937915">>,
        <<"1000000000679891282">>,
        <<"1000000000523926349">>,
        <<"1000000000305288240">>,
        <<"1000000000318973506">>,
        <<"1000000000893731049">>,
        <<"1000000000470767888">>,
        <<"1000000000394730720">>,   %% Above users were picked from the logs.
        <<"1000000000244386007">>,   %% Babken
        <<"1000000000391903431">>,   %% Tigran
        <<"1000000000608373702">>,   %% Grigor
        <<"1000000000470441450">>,
        <<"1000000000319812640">>,
        <<"1000000000501355953">>,
        <<"1000000000073703946">>,
        <<"1000000000986912824">>,
        <<"1000000000732601709">>,
        <<"1000000000422123879">>,
        <<"1000000000589160898">>,
        <<"1000000000679891282">>,
        <<"1000000000842553635">>,
        <<"1000000000305288240">>,
        <<"1000000000871871514">>,
        <<"1000000000272974927">>,
        <<"1000000000257241282">>,
        <<"1000000000595131504">>,
        <<"1000000000325261047">>,
        <<"1000000000384709179">>,
        <<"1000000000342507776">>,
        <<"1000000000080345706">>,
        <<"1000000000913082664">>,
        <<"1000000000489569557">>,
        <<"1000000000338599889">>,
        <<"1000000000956772891">>,
        <<"1000000000109841048">>,
        <<"1000000000977167116">>,
        <<"1000000000545035268">>,
        <<"1000000000394730720">>,
        <<"1000000000228055381">>,
        <<"1000000000523138805">>,
        <<"1000000000470767888">>,
        <<"1000000000637854529">>,
        <<"1000000000399778754">>,
        <<"1000000000976734425">>,
        <<"1000000000615158513">>
    ]).

generate_hash(SortedProplist) ->
    Json = jsx:encode(SortedProplist),
    <<HashValue:?PROPS_SHA_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, Json),
    HashValue.


get_props_and_hash(Uid, ClientVersion) ->
    SortedProplist = get_props(Uid, ClientVersion),
    Hash = generate_hash(SortedProplist),
    {Hash, SortedProplist}.


make_response(IQ, SortedProplist, Hash) ->
    Props = [#pb_prop{name = util:to_binary(Key), value = util:to_binary(Val)} ||
            {Key, Val} <- SortedProplist],
    Prop = #pb_props{hash = Hash, props = Props},
    pb:make_iq_result(IQ, Prop).


get_invite_strings_bin() ->
    try
        Filename = filename:join(misc:data_dir(), ?INVITE_STRINGS_FILE),
        {ok, Bin} = file:read_file(Filename),
        InviteStringsMap = jiffy:decode(Bin, [return_maps]),
        %% en localization strings dont appear with other languages in ios repo for some reason.
        %% TODO: need to fix this in the ios repo.
        InviteStringsMap1 = InviteStringsMap#{
            <<"en">> => <<"I’m inviting you to join me on HalloApp. It is a private and secure app to share pictures, chat and call your friends. Get it at https://halloapp.com/get"/utf8>>
        },
        jiffy:encode(InviteStringsMap1)
    catch
        Class: Reason: Stacktrace  ->
            ?ERROR("Failed to get invite strings", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            <<>>
    end.

