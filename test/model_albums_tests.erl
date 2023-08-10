%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(model_albums_tests).
-author("josh").

-include("albums.hrl").
-include("server.hrl").
-include_lib("tutil.hrl").

-define(ALBUM_NAME, <<"test name">>).

setup() ->
    tutil:setup([
        {redis, [redis_accounts, redis_feed]}
    ]).


media_items_setup(Num) ->
    CleanupInfo = setup(),
    AlbumId = util_id:generate_album_id(),
    TestData = lists:map(
        fun(N) ->
            Uid = tutil:generate_uid(),
            Name = <<"Name ", N/integer>>,
            Username = <<"uname", N/integer>>,
            model_accounts:create_account(Uid, <<"1450555000", N/integer>>, <<"HalloApp/iOS1.0">>),
            model_accounts:set_name(Uid, Name),
            model_accounts:set_username(Uid, Username),
            MediaItemId = util_id:new_long_id(),
            MediaItem = #pb_media_item{
                id = MediaItemId,
                publisher_uid = Uid,
                album_id = AlbumId,
                payload = <<"payload ", N/integer>>,
                device_capture_timestamp_ms = 1691008930 + N,
                upload_timestamp_ms = 1691015090 + N
            },
            ResultMediaItem = MediaItem#pb_media_item{
                publisher_name = Name,
                publisher_username = Username
            },
            {MediaItem, ResultMediaItem}
        end,
        lists:seq(1, Num)),
    maps:put(test_data, TestData, CleanupInfo).


create_simple_album(OwnerUid) ->
    model_albums:create_album(OwnerUid, album_wrapper(#pb_album{name = <<"Album Name">>, can_view = everyone, can_contribute = everyone})).


%% When an album is converted from a pb, some fields (like time_range) are
%% expanded for easier processing later. Since these tests skip this processing
%% as it's done in mod_albums, we replicate it here.
album_wrapper(Album) ->
    mod_albums:album_pb_to_record(Album).


create_album_and_getters_testset(_) ->
    BadAlbumId = <<"bad-id">>,
    CreatorUid = tutil:generate_uid(),
    SimpleInputAlbum = album_wrapper(#pb_album{
        name = ?ALBUM_NAME,
        can_view = everyone,
        can_contribute = everyone
    }),
    SimpleAlbumId = model_albums:create_album(CreatorUid, SimpleInputAlbum),
    SimpleAlbumExpectedResult = SimpleInputAlbum#album{
        id = SimpleAlbumId,
        owner = CreatorUid,
        members = [#album_member{
            uid = CreatorUid,
            role = owner,
            pending = false
        }]
    },
    MUid1 = tutil:generate_uid(),
    MUid2 = tutil:generate_uid(),
    MUid3 = tutil:generate_uid(),
    StartTs = 1691008938,
    EndTs = 1691015091,
    Offset = -86400,
    Lat = 37.428611,
    Long = -122.143278,
    ComplexInputAlbum = album_wrapper(#pb_album{
        name = ?ALBUM_NAME,
        time_range = #pb_time_range{
            start_timestamp = StartTs,
            end_timestamp = EndTs,
            utc_offset = Offset
        },
        location = #pb_gps_location{
            latitude = Lat,
            longitude = Long
        },
        can_view = invite_only,
        can_contribute = invite_only,
        members = [
            #pb_album_member{uid = MUid1, role = admin, pending = true},
            #pb_album_member{uid = MUid2, role = contributor, pending = true},
            #pb_album_member{uid = MUid3, role = viewer, pending = true}
        ]
    }),
    ComplexAlbumId = model_albums:create_album(CreatorUid, ComplexInputAlbum),
    ComplexAlbumExpectedResult = #album{
        id = ComplexAlbumId,
        name = ?ALBUM_NAME,
        owner = CreatorUid,
        time_range = {StartTs, EndTs, Offset},
        location = {Lat, Long},
        can_view = invite_only,
        can_contribute = invite_only,
        members = [
            #album_member{uid = CreatorUid, role = owner, pending = false},
            #album_member{uid = MUid1, role = admin, pending = true},
            #album_member{uid = MUid2, role = contributor, pending = true},
            #album_member{uid = MUid3, role = viewer, pending = true}
        ]
    },
    [
        %% BadAlbumId – doesn't exist
        ?_assertEqual(undefined, model_albums:get_album(BadAlbumId)),
        ?_assertEqual(bad_album_id, model_albums:get_name(BadAlbumId)),
        ?_assertEqual({undefined, undefined}, model_albums:get_location(BadAlbumId)),
        ?_assertEqual({undefined, undefined, undefined}, model_albums:get_time_range(BadAlbumId)),
        ?_assertEqual(bad_album_id, model_albums:get_contribute_access(BadAlbumId)),
        ?_assertEqual(bad_album_id, model_albums:get_view_access(BadAlbumId)),
        %% SimpleAlbumId – only mandatory fields filled
        ?_assertEqual(SimpleAlbumExpectedResult, model_albums:get_album(SimpleAlbumId)),
        ?_assertEqual(?ALBUM_NAME, model_albums:get_name(SimpleAlbumId)),
        ?_assertEqual({undefined, undefined}, model_albums:get_location(SimpleAlbumId)),
        ?_assertEqual({undefined, undefined, undefined}, model_albums:get_time_range(SimpleAlbumId)),
        ?_assertEqual(everyone, model_albums:get_contribute_access(SimpleAlbumId)),
        ?_assertEqual(everyone, model_albums:get_view_access(SimpleAlbumId)),
        ?_assertOk(model_albums:delete_album(SimpleAlbumId)),
        ?_assertEqual(undefined, model_albums:get_album(SimpleAlbumId)),
        %% ComplexAlbumId – all fields filled
        ?_assertEqual(ComplexAlbumExpectedResult, model_albums:get_album(ComplexAlbumId)),
        ?_assertEqual(?ALBUM_NAME, model_albums:get_name(ComplexAlbumId)),
        ?_assertEqual({Lat, Long}, model_albums:get_location(ComplexAlbumId)),
        ?_assertEqual({StartTs, EndTs, Offset}, model_albums:get_time_range(ComplexAlbumId)),
        ?_assertEqual(invite_only, model_albums:get_contribute_access(ComplexAlbumId)),
        ?_assertEqual(invite_only, model_albums:get_view_access(ComplexAlbumId)),
        ?_assertOk(model_albums:delete_album(ComplexAlbumId)),
        ?_assertEqual(undefined, model_albums:get_album(ComplexAlbumId))
    ].


