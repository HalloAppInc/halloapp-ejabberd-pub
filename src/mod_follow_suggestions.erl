%%%----------------------------------------------------------------------
%%% File    : mod_follow_suggest.erl
%%%
%%% Copyright (C) 2022 HalloApp Inc.
%%%
%%% This file generates follow suggestions.
%%%----------------------------------------------------------------------

-module(mod_follow_suggestions).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").

-define(CONTACT_SCORE, 100).
-define(REV_CONTACT_SCORE, 70).
-define(GEO_TAG_SCORE, 25).
-define(FOFOLLOWING_SCORE, 40).
-define(FOCONTACT_SCORE, 40).
-define(FOREVCONTACT_SCORE, 20).
-define(FOGEOTAG_SCORE, 20).
-define(FOF_RUNTIME_LIMIT_MS, 100).
%% limits for num of fof users.
-define(FOF_BATCH_LIMIT, 100).
-define(FOF_TOTAL_LIMIT, 500).

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% hooks and api.
-export([
    process_local_iq/1,
    generate_follow_suggestions/1,
    remove_deleted/1,
    generate_fof_uids/0,
    update_fof/1
]).


%%====================================================================
%% gen_mod api
%%====================================================================

start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_follow_suggestions_request, ?MODULE, process_local_iq),
    check_and_schedule(),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_follow_suggestions_request),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% iq handlers and api
%%====================================================================

