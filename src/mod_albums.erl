%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_albums).
-author("josh").

-include("albums.hrl").
-include("ha_types.hrl").
-include("logger.hrl").
-include("packets.hrl").
-include("time.hrl").

%% for tests
-ifdef(TEST).
-export([
    parse_member_actions/3,
    is_role_higher/2,
    is_role_lower/2,
    album_pb_to_record/1,
    album_record_to_pb/1
]).
-endif.

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    process_local_iq/1
]).

-define(ALBUM_MEMBER_LIMIT, 256).

%%====================================================================
%% gen_mod API
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, ?HALLOAPP, pb_album, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?HALLOAPP, pb_get_albums, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?HALLOAPP, pb_album),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?HALLOAPP, pb_get_albums),
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

%% Create an album
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{action = create, name = Name, time_range = TimeRange,
        can_view = CanView, can_contribute = CanContribute, members = Members} = AlbumPb} = IQ) ->
    %% Some basic error checking:
    %%    * name, can_view, and can_contribute must be specified
    %%    * if time_range is specified, make sure it is valid
    %%    * if members are added, make sure the total number does not exceed the limit
    %%    * creator of album should not be in members list (server always adds them during creation)
    case not lists:member(undefined, [Name, CanView, CanContribute])
            andalso is_time_range_ok(TimeRange)
            andalso length(Members) < ?ALBUM_MEMBER_LIMIT
            andalso not lists:keyfind(Uid, 2, Members) of
        false ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail});
        true ->
            %% Make sure all members have pending = true
            PendingMembers = lists:map(fun(#pb_album_member{} = PbMember) -> PbMember#pb_album_member{pending = true} end, Members),
            AlbumId = model_albums:create_album(Uid, album_pb_to_record(AlbumPb#pb_album{members = PendingMembers})),
            ok = model_albums:store_media_items(AlbumId, AlbumPb#pb_album.media_items),
            case model_albums:get_album(AlbumId) of
                undefined ->
                    pb:make_iq_result(IQ, #pb_album_result{result = fail});
                Album ->
                    PbAlbum = album_record_to_pb(Album),
                    ok = notify(Uid, PbAlbum),
                    ?INFO("Album (~s) created by ~s: ~p", [AlbumId, Uid, PbAlbum]),
                    pb:make_iq_result(IQ, PbAlbum)
            end
    end;

%% Change name
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = change_name, name = NewName} = PbAlbum} = IQ) ->
    %% Requires Uid to be at least a contributor
    case is_role_at_least(get_role(AlbumId, Uid), contributor) of
        false ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed});
        true ->
            ok = model_albums:set_name(AlbumId, NewName),
            ok = notify(Uid, PbAlbum),
            ?INFO("~s changed album (~s) name", [Uid, AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = PbAlbum})
    end;

%% Change location
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = change_location, location = Location} = PbAlbum} = IQ) ->
    %% Requires Uid to be at least a contributor
    case is_role_at_least(get_role(AlbumId, Uid), contributor) of
        false ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed});
        true ->
            ok = model_albums:set_location(AlbumId, location_pb_to_tuple(Location)),
            ok = notify(Uid, PbAlbum),
            ?INFO("~s changed album (~s) location", [Uid, AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = PbAlbum})
    end;

%% Change time range
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = change_time, time_range = TimeRange} = PbAlbum} = IQ) ->
    %% Requires Uid to be at least a contributor
    case is_role_at_least(get_role(AlbumId, Uid), contributor) of
        false ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed});
        true ->
            ok = model_albums:set_time_range(AlbumId, time_range_pb_to_tuple(TimeRange)),
            ok = notify(Uid, PbAlbum),
            ?INFO("~s changed album (~s) time range", [Uid, AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = PbAlbum})
    end;

%% Change view access
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = change_view_access, can_view = CanView} = PbAlbum} = IQ) ->
    %% Requires Uid to be at least an admin
    case is_role_at_least(get_role(AlbumId, Uid), admin) of
        false ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed});
        true ->
            ok = model_albums:set_view_access(AlbumId, CanView),
            ok = notify(Uid, PbAlbum),
            ?INFO("~s changed album (~s) view access", [Uid, AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = PbAlbum})
    end;