get_user_albums_testset(_) ->
    Uid1 = tutil:generate_uid(),
    Uid2 = tutil:generate_uid(),
    Uid3 = tutil:generate_uid(),
    AlbumId1 = create_simple_album(Uid1),
    AlbumId2 = create_simple_album(Uid2),
    AlbumId3 = create_simple_album(Uid3),
    [
        ?_assertEqual([AlbumId1], model_albums:get_user_albums(Uid1, all)),
        ?_assertEqual([AlbumId2], model_albums:get_user_albums(Uid2, all)),
        ?_assertEqual([AlbumId3], model_albums:get_user_albums(Uid3, all)),
        ?_assertOk(model_albums:set_role(AlbumId1, Uid2, {viewer, true})),
        ?_assertEqual(lists:sort([AlbumId2, AlbumId1]), lists:sort(model_albums:get_user_albums(Uid2, all))),
        ?_assertEqual([AlbumId2], model_albums:get_user_albums(Uid2, member)),
        ?_assertEqual([AlbumId1], model_albums:get_user_albums(Uid2, invited)),
        ?_assertOk(model_albums:set_role(AlbumId3, Uid2, {contributor, false})),
        ?_assertEqual(lists:sort([AlbumId2, AlbumId1, AlbumId3]), lists:sort(model_albums:get_user_albums(Uid2, all))),
        ?_assertEqual(lists:sort([AlbumId2, AlbumId3]), lists:sort(model_albums:get_user_albums(Uid2, member))),
        ?_assertEqual([AlbumId1], model_albums:get_user_albums(Uid2, invited)),
        ?_assertOk(model_albums:remove_role(AlbumId1, Uid2)),
        ?_assertEqual(lists:sort([AlbumId2, AlbumId3]), lists:sort(model_albums:get_user_albums(Uid2, all))),
        ?_assertEqual(lists:sort([AlbumId2, AlbumId3]), lists:sort(model_albums:get_user_albums(Uid2, member))),
        ?_assertEqual([], model_albums:get_user_albums(Uid2, invited)),
        ?_assertOk(model_albums:remove_role(AlbumId3, Uid2)),
        ?_assertEqual([AlbumId1], model_albums:get_user_albums(Uid1, all)),
        ?_assertEqual([AlbumId2], model_albums:get_user_albums(Uid2, all)),
        ?_assertEqual([AlbumId3], model_albums:get_user_albums(Uid3, all)),
        ?_assertEqual([AlbumId2], lists:sort(model_albums:get_user_albums(Uid2, member))),
        ?_assertOk(model_albums:delete_album(AlbumId1)),
        ?_assertEqual([], model_albums:get_user_albums(Uid1, all)),
        ?_assertEqual([AlbumId2], model_albums:get_user_albums(Uid2, all)),
        ?_assertEqual([AlbumId3], model_albums:get_user_albums(Uid3, all))
    ].


media_items_test_() ->
    tutil:setup_once(
        fun() -> media_items_setup(5) end,
        fun test_store_and_get_and_remove_media_items/1
    ).


