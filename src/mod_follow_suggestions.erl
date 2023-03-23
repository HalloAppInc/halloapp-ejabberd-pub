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
-define(FOF_SUGGESTIONS_BATCH_LIMIT, 50).
-define(FOF_SUGGESTIONS_TOTAL_LIMIT, 100).

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% hooks and api.
-export([
    process_local_iq/1,
    generate_fof_uids/0,
    update_fof/1,
    generate_follow_suggestions/0,
    update_follow_suggestions/1,
    update_follow_suggestions/2,
    fetch_follow_suggestions/1
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
    FollowSuggestions = fetch_follow_suggestions(Uid),
    pb:make_iq_result(IQ, #pb_follow_suggestions_response{result = ok, suggested_profiles = FollowSuggestions}).

check_and_schedule() ->
    case util:is_main_stest() of
        true ->
            ?INFO("Scheduling fof run", []),
            erlcron:cron(follow_suggestions, {
                {daily, {10, 00, am}},
                {?MODULE, generate_fof_uids, []}
            }),
            erlcron:cron(follow_suggestions, {
                {daily, {10, 00, am}},
                {?MODULE, generate_follow_suggestions, []}
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
        [{execute, sequential}, {scan_count, 500}]).


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
    %% We choose at most FOF_BATCH_LIMIT uids and obtain at most FOF_BATCH_LIMIT followers.
    %% So max number of uids in BroaderFollowingSet is 5 * FOF_BATCH_LIMIT * FOF_BATCH_LIMIT
    FofollowingSet = sets:from_list(model_follow:get_random_following(lists:sublist(sets:to_list(AllFollowingSet), ?FOF_BATCH_LIMIT), ?FOF_BATCH_LIMIT)),
    FoContactSet = sets:from_list(model_follow:get_random_following(lists:sublist(sets:to_list(ContactUidSet), ?FOF_BATCH_LIMIT), ?FOF_BATCH_LIMIT)),
    FoRevContactSet = sets:from_list(model_follow:get_random_following(lists:sublist(sets:to_list(RevContactUidSet), ?FOF_BATCH_LIMIT), ?FOF_BATCH_LIMIT)),
    FoGeoTagUidSet = sets:from_list(model_follow:get_random_following(lists:sublist(sets:to_list(GeoTagUidSet), ?FOF_BATCH_LIMIT), ?FOF_BATCH_LIMIT)),
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


generate_follow_suggestions() ->
    %% TODO: change migration to run for every zoneoffset uids.
    %% that will ensure we do this in batches throughout the day.
    redis_migrate:start_migration("calculate_fof_run", redis_accounts,
        {migrate_check_accounts, generate_follow_suggestions},
        [{execute, sequential}, {scan_count, 500}]).


%% TODO: need to optimize.
-spec update_follow_suggestions(Uid :: uid()) -> [pb_suggested_profile()].
update_follow_suggestions(Uid) ->
    case model_accounts:get_phone(Uid) of
        {error, missing} ->
            ?ERROR("Uid: ~p without phone number", [Uid]),
            [];
        {ok, Phone} ->
            update_follow_suggestions(Uid, Phone)
    end.


update_follow_suggestions(Uid, Phone) ->
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
    %% We choose at most FOF_BATCH_LIMIT uids and obtain at most FOF_BATCH_LIMIT followers.
    %% So max number of uids in BroaderFollowingSet is 5 * FOF_SUGGESTIONS_BATCH_LIMIT * FOF_SUGGESTIONS_BATCH_LIMIT
    FofollowingSet = sets:from_list(model_follow:get_random_following(lists:sublist(sets:to_list(AllFollowingSet), ?FOF_SUGGESTIONS_BATCH_LIMIT), ?FOF_SUGGESTIONS_BATCH_LIMIT)),
    FoContactSet = sets:from_list(model_follow:get_random_following(lists:sublist(sets:to_list(ContactUidSet), ?FOF_SUGGESTIONS_BATCH_LIMIT), ?FOF_SUGGESTIONS_BATCH_LIMIT)),
    FoRevContactSet = sets:from_list(model_follow:get_random_following(lists:sublist(sets:to_list(RevContactUidSet), ?FOF_SUGGESTIONS_BATCH_LIMIT), ?FOF_SUGGESTIONS_BATCH_LIMIT)),
    FoGeoTagUidSet = sets:from_list(model_follow:get_random_following(lists:sublist(sets:to_list(GeoTagUidSet), ?FOF_SUGGESTIONS_BATCH_LIMIT), ?FOF_SUGGESTIONS_BATCH_LIMIT)),
    BroaderFollowingUidSet = sets:union([FofollowingSet, FoContactSet, FoRevContactSet, FoGeoTagUidSet]),
    Time6 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get broader following set: ~p", [Uid, Time6 - Time5]),

    %% BlockedUser set
    BlockedUidSet = sets:from_list(model_follow:get_blocked_uids(Uid)),
    BlockedByUidSet = sets:from_list(model_follow:get_blocked_by_uids(Uid)),
    Time7 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get blocked uid set: ~p", [Uid, Time7 - Time6]),

    %% RejectedUser set
    {ok, RejectedUids} = model_accounts:get_all_rejected_suggestions(Uid),
    RejectedUidSet = sets:from_list(RejectedUids),
    Time8 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get rejected uid set: ~p", [Uid, Time8 - Time7]),

    %% Calculate Fof Suggestions
    FoFSuggestionsSet = sets:subtract(
        sets:union([BroaderFollowingUidSet, RevContactUidSet, GeoTagUidSet]),
        sets:union([AllFollowingSet, BlockedByUidSet, BlockedUidSet, RejectedUidSet, ContactUidSet])),
    Time9 = util:now_ms(),
    %%TODO: model_feed:get_active_uids --> this code is very bad, talk to vipin.
    ?INFO("Uid: ~p, Time taken to get fof suggestions: ~p", [Uid, Time9 - Time8]),

    %% Calculate Contact Suggestions
    ContactSuggestionsSet = sets:subtract(
        ContactUidSet,
        sets:union([AllFollowingSet, BlockedByUidSet, BlockedUidSet, RejectedUidSet])),
    Time10 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get contact suggestions: ~p", [Uid, Time10 - Time9]),

    %% Reverse sort ContactSuggestionsSet, FoFSuggestionsSet on number of followers
    ContactSuggestions = sort_suggestions(Uid, ContactSuggestionsSet),
    Time11 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to sort contact suggestions: ~p, size: ~p", [Uid, Time11 - Time10, length(ContactSuggestions)]),

    FoFSuggestions = sort_suggestions(Uid, FoFSuggestionsSet),
    Time12 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to sort fof suggestions: ~p, size: ~p", [Uid, Time12 - Time11, length(FoFSuggestions)]),

    TrimmedContactSuggestions = lists:sublist(ContactSuggestions, ?FOF_SUGGESTIONS_TOTAL_LIMIT),
    TrimmedFoFSuggestions = lists:sublist(FoFSuggestions, ?FOF_SUGGESTIONS_TOTAL_LIMIT),
    Time13 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to trim contact and fof suggestions: ~p", [Uid, Time13 - Time12]),

    ok = model_follow:update_contact_suggestions(Uid, TrimmedContactSuggestions),
    ok = model_follow:update_fof_suggestions(Uid, TrimmedFoFSuggestions),
    Time14 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to store contact and fof suggestions: ~p", [Uid, Time14 - Time13]),
    ?INFO("Uid: ~p, Total time taken: ~p", [Uid, Time14 - Time1]),
    ok.


sort_suggestions(Uid, SuggestionsSet) ->
    OUidList = sets:to_list(SuggestionsSet),
    OProfilesList = model_accounts:get_basic_user_profiles(Uid, OUidList),
    OFollowersCountList = model_follow:get_followers_count(OUidList),
    OList = lists:zip3(OUidList, OProfilesList, OFollowersCountList),
    SortedTuples = lists:sort(
        fun({_OUid1, OUidProfile1, OUidFollowerCount1}, {_OUid2, OUidProfile2, OUidFollowerCount2}) ->
            NumMutualFollow1 = OUidProfile1#pb_basic_user_profile.num_mutual_following,
            NumMutualFollow2 = OUidProfile2#pb_basic_user_profile.num_mutual_following,
            case NumMutualFollow1 =:= NumMutualFollow2 of
                true -> OUidFollowerCount1 >= OUidFollowerCount2;
                false -> NumMutualFollow1 >= NumMutualFollow2
            end
        end, OList),
    [OUid || {OUid, _, _} <- SortedTuples].


fetch_follow_suggestions(Uid) ->
    Time1 = util:now_ms(),
    ContactSuggestions = model_follow:get_contact_suggestions(Uid),
    FoFSuggestions = model_follow:get_fof_suggestions(Uid),
    Time2 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to fetch both contact and fof suggestions: ~p", [Uid, Time2 - Time1]),

    ContactSuggestedProfiles = filter_and_convert_to_suggestions(Uid, ContactSuggestions, direct_contact, 1),
    Time3 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to filter and convert contact suggestions: ~p", [Uid, Time3 - Time2]),

    FoFSuggestedProfiles = filter_and_convert_to_suggestions(Uid, FoFSuggestions, fof, length(ContactSuggestions)+1),
    Time4 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to filter and convert fof suggestions: ~p", [Uid, Time4 - Time3]),

    AllSuggestedProfiles = ContactSuggestedProfiles ++ FoFSuggestedProfiles,
    %% TODO: handle edgecase of empty fof suggestions.
    %% model_feed:get_active_uids code is not great.
    AllSuggestedProfiles.


%% Filter out following uids, self uids, blocked-any uids, rejected uids and uids without name/username.
%% Send in the remaining suggested profiles in ranked order.
filter_and_convert_to_suggestions(Uid, Suggestions, Reason, StartingRank) ->
    FollowingSet = sets:from_list(model_follow:get_all_following(Uid) ++ [Uid]),
    BlockedUidSet = sets:from_list(model_follow:get_blocked_uids(Uid)),
    BlockedByUidSet = sets:from_list(model_follow:get_blocked_by_uids(Uid)),
    {ok, RejectedUids} = model_accounts:get_all_rejected_suggestions(Uid),
    RejectedUidSet = sets:from_list(RejectedUids),
    %% Combine all into unacceptable list of uids.
    UnacceptedUids = sets:union([FollowingSet, BlockedUidSet, BlockedByUidSet, RejectedUidSet]),
    %% Get all profiles as well.
    SuggestedProfiles = model_accounts:get_basic_user_profiles(Uid, Suggestions),
    %% Filter them out once.
    FilteredSuggestions = lists:filtermap(
        fun({Ouid, OuidProfile}) ->
            case sets:is_element(Ouid, UnacceptedUids) of
                true -> false;
                false ->
                    case OuidProfile#pb_basic_user_profile.name =/= undefined andalso
                            OuidProfile#pb_basic_user_profile.username =/= undefined of
                        true -> {true, OuidProfile};
                        false -> false
                    end
            end
        end, lists:zip(Suggestions, SuggestedProfiles)),

    %% Set a proper rank and reason and return.
    {FinalSuggestedProfiles, _} = lists:mapfoldl(
        fun(OuidProfile, Rank) ->
            {
                #pb_suggested_profile{
                    user_profile = OuidProfile,
                    reason = Reason,
                    rank = Rank
                }, 
                Rank+1
            }
        end, StartingRank, FilteredSuggestions),
    FinalSuggestedProfiles.
 
