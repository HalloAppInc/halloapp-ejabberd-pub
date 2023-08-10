%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_albums_tests).
-author("josh").

-include("albums.hrl").
-include("server.hrl").
-include_lib("tutil.hrl").

setup() ->
    tutil:setup([
        {redis, [redis_accounts, redis_feed]}
    ]).

%% When an album is converted from a pb, some fields (like time_range) are
%% expanded for easier processing later. Since these tests skip this processing
%% as it's done in mod_albums, we replicate it here.
album_wrapper(Album) ->
    mod_albums:album_pb_to_record(Album).


parse_member_actions_testset(_) ->
    OwnerUid = tutil:generate_uid(),
    AdminUid = tutil:generate_uid(),
    NotInterestedUid = tutil:generate_uid(),
    MistakenlyInvitedUid = tutil:generate_uid(),
    AlbumId = model_albums:create_album(OwnerUid, album_wrapper(#pb_album{name = <<"name">>, can_view = everyone, can_contribute = everyone})),
    OwnerAction1 = [#pb_album_member{uid = AdminUid, action = invite, role = admin}, #pb_album_member{uid = NotInterestedUid, action = invite, role = admin},
        #pb_album_member{uid = MistakenlyInvitedUid, action = invite, role = viewer}],
    OwnerResult1 = [{set, AdminUid, admin, true}, {set, NotInterestedUid, admin, true}, {set, MistakenlyInvitedUid, viewer, true}],
    AdminAction1 = [#pb_album_member{uid = AdminUid, action = accept_invite}],
    AdminResult2 = [{set, AdminUid, admin, false}],
    NotInterestedAction1 = [#pb_album_member{uid = NotInterestedUid, action = reject_invite}],
    NotInterestedResult1 = [{remove, NotInterestedUid, false}],
    OwnerAction2 = [#pb_album_member{uid = MistakenlyInvitedUid, action = un_invite}],
    OwnerResult2 = [{remove, MistakenlyInvitedUid, false}],
    JoinedUid = tutil:generate_uid(),
    JoinedAction1 = [#pb_album_member{uid = JoinedUid, action = join}],
    JoinedResult1 = [{set, JoinedUid, contributor, false}],
    OwnerAction3 = [#pb_album_member{uid = AdminUid, action = demote, role = contributor}, #pb_album_member{uid = JoinedUid, action = promote, role = admin}],
    OwnerResult3 = [{set, AdminUid, contributor, false}, {set, JoinedUid, admin, false}],
    JoinedAction2 = [#pb_album_member{uid = AdminUid, action = remove}, #pb_album_member{uid = JoinedUid, action = leave, remove_media = true}],
    JoinedResult2 = [{remove, AdminUid, false}, {remove, JoinedUid, true}],
    OwnerDisallowedAction1 = [#pb_album_member{uid = JoinedUid, action = promote, role = owner}],
    OwnerDisallowedAction2 = [#pb_album_member{uid = OwnerUid, action = leave}],
    MistakenlyDisallowedAction1 = [#pb_album_member{uid = MistakenlyInvitedUid, action = accept_invite}],
    OwnerDisallowedAction3 = [#pb_album_member{uid = AdminUid, action = demote, role = contributor}],
    AdminDisallowedAction1 = [#pb_album_member{uid = NotInterestedUid, action = invite, role = admin}],
    [
        %% Owner invites a bunch of other users
        ?_assertEqual(OwnerResult1, mod_albums:parse_member_actions(AlbumId, OwnerUid, OwnerAction1)),
        ?_assertOk(model_albums:execute_member_actions(AlbumId, OwnerResult1)),
        %% One user accepts the invitation to join as an admin
        ?_assertEqual(AdminResult2, mod_albums:parse_member_actions(AlbumId, AdminUid, AdminAction1)),
        ?_assertOk(model_albums:execute_member_actions(AlbumId, AdminResult2)),
        %% Another user rejects the invite
        ?_assertEqual(NotInterestedResult1, mod_albums:parse_member_actions(AlbumId, NotInterestedUid, NotInterestedAction1)),
        ?_assertOk(model_albums:execute_member_actions(AlbumId, NotInterestedResult1)),
        %% Owner un-invites someone
        ?_assertEqual(OwnerResult2, mod_albums:parse_member_actions(AlbumId, OwnerUid, OwnerAction2)),
        ?_assertOk(model_albums:execute_member_actions(AlbumId, OwnerResult2)),
        %% At this point the album has an owner and an admin
        %% A user joins the album as a contributor (the highest level with share access = everyone)
        ?_assertEqual(JoinedResult1, mod_albums:parse_member_actions(AlbumId, JoinedUid, JoinedAction1)),
        ?_assertOk(model_albums:execute_member_actions(AlbumId, JoinedResult1)),
        %% Owner promotes the new contributor and demotes the existing admin
        ?_assertEqual(OwnerResult3, mod_albums:parse_member_actions(AlbumId, OwnerUid, OwnerAction3)),
        ?_assertOk(model_albums:execute_member_actions(AlbumId, OwnerResult3)),
        %% The new admin removes the newly-demoted contributor and then leaves the album
        %% We won't execute this action so the album still has some members for further tests
        %% Album state is: OwnerUid = owner, AdminUid = contributor, JoinedUid = admin
        ?_assertEqual(JoinedResult2, mod_albums:parse_member_actions(AlbumId, JoinedUid, JoinedAction2)),
        %% Owner tries to promote admin to owner – shouldn't be allowed
        ?_assertEqual([not_allowed], mod_albums:parse_member_actions(AlbumId, OwnerUid, OwnerDisallowedAction1)),
        %% Owner tries to leave – shouldn't be allowed
        ?_assertEqual([not_allowed], mod_albums:parse_member_actions(AlbumId, OwnerUid, OwnerDisallowedAction2)),
        %% Random user tries to accept a non-existing invite – shouldn't be allowed
        ?_assertEqual([not_allowed], mod_albums:parse_member_actions(AlbumId, MistakenlyInvitedUid, MistakenlyDisallowedAction1)),
        %% Owner tries to demote someone to the same role they are currently in – shouldn't be allowed
        ?_assertEqual([not_allowed], mod_albums:parse_member_actions(AlbumId, OwnerUid, OwnerDisallowedAction3)),
        %% Contributor tries to invite someone as an admin – shouldn't be allowed
        ?_assertEqual([not_allowed], mod_albums:parse_member_actions(AlbumId, AdminUid, AdminDisallowedAction1))
    ].


is_role_higher_testparallel(_) ->
    {inparallel, [
        ?_assertNot(mod_albums:is_role_higher(owner, owner)),
        ?_assert(mod_albums:is_role_higher(owner, admin)),
        ?_assert(mod_albums:is_role_higher(owner, contributor)),
        ?_assert(mod_albums:is_role_higher(owner, viewer)),
        ?_assert(mod_albums:is_role_higher(owner, none)),
        ?_assertNot(mod_albums:is_role_higher(admin, owner)),
        ?_assertNot(mod_albums:is_role_higher(admin, admin)),
        ?_assert(mod_albums:is_role_higher(admin, contributor)),
        ?_assert(mod_albums:is_role_higher(admin, viewer)),
        ?_assert(mod_albums:is_role_higher(admin, none)),
        ?_assertNot(mod_albums:is_role_higher(contributor, owner)),
        ?_assertNot(mod_albums:is_role_higher(contributor, admin)),
        ?_assertNot(mod_albums:is_role_higher(contributor, contributor)),
        ?_assert(mod_albums:is_role_higher(contributor, viewer)),
        ?_assert(mod_albums:is_role_higher(contributor, none)),
        ?_assertNot(mod_albums:is_role_higher(viewer, owner)),
        ?_assertNot(mod_albums:is_role_higher(viewer, admin)),
        ?_assertNot(mod_albums:is_role_higher(viewer, contributor)),
        ?_assertNot(mod_albums:is_role_higher(viewer, viewer)),
        ?_assert(mod_albums:is_role_higher(viewer, none)),
        ?_assertNot(mod_albums:is_role_higher(none, owner)),
        ?_assertNot(mod_albums:is_role_higher(none, admin)),
        ?_assertNot(mod_albums:is_role_higher(none, contributor)),
        ?_assertNot(mod_albums:is_role_higher(none, viewer)),
        ?_assertNot(mod_albums:is_role_higher(none, none))
    ]}.


is_role_lower_testparallel(_) ->
    {inparallel, [
        ?_assertNot(mod_albums:is_role_lower(owner, owner)),
        ?_assertNot(mod_albums:is_role_lower(owner, admin)),
        ?_assertNot(mod_albums:is_role_lower(owner, contributor)),
        ?_assertNot(mod_albums:is_role_lower(owner, viewer)),
        ?_assertNot(mod_albums:is_role_lower(owner, none)),
        ?_assert(mod_albums:is_role_lower(admin, owner)),
        ?_assertNot(mod_albums:is_role_lower(admin, admin)),
        ?_assertNot(mod_albums:is_role_lower(admin, contributor)),
        ?_assertNot(mod_albums:is_role_lower(admin, viewer)),
        ?_assertNot(mod_albums:is_role_lower(admin, none)),
        ?_assert(mod_albums:is_role_lower(contributor, owner)),
        ?_assert(mod_albums:is_role_lower(contributor, admin)),
        ?_assert(mod_albums:is_role_lower(contributor, contributor)),
        ?_assertNot(mod_albums:is_role_lower(contributor, viewer)),
        ?_assertNot(mod_albums:is_role_lower(contributor, none)),
        ?_assert(mod_albums:is_role_lower(viewer, owner)),
        ?_assert(mod_albums:is_role_lower(viewer, admin)),
        ?_assert(mod_albums:is_role_lower(viewer, contributor)),
        ?_assert(mod_albums:is_role_lower(viewer, viewer)),
        ?_assertNot(mod_albums:is_role_lower(viewer, none)),
        ?_assert(mod_albums:is_role_lower(none, owner)),
        ?_assert(mod_albums:is_role_lower(none, admin)),
        ?_assert(mod_albums:is_role_lower(none, contributor)),
        ?_assert(mod_albums:is_role_lower(none, viewer)),
        ?_assertNot(mod_albums:is_role_lower(none, none))
    ]}.