test_store_and_get_and_remove_media_items(#{test_data := [{M1, RM1}, _, _, _, {_M5, RM5}] = TestData}) ->
    AlbumId = M1#pb_media_item.album_id,
    MediaItems = lists:map(fun({M, _}) -> M end, TestData),
    [MId1 | MRest] = lists:map(fun(#pb_media_item{id = Id}) -> Id end, MediaItems),
    [MId2, MId3, MId4, _MId5] = MRest,
    [RM1 | RMRest] = lists:map(fun({_, RM}) -> RM end, TestData),
    model_albums:store_media_items(AlbumId, MediaItems),
    [
        %% Test get_media_items
        ?_assertEqual([RM1], model_albums:get_media_items(AlbumId, [MId1])),
        ?_assertEqual(RMRest, model_albums:get_media_items(AlbumId, MRest)),
        %% Test remove_media_items
        ?_assertOk(model_albums:remove_media_items(AlbumId, RM1#pb_media_item.publisher_uid, [MId2, MId3, MId4])),
        ?_assertEqual([RM1, undefined, undefined, undefined, RM5], model_albums:get_media_items(AlbumId, [MId1 | MRest]))
    ].


execute_member_action_testset(_) ->
    OwnerUid = tutil:generate_uid(),
    TmpAdminUid = tutil:generate_uid(),
    TmpContributorUid = tutil:generate_uid(),
    ViewerUid = tutil:generate_uid(),
    AlbumId = create_simple_album(OwnerUid),
    ActionSet1 = [{set, TmpAdminUid, admin, false}, {set, ViewerUid, viewer, true}],
    TmpAdminMediaItems = [
        #pb_media_item{id = util_id:new_long_id(), publisher_uid = TmpAdminUid, album_id = AlbumId, payload = <<"p1">>, device_capture_timestamp_ms = 10, upload_timestamp_ms = 100},
        #pb_media_item{id = util_id:new_long_id(), publisher_uid = TmpAdminUid, album_id = AlbumId, payload = <<"p2">>, device_capture_timestamp_ms = 20, upload_timestamp_ms = 200}
    ],
    TmpContributorMediaItems = [
        #pb_media_item{id = util_id:new_long_id(), publisher_uid = TmpContributorUid, album_id = AlbumId, payload = <<"p3">>, device_capture_timestamp_ms = 30, upload_timestamp_ms = 300},
        #pb_media_item{id = util_id:new_long_id(), publisher_uid = TmpContributorUid, album_id = AlbumId, payload = <<"p4">>, device_capture_timestamp_ms = 40, upload_timestamp_ms = 400}
    ],
    ActionSet2 = [{remove, TmpAdminUid, false}, {set, TmpContributorUid, contributor, false}],
    ActionSet3 = [{remove, TmpContributorUid, true}],
    [
        ?_assertEqual({none, false}, model_albums:get_role(AlbumId, TmpAdminUid)),
        ?_assertEqual({none, false}, model_albums:get_role(AlbumId, ViewerUid)),
        ?_assertEqual({none, false}, model_albums:get_role(AlbumId, TmpContributorUid)),
        ?_assertOk(model_albums:execute_member_actions(AlbumId, ActionSet1)),
        ?_assertEqual({admin, false}, model_albums:get_role(AlbumId, TmpAdminUid)),
        ?_assertEqual({viewer, true}, model_albums:get_role(AlbumId, ViewerUid)),
        ?_assertEqual({none, false}, model_albums:get_role(AlbumId, TmpContributorUid)),
        ?_assertOk(model_albums:store_media_items(AlbumId, TmpAdminMediaItems)),
        ?_assertEqual(#album{id = AlbumId, media_items = TmpAdminMediaItems}, model_albums:get_album_media_items(AlbumId, <<>>)),
        ?_assertOk(model_albums:execute_member_actions(AlbumId, ActionSet2)),
        ?_assertEqual({none, false}, model_albums:get_role(AlbumId, TmpAdminUid)),
        ?_assertEqual({viewer, true}, model_albums:get_role(AlbumId, ViewerUid)),
        ?_assertEqual({contributor, false}, model_albums:get_role(AlbumId, TmpContributorUid)),
        ?_assertOk(model_albums:store_media_items(AlbumId, TmpContributorMediaItems)),
        ?_assertEqual(#album{id = AlbumId, media_items = TmpAdminMediaItems ++ TmpContributorMediaItems},
            model_albums:get_album_media_items(AlbumId, <<>>)),
        ?_assertOk(model_albums:execute_member_actions(AlbumId, ActionSet3)),
        ?_assertEqual({none, false}, model_albums:get_role(AlbumId, TmpAdminUid)),
        ?_assertEqual({viewer, true}, model_albums:get_role(AlbumId, ViewerUid)),
        ?_assertEqual({none, false}, model_albums:get_role(AlbumId, TmpContributorUid)),
        ?_assertEqual(#album{id = AlbumId, media_items = TmpAdminMediaItems}, model_albums:get_album_media_items(AlbumId, <<>>))
    ].