%% Change contribute access
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = change_contribute_access, can_contribute = CanContribute} = PbAlbum} = IQ) ->
    %% Requires Uid to be at least an admin AND the new access type to be more or equally as strict as view access
    case is_role_at_least(get_role(AlbumId, Uid), admin) andalso
            not (CanContribute =:= everyone andalso model_albums:get_view_access(AlbumId) =:= invite_only) of
        false ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed});
        true ->
            ok = model_albums:set_contribute_access(AlbumId, CanContribute),
            ok = notify(Uid, PbAlbum),
            ?INFO("~s changed album (~s) contribute access", [Uid, AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = PbAlbum})
    end;

%% Modify members
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = modify_members, members = PbMembers} = PbAlbum} = IQ) ->
    ActionList = parse_member_actions(AlbumId, Uid, PbMembers),
    case lists:member(not_allowed, ActionList) of
        true ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed});
        false ->
            ok = model_albums:execute_member_actions(AlbumId, ActionList),
            ok = notify(Uid, PbAlbum),
            ?INFO("~s modified album (~s) members", [Uid, AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = PbAlbum})
    end;

%% Add media items
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = add_media, media_items = MediaItems} = PbAlbum} = IQ) ->
    %% Uid must be at least a contributor of the album OR the album must have contribute access = everyone
    case {is_role_at_least(get_role(AlbumId, Uid), contributor), model_albums:get_contribute_access(AlbumId), check_media_items(AlbumId, Uid, MediaItems)} of
        {false, invite_only, _} ->
            %% Uid is not a member of the album and the contribute access is invite_only
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed});
        {_, _, false} ->
            %% Problem with one of the media items
            pb:make_iq_result(IQ, #pb_album_result{result = fail});
        {true, _, true} ->
            %% Uid is a contributor
            ok = model_albums:store_media_items(AlbumId, MediaItems),
            ok = notify(Uid, PbAlbum),
            ?INFO("~s added ~B media items to an album (~s)", [Uid, length(MediaItems), AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = PbAlbum});
        {false, everyone, true} ->
            %% Uid is not a contributor, but the contribute access is everyone, so we allow the media items and set Uid as a contributor
            ok = model_albums:set_role(AlbumId, Uid, {contributor, false}),
            ok = notify(Uid, #pb_album{id = AlbumId, action = modify_members, members = #pb_album_member{uid = Uid, action = join}}),
            ok = model_albums:store_media_items(AlbumId, MediaItems),
            ok = notify(Uid, PbAlbum),
            ?INFO("~s added ~B media items to an album (~s) and joined as a contributor", [Uid, length(MediaItems), AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = PbAlbum})
    end;

%% Remove media items
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = remove_media, media_items = MediaItems} = Album} = IQ) ->
    %% Uid must be an admin or the creator of all the media items
    case is_role_at_least(get_role(AlbumId, Uid), admin)
            orelse not lists:any(fun(#pb_media_item{publisher_uid = PUid}) -> PUid =/= Uid end, MediaItems) of
        false ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed});
        true ->
            MediaItemIds = lists:map(fun(#pb_media_item{id = Id}) -> Id end, MediaItems),
            ok = model_albums:remove_media_items(AlbumId, Uid, MediaItemIds),
            ?INFO("~s removed ~B media items from an album (~s)", [Uid, length(MediaItems), AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = Album})
    end;

%% Get album (info only, media items only, or entire thing)
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = Action, cursor = Cursor}} = IQ)
        when Action =:= get orelse Action =:= get_info orelse Action =:= get_media ->
    %% Album view access needs to be set to everyone OR Uid needs to be at least a viewer OR Uid needs to be invited
    {Role, Pending} = model_albums:get_role(AlbumId, Uid),
    case {model_albums:get_view_access(AlbumId), is_role_at_least(Role, viewer), Pending} of
        {bad_album_id, _, _} ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = bad_album_id});
        {invite_only, false, false} ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed});
        _ ->
            AlbumRecord = case Action of
                get -> model_albums:get_album(AlbumId, Cursor);
                get_info -> model_albums:get_album_info(AlbumId);
                get_media -> model_albums:get_album_media_items(AlbumId, Cursor)
            end,
            ?INFO("~s requested an album (~s) with ~s", [Uid, AlbumId, Action]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = album_record_to_pb(AlbumRecord)})
    end;