process_local_iq(
    #pb_iq{from_uid = Uid, type = set, payload = #pb_follow_suggestions_request{
        action = reject, rejected_uids = RejectedUids}} = IQ) ->
    ?INFO("Uid: ~p, rejected uids: ~p", [Uid, RejectedUids]),
    stat:count("KA/suggestions", "reject"),
    ok = model_accounts:add_rejected_suggestions(Uid, RejectedUids),
    pb:make_iq_result(IQ, #pb_follow_suggestions_response{result = ok});

process_local_iq(
    #pb_iq{from_uid = Uid, type = get, payload = #pb_follow_suggestions_request{
        action = get}} = IQ) ->
    ?INFO("Uid: ~p", [Uid]),
    stat:count("KA/suggestions", "follow"),
    FollowSuggestions = generate_follow_suggestions(Uid),
    pb:make_iq_result(IQ, #pb_follow_suggestions_response{result = ok, suggested_profiles = FollowSuggestions}).

%% TODO: need to optimize.
-spec generate_follow_suggestions(Uid :: uid()) -> [pb_suggested_profile()].
generate_follow_suggestions(Uid) ->
    case model_accounts:get_phone(Uid) of
        {error, missing} ->
            ?ERROR("Uid: ~p without phone number", [Uid]),
            [];
        {ok, Phone} ->
            generate_follow_suggestions(Uid, Phone)
    end.

check_and_schedule() ->
    case util:is_main_stest() of
        true ->
            ?INFO("Scheduling fof run", []),
            erlcron:cron(follow_suggestions, {
                {daily, {10, 00, am}},
                {?MODULE, generate_fof_uids, []}
            }),
            ok;
        false ->
            ok
    end.


generate_fof_uids() ->
    %% TODO: change migration to run for every zoneoffset uids.
    %% that will ensure we do this in batches throughout the day.
    redis_migrate:start_migration("calculate_fof_run", redis_accounts,
        {migrate_check_accounts, calculate_fof_run},
        [{execute, sequential}, {scan_count, 1000}]).


update_fof(Uid) ->
    Time1 = util:now_ms(),
    %% Get Uid info:
    AppType = util_uid:get_app_type(Uid),
    {ok, Phone} = model_accounts:get_phone(Uid),
    AllFollowingSet = sets:from_list(model_follow:get_all_following(Uid)),
    GeoTag = model_accounts:get_latest_geo_tag(Uid),
    Time2 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get user info: ~p", [Uid, Time2 - Time1]),

    %% 1. Find list of contact uids.
    {ok, ContactPhones} = model_contacts:get_contacts(Uid),
    ContactUids = maps:values(model_phone:get_uids(ContactPhones, AppType)),
    ContactUidSet = sets:from_list(ContactUids),
    Time3 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get contact uids: ~p", [Uid, Time3 - Time2]),

    %% 2. Find list of reverse contact uids.
    {ok, RevContactUids} = model_contacts:get_contact_uids(Phone, AppType),
    RevContactUidSet = sets:from_list(RevContactUids),
    Time4 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get rev contact uids: ~p", [Uid, Time4 - Time3]),

    %% 3. Find list of geo-tagged uids.
    GeoTagUidSet = case GeoTag of
        undefined -> sets:from_list([]);
        _ -> sets:from_list(model_accounts:get_geotag_uids(GeoTag))
    end,
    Time5 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get geo-tag uids: ~p", [Uid, Time5 - Time4]),

    %% 4. Find uids followed by all the above - following, contacts, revcontacts, geotagged uids.
    FofollowingSet = sets:from_list(model_follow:get_following(sets:to_list(AllFollowingSet), ?FOF_BATCH_LIMIT)),
    FoContactSet = sets:from_list(model_follow:get_following(sets:to_list(ContactUidSet), ?FOF_BATCH_LIMIT)),
    FoRevContactSet = sets:from_list(model_follow:get_following(sets:to_list(RevContactUidSet), ?FOF_BATCH_LIMIT)),
    FoGeoTagUidSet = sets:from_list(model_follow:get_following(sets:to_list(GeoTagUidSet), ?FOF_BATCH_LIMIT)),
    BroaderFollowingUidSet = sets:union([FofollowingSet, FoContactSet, FoRevContactSet, FoGeoTagUidSet]),
    Time6 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get broader following set: ~p", [Uid, Time6 - Time5]),

    %% BlockedUser set
    BlockedUidSet = sets:from_list(model_follow:get_blocked_uids(Uid)),
    BlockedByUidSet = sets:from_list(model_follow:get_blocked_by_uids(Uid)),
    Time7 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get blocked uid set: ~p", [Uid, Time7 - Time6]),

    %% Calculate potential Fof
    FofSet = sets:subtract(
        sets:union([BroaderFollowingUidSet, ContactUidSet, RevContactUidSet, GeoTagUidSet]),
        sets:union([AllFollowingSet, BlockedByUidSet, BlockedUidSet])),
    Time8 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get fof users without followers: ~p", [Uid, Time8 - Time7]),

    %% Score Fof
    TempFofWithScores = sets:fold(
        fun(FofUid, Acc) ->
            ContactScore = case sets:is_element(FofUid, ContactUidSet) of
                true -> ?CONTACT_SCORE;
                false -> 0
            end,
            RevContactScore = case sets:is_element(FofUid, RevContactUidSet) of
                true -> ?REV_CONTACT_SCORE;
                false -> 0
            end,
            GeoTagScore = case sets:is_element(FofUid, GeoTagUidSet) of
                true -> ?GEO_TAG_SCORE;
                false -> 0
            end,
            FoFollowingScore = case sets:is_element(FofUid, FofollowingSet) of
                true -> ?FOFOLLOWING_SCORE;
                false -> 0
            end,
            FoContactScore = case sets:is_element(FofUid, FoContactSet) of
                true -> ?FOCONTACT_SCORE;
                false -> 0
            end,
            FoRevContactScore = case sets:is_element(FofUid, FoRevContactSet) of
                true -> ?FOREVCONTACT_SCORE;
                false -> 0
            end,
            FoGeoTagScore = case sets:is_element(FofUid, FoGeoTagUidSet) of
                true -> ?FOGEOTAG_SCORE;
                false -> 0
            end,
            Acc#{FofUid => ContactScore + RevContactScore + GeoTagScore + FoFollowingScore + FoContactScore + FoRevContactScore + FoGeoTagScore}
        end, #{}, FofSet),
    %% Sort this map of uids and their scores by scores, pick the top uids by the limit and store them.
    FofWithScores = maps:from_list(lists:sublist(lists:reverse(lists:keysort(2, maps:to_list(TempFofWithScores))), ?FOF_TOTAL_LIMIT)),

    Time9 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to score fof: ~p, NumFoF: ~p", [Uid, Time9 - Time8, maps:size(FofWithScores)]),

    %% Store this in redis.
    ok = model_follow:update_fof(Uid, FofWithScores),
    Time10 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to store fof in redis: ~p", [Uid, Time10 - Time9]),

    case Time10 - Time1 > ?FOF_RUNTIME_LIMIT_MS of
        true ->
            ?WARNING("Uid: ~p, Total time taken to fetch, score and store fof: ~p", [Uid, Time10 - Time1]);
        false ->
            ?INFO("Uid: ~p, Total time taken to fetch, score and store fof: ~p", [Uid, Time10 - Time1])
    end,
    ok.


%%====================================================================
%% internal functions
%%====================================================================

generate_follow_suggestions(Uid, Phone) ->
    %% 1. Find list of contact uids.
    AppType = util_uid:get_app_type(Uid),
    {ok, ContactPhones} = model_contacts:get_contacts(Uid),
    ContactUids = maps:values(model_phone:get_uids(ContactPhones, AppType)),
    ContactUidsSet = sets:from_list(ContactUids),
 
    %% Find list of reverse contact uids.
    {ok, RevContactUids} = model_contacts:get_contact_uids(Phone, AppType),
    RevContactConsiderSet = sets:subtract(sets:from_list(RevContactUids), ContactUidsSet),
 
    %% 2. Find uids of followed by various follows and contacts
    AllFollowing = model_follow:get_all_following(Uid),
    AllFollowingAndContacts = sets:to_list(sets:union(sets:from_list(AllFollowing), ContactUidsSet)),
    FoFSet1 = sets:from_list(model_follow:get_all_following(AllFollowingAndContacts)),
    FoFSet2 = sets:union(RevContactConsiderSet, FoFSet1),

    %% 3. Find uids of geo tagged users.
    UidGeoTag = model_accounts:get_latest_geo_tag(Uid),
    GeoTagPopUids = case UidGeoTag of
        undefined -> [];
        _ -> model_accounts:get_geotag_uids(UidGeoTag)
    end,
    FoFSet = sets:union(sets:from_list(GeoTagPopUids), FoFSet2),
 
    {ok, RejectedUids} = model_accounts:get_all_rejected_suggestions(Uid),
 
    %% Keep only the new ones.
    AllSubtractSet = sets:union(sets:from_list(AllFollowing), sets:from_list(RejectedUids)),
    ContactSuggestionsSet = remove_deleted(sets:subtract(ContactUidsSet, AllSubtractSet)),
    FoFSuggestions1 = sets:subtract(FoFSet, AllSubtractSet),
    FoFSuggestionsSet = remove_deleted(sets:subtract(FoFSuggestions1, ContactSuggestionsSet)),
 
    %% Reverse sort ContactSuggestionsSet, FoFSuggestionsSet on number of followers
    ContactSuggestions = get_sorted_uids(Uid, ContactSuggestionsSet),
    FoFSuggestions = get_sorted_uids(Uid, FoFSuggestionsSet),
 
    %% Fetch Profiles
    ContactSuggestedProfiles =
        fetch_suggested_profiles(Uid, ContactSuggestions, direct_contact, 1),
    FoFSuggestedProfiles =
        fetch_suggested_profiles(Uid, FoFSuggestions, fof, length(ContactSuggestions) + 1),
    ContactSuggestedProfiles ++ FoFSuggestedProfiles.

remove_deleted(UidsSet) ->
    %% Get rid of deleted users.
    Uids = sets:to_list(UidsSet),
    Phones = model_accounts:get_phones(Uids),
    lists:foldl(fun({Uid, Phone}, Acc) ->
        case Phone of
            undefined -> Acc;
            _ -> sets:add_element(Uid, Acc)
        end
    end, sets:new(), lists:zip(Uids, Phones)).

get_sorted_uids(Uid, SuggestionsSet) ->
    OUidList = sets:to_list(SuggestionsSet),
    OProfilesList = model_accounts:get_basic_user_profiles(Uid, OUidList),
    OList = lists:zip(OUidList, OProfilesList),
    %% fetch followers count.
    Tuples = lists:foldl(fun({Ouid, OProfile}, Acc) ->
        case model_follow:is_blocked_any(Uid, Ouid) orelse Uid =:= Ouid of
            true -> Acc;
            false ->
                NumMutualFollowing = OProfile#pb_basic_user_profile.num_mutual_following,
                Acc ++ [{Ouid, NumMutualFollowing, model_follow:get_followers_count(Ouid)}]
        end
    end, [], OList),
    
    %% Sort and extract uids.
    SortedTuples = lists:sort(
        fun({_, NumMFollow1, NumFollowers1}, {_, NumMFollow2, NumFollowers2}) ->
            case NumMFollow1 =:= NumMFollow2 of
                true -> NumFollowers1 >= NumFollowers2;
                false -> NumMFollow1 >= NumMFollow2
            end
        end, Tuples),
    [Elem || {Elem, _, _} <- SortedTuples].

fetch_suggested_profiles(Uid, Suggestions, Reason, StartingRank) ->
    Profiles = model_accounts:get_basic_user_profiles(Uid, Suggestions),
    ProfilesWithRank =
        lists:zip(Profiles, lists:seq(StartingRank, StartingRank + length(Profiles) - 1)),
    [#pb_suggested_profile{user_profile = UserProfile, reason = Reason, rank = Rank} ||
        {UserProfile, Rank} <- ProfilesWithRank].
 