%% Delete album
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_album{id = AlbumId, action = delete} = PbAlbum} = IQ) ->
    case get_role(AlbumId, Uid) of
        owner ->
            ok = notify(Uid, PbAlbum),
            ok = model_albums:delete_album(AlbumId),
            ?INFO("~s deleted an album (~s)", [Uid, AlbumId]),
            pb:make_iq_result(IQ, #pb_album_result{result = ok, album = PbAlbum});
        _ ->
            pb:make_iq_result(IQ, #pb_album_result{result = fail, reason = not_allowed})
    end;

%% GetAlbums request
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_get_albums{type = Type}} = IQ) ->
    AlbumIds = model_albums:get_user_albums(Uid, Type),
    pb:make_iq_result(IQ, #pb_get_albums{type = Type, album_ids = AlbumIds}).

%%====================================================================
%% Internal functions
%%====================================================================

-spec notify(uid(), pb_album()) -> ok.
notify(FromUid, PbAlbum) ->
    Members = model_albums:get_all_members(PbAlbum#pb_album.id),
    lists:foreach(
        fun
            ({ToUid, _}) when ToUid =/= FromUid ->
                send_msg(FromUid, ToUid, PbAlbum);
            (_) -> ok
        end,
        Members).


%% Parse through intended member actions and return a list of actions to complete
-spec parse_member_actions(album_id(), uid(), list(pb_album_member())) -> member_actions_list().
parse_member_actions(AlbumId, Uid, PbMembers) ->
    {UserRole, UserPending} = model_albums:get_role(AlbumId, Uid),
    UserCurrentRole = case UserPending of
        true -> none;
        false -> UserRole
    end,
    UserIsAtLeastAdmin = is_role_at_least(UserCurrentRole, admin),
    lists:map(
        fun(#pb_album_member{uid = MUid, action = Action, role = MNewRole, remove_media = RemoveMedia}) ->
            %% Processes all valid combinations and outputs {action, uid, role, pending} | {remove, uid, remove_media} | not_allowed
            {MRole, MPending} = model_albums:get_role(AlbumId, MUid),
            MCurrentRole = case MPending of
                true -> none;
                false -> MRole
            end,
            case {Action, Uid, UserPending, MUid} of
                {accept_invite, Uid, true, Uid} -> {set, Uid, UserRole, false};
                {reject_invite, Uid, true, Uid} -> {remove, Uid, false};
                {join, Uid, _, Uid} ->
                    case {model_albums:get_view_access(AlbumId), model_albums:get_contribute_access(AlbumId)} of
                        {invite_only, invite_only} -> not_allowed;
                        {everyone, invite_only} -> {set, Uid, viewer, false};
                        {everyone, everyone} -> {set, Uid, contributor, false}
                    end;
                {leave, Uid, _, Uid} when UserRole =/= owner -> {remove, Uid, RemoveMedia};
                {un_invite, _, false, MUid} when UserIsAtLeastAdmin andalso MPending -> {remove, MUid, false};  %% TODO: make it so Uid can un-invite MUid if they were the one to invite them
                {remove, Uid, false, MUid} when Uid =/= MUid andalso UserIsAtLeastAdmin -> {remove, MUid, false};
                {invite, Uid, false, MUid} when Uid =/= MUid->
                    %% Contributors and above can invite other users at their level or lower (except owner)
                    case is_role_at_least(UserCurrentRole, contributor) andalso is_role_at_most(MNewRole, UserCurrentRole) andalso MNewRole =/= owner of
                        true -> {set, MUid, MNewRole, true};
                        false -> not_allowed
                    end;
                {promote, Uid, false, MUid} when Uid =/= MUid andalso UserIsAtLeastAdmin andalso MNewRole =/= owner ->
                    %% Uid can promote viewers and above to a role at or below themselves (but owner cannot promote to owner)
                    case is_role_at_least(MCurrentRole, viewer) andalso is_role_higher(MNewRole, MCurrentRole) andalso is_role_at_most(MNewRole, UserCurrentRole) andalso MNewRole =/= owner of
                        true -> {set, MUid, MNewRole, false};
                        false -> not_allowed
                    end;
                {demote, Uid, false, MUid} when Uid =/= MUid andalso UserIsAtLeastAdmin andalso MNewRole =/= none ->
                    %% Uid must be a higher role than MUid and the demotion must be valid (new role is lower but not none)
                    case is_role_at_least(UserCurrentRole, MCurrentRole) andalso is_role_higher(MCurrentRole, MNewRole) andalso MNewRole =/= none of
                        true -> {set, MUid, MNewRole, false};
                        false -> not_allowed
                    end;
                _ -> not_allowed
            end
        end,
        PbMembers).


%% Gets role of Uid in an album. If Uid is only invited, this equates to none here
-spec get_role(album_id(), uid()) -> role().
get_role(AlbumId, Uid) ->
    case model_albums:get_role(AlbumId, Uid) of
        {_, true} -> none;
        {Role, false} -> Role
    end.


%% Role1 > Role2 ?
-spec is_role_higher(role(), role()) -> boolean().
is_role_higher(Role1, Role2) ->
    case Role1 of
        owner -> Role2 =/= owner;
        admin -> Role2 =/= owner andalso Role2 =/= admin;
        contributor -> Role2 =:= viewer orelse Role2 =:= none;
        viewer -> Role2 =:= none;
        none -> false
    end.


%% Role1 < Role2 ?
-spec is_role_lower(role(), role()) -> boolean().
is_role_lower(Role1, Role2) ->
    case Role1 of
        owner -> false;
        admin -> Role2 =:= owner;
        contributor -> Role2 =/= viewer andalso Role2 =/= none;
        viewer -> Role2 =/= none;
        none -> Role2 =/= none
    end.


%% Role1 ≥ Role2 ?
-spec is_role_at_least(role(), role()) -> boolean().
is_role_at_least(Role1, Role2) ->
    Role1 =:= Role2 orelse is_role_higher(Role1, Role2).


%% Role1 ≤ Role2 ?
-spec is_role_at_most(role(), role()) -> boolean().
is_role_at_most(Role1, Role2) ->
    Role1 =:= Role2 orelse is_role_lower(Role1, Role2).


-spec location_pb_to_tuple(maybe(pb_gps_location())) -> location().
location_pb_to_tuple(undefined) -> {undefined, undefined};
location_pb_to_tuple(#pb_gps_location{latitude = Lat, longitude = Long}) -> {Lat, Long}.

-spec location_tuple_to_pb(location()) -> maybe(pb_gps_location()).
location_tuple_to_pb({undefined, undefined}) -> undefined;
location_tuple_to_pb({Lat, Long}) -> #pb_gps_location{latitude = Lat, longitude = Long}.


-spec time_range_pb_to_tuple(maybe(pb_time_range())) -> time_range().
time_range_pb_to_tuple(undefined) -> {undefined, undefined, undefined};
time_range_pb_to_tuple(#pb_time_range{start_timestamp = S, end_timestamp = E, utc_offset = O}) ->
    {util:to_integer(S), util:to_integer(E), util:to_integer(O)}.

-spec time_range_tuple_to_pb(time_range()) -> maybe(pb_time_range()).
time_range_tuple_to_pb({undefined, undefined, undefined}) -> undefined;
time_range_tuple_to_pb({S, E, O}) -> #pb_time_range{start_timestamp = S, end_timestamp = E, utc_offset = O}.


-spec album_pb_to_record(pb_album()) -> album().
album_pb_to_record(AlbumPb) ->
    TimeRange = time_range_pb_to_tuple(AlbumPb#pb_album.time_range),
    Location = location_pb_to_tuple(AlbumPb#pb_album.location),
    Members = lists:map(
        fun(#pb_album_member{uid = Uid, role = Role, pending = Pending}) ->
            #album_member{uid = Uid, role = Role, pending = Pending}
        end,
        AlbumPb#pb_album.members),
    #album{
        id = AlbumPb#pb_album.id,
        name = AlbumPb#pb_album.name,
        owner = AlbumPb#pb_album.owner,
        time_range = TimeRange,
        location = Location,
        can_view = AlbumPb#pb_album.can_view,
        can_contribute = AlbumPb#pb_album.can_contribute,
        members = Members,
        media_items = AlbumPb#pb_album.media_items,
        cursor = AlbumPb#pb_album.cursor
    }.


-spec album_record_to_pb(album()) -> pb_album().
album_record_to_pb(AlbumRecord) ->
    TimeRange = time_range_tuple_to_pb(AlbumRecord#album.time_range),
    Location = location_tuple_to_pb(AlbumRecord#album.location),
    Members = lists:map(
        fun(#album_member{uid = Uid, role = Role, pending = Pending}) ->
            {Name, Username, AvatarId} = model_accounts:get_album_member_info(Uid),
            #pb_album_member{
                uid = Uid,
                name = Name,
                username = Username,
                avatar_id = AvatarId,
                role = Role,
                pending = Pending
            }
        end,
        AlbumRecord#album.members),
    #pb_album{
        id = AlbumRecord#album.id,
        name = AlbumRecord#album.name,
        owner = AlbumRecord#album.owner,
        time_range = TimeRange,
        location = Location,
        can_view = AlbumRecord#album.can_view,
        can_contribute = AlbumRecord#album.can_contribute,
        members = Members,
        media_items = AlbumRecord#album.media_items,
        cursor = AlbumRecord#album.cursor
    }.


-spec is_time_range_ok(maybe(pb_time_range())) -> boolean().
is_time_range_ok(#pb_time_range{start_timestamp = StartTs, end_timestamp = EndTs, utc_offset = Offset}) ->
    %% Ensure all fields are defined and EndTs is later than StartTs and that the Offset value is between -12 and 14 hours (inclusive)
    not lists:member(undefined, [EndTs, StartTs, Offset]) andalso EndTs > StartTs andalso (-12 * ?HOURS) =< Offset andalso Offset =< (14 * ?HOURS);
is_time_range_ok(undefined) ->
    %% It is also valid for the time range not to exist
    true.


%% This function checks that all the fields of the media item have been appropriately designated
%% Returns false if there is an issue with any of the media items
-spec check_media_items(album_id(), uid(), list(pb_media_item())) -> boolean().
check_media_items(AlbumId, Uid, MediaItems) ->
    not lists:any(
        fun
            (#pb_media_item{id = <<>>}) -> true;
            (#pb_media_item{publisher_uid = PUid}) when PUid =/= Uid -> true;
            (#pb_media_item{publisher_name = <<>>}) -> true;
            (#pb_media_item{publisher_username = <<>>}) -> true;
            (#pb_media_item{album_id = AId}) when AId =/= AlbumId -> true;
            (#pb_media_item{device_capture_timestamp_ms = 0}) -> true;
            (#pb_media_item{upload_timestamp_ms = 0}) -> true;
            (_) -> false
        end,
        MediaItems).


-spec send_msg(uid(), uid(), pb_album()) -> ok.
send_msg(From, To, Payload) ->
    MsgId = util_id:new_msg_id(),
    ?INFO("FromUid: ~p, ToUid: ~p, MsgId: ~p", [From, To, MsgId]),
    Msg = #pb_msg{
        id = MsgId,
        to_uid = To,
        from_uid = From,
        payload = Payload
    },
    ejabberd_router:route(Msg).

