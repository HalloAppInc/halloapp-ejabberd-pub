%%%----------------------------------------------------------------------
%%% File    : mod_friend_suggestions.erl
%%%
%%% Copyright (C) 2023 HalloApp Inc.
%%%
%%% This file generates friend suggestions.
%%%----------------------------------------------------------------------

-module(mod_friend_suggestions).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").

%% limits for num of fof users.
-define(FOF_SUGGESTIONS_INITIAL_LIMIT, 20).
-define(FOF_SUGGESTIONS_BATCH_LIMIT, 50).
-define(FOF_SUGGESTIONS_TOTAL_LIMIT, 100).

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% hooks and api.
-export([
    generate_friend_suggestions/0,
    update_friend_suggestions/1,
    update_friend_suggestions/2,
    fetch_friend_suggestions/1,
    register_user/4,
    re_register_user/4,
    remove_friend/4
]).


%%====================================================================
%% gen_mod api
%%====================================================================

start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    ejabberd_hooks:add(re_register_user, halloapp, ?MODULE, re_register_user, 100),
    ejabberd_hooks:add(register_user, halloapp, ?MODULE, register_user, 100),
    ejabberd_hooks:add(remove_friend, halloapp, ?MODULE, remove_friend, 50),
    check_and_schedule(),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ejabberd_hooks:delete(re_register_user, halloapp, ?MODULE, re_register_user, 100),
    ejabberd_hooks:delete(register_user, halloapp, ?MODULE, register_user, 100),
    ejabberd_hooks:delete(remove_friend, halloapp, ?MODULE, remove_friend, 50),
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

-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
re_register_user(Uid, _Server, _Phone, _CampaignId) ->
    spawn(?MODULE, update_friend_suggestions, [Uid]),
    ok.

-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
register_user(Uid, _Server, _Phone, _CampaignId) ->
    spawn(?MODULE, update_friend_suggestions, [Uid]),
    ok.

remove_friend(Uid, _Server, Ouid, _WasBlocked) ->
    ok = model_accounts:add_rejected_suggestions(Ouid, [Uid]),
    spawn(?MODULE, update_friend_suggestions, [Uid]),
    ok.


check_and_schedule() ->
    case util:is_main_stest() of
        true ->
            ?INFO("Scheduling friend suggestions run", []),
            erlcron:cron(generate_friend_suggestions, {
                {daily, {10, 00, am}},
                {?MODULE, generate_friend_suggestions, []}
            }),
            ok;
        false ->
            ok
    end.


generate_friend_suggestions() ->
    redis_migrate:start_migration("calculate_friend_suggestions", redis_accounts,
        {migrate_check_accounts, calculate_friend_suggestions},
        [{execute, sequential}, {scan_count, 500}]).


%% TODO: need to optimize.
-spec update_friend_suggestions(Uid :: uid()) -> [pb_suggested_profile()].
update_friend_suggestions(Uid) ->
    case model_accounts:get_phone(Uid) of
        {error, missing} ->
            ?ERROR("Uid: ~p without phone number", [Uid]),
            [];
        {ok, Phone} ->
            update_friend_suggestions(Uid, Phone)
    end.


update_friend_suggestions(Uid, Phone) ->
    Time1 = util:now_ms(),
    %% Get Uid info:
    AppType = util_uid:get_app_type(Uid),
    {ok, Phone} = model_accounts:get_phone(Uid),

    AllFriendSet = case model_accounts:get_username_binary(Uid) of
        <<>> ->
            %% halloapp user has not migrated yet.
            %% use mutual add based friends for suggestions.
            {ok, OldFriendUids} = model_friends:get_friends(Uid),
            sets:from_list(OldFriendUids);
        _ ->
            %% halloapp user already migrated and set username.
            %% use halloapp friends
            sets:from_list(model_halloapp_friends:get_all_friends(Uid))
    end,
    Time2 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get user info: ~p", [Uid, Time2 - Time1]),

    %% 1. Find list of contact uids.
    {ok, ContactPhones} = model_contacts:get_contacts(Uid),
    ContactUids = maps:values(model_phone:get_uids(ContactPhones, AppType)),
    ContactUidSet = sets:from_list(ContactUids),
    Time3 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get contact uids: ~p", [Uid, Time3 - Time2]),

    %% 2. Find list of reverse contact uids.
    RevContactUidSet = case Phone of
        <<"">> -> sets:from_list([]);
        _ ->
            {ok, RevContactUids} = model_contacts:get_contact_uids(Phone, AppType),
            sets:from_list(RevContactUids)
    end,
    Time4 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get rev contact uids: ~p", [Uid, Time4 - Time3]),

    %% 4. Find uids followed by all the above - friends, contacts, revcontacts.
    %% We choose at most FOF_SUGGESTIONS_BATCH_LIMIT uids and obtain at most FOF_SUGGESTIONS_BATCH_LIMIT
    %% So max number of uids in BroaderFriendSuggestionsUidSet is 3 * FOF_SUGGESTIONS_BATCH_LIMIT * FOF_SUGGESTIONS_BATCH_LIMIT
    FofriendSet = sets:from_list(model_halloapp_friends:get_random_friends(lists:sublist(sets:to_list(AllFriendSet), ?FOF_SUGGESTIONS_INITIAL_LIMIT), ?FOF_SUGGESTIONS_BATCH_LIMIT)),
    FoContactSet = sets:from_list(model_halloapp_friends:get_random_friends(lists:sublist(sets:to_list(ContactUidSet), ?FOF_SUGGESTIONS_INITIAL_LIMIT), ?FOF_SUGGESTIONS_BATCH_LIMIT)),
    FoRevContactSet = sets:from_list(model_halloapp_friends:get_random_friends(lists:sublist(sets:to_list(RevContactUidSet), ?FOF_SUGGESTIONS_INITIAL_LIMIT), ?FOF_SUGGESTIONS_BATCH_LIMIT)),
    BroaderFriendSuggestionsUidSet = sets:union([FofriendSet, FoContactSet, FoRevContactSet]),
    Time5 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get broader friend suggestion set: ~p", [Uid, Time5 - Time4]),

    %% BlockedUser set
    BlockedUidSet = sets:from_list(model_follow:get_blocked_uids(Uid)),
    BlockedByUidSet = sets:from_list(model_follow:get_blocked_by_uids(Uid)),
    Time6 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get blocked uid set: ~p", [Uid, Time6 - Time5]),

    %% RejectedUser set
    {ok, RejectedUids} = model_accounts:get_all_rejected_suggestions(Uid),
    RejectedUidSet = sets:from_list(RejectedUids),
    Time7 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get rejected uid set: ~p", [Uid, Time7 - Time6]),

    %% Calculate Friend Suggestions
    FoFSuggestionsSet = sets:subtract(
        sets:union([BroaderFriendSuggestionsUidSet, RevContactUidSet]),
        sets:union([AllFriendSet, BlockedByUidSet, BlockedUidSet, RejectedUidSet, ContactUidSet])),
    Time8 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get friend suggestions: ~p", [Uid, Time8 - Time7]),

    %% Calculate Contact Suggestions
    ContactSuggestionsSet = sets:subtract(
        ContactUidSet,
        sets:union([AllFriendSet, BlockedByUidSet, BlockedUidSet, RejectedUidSet])),
    Time9 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to get contact suggestions: ~p", [Uid, Time9 - Time8]),

    %% Reverse sort ContactSuggestionsSet, FoFSuggestionsSet on number of followers
    ContactSuggestions = sort_suggestions(Uid, ContactSuggestionsSet),
    Time10 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to sort contact suggestions: ~p, size: ~p", [Uid, Time10 - Time9, length(ContactSuggestions)]),

    FoFSuggestions = sort_suggestions(Uid, FoFSuggestionsSet),
    Time11 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to sort fof suggestions: ~p, size: ~p", [Uid, Time11 - Time10, length(FoFSuggestions)]),

    TrimmedContactSuggestions = lists:sublist(ContactSuggestions, ?FOF_SUGGESTIONS_TOTAL_LIMIT),
    TrimmedFoFSuggestions = lists:sublist(FoFSuggestions, ?FOF_SUGGESTIONS_TOTAL_LIMIT),
    Time12 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to trim contact and fof suggestions: ~p", [Uid, Time12 - Time11]),


    ok = model_halloapp_friends:update_contact_suggestions(Uid, TrimmedContactSuggestions),
    ok = model_halloapp_friends:update_fof_suggestions(Uid, TrimmedFoFSuggestions),
    Time13 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to store contact and fof suggestions: ~p", [Uid, Time13 - Time12]),
    ?INFO("Uid: ~p, Total time taken: ~p", [Uid, Time13 - Time1]),
    ok.


sort_suggestions(Uid, SuggestionsSet) ->
    Ouids = sets:to_list(SuggestionsSet),
    OuidsMutualFriendCount = model_halloapp_friends:get_num_mutual_friends(Uid, Ouids),
    OList = lists:zip(Ouids, OuidsMutualFriendCount),
    SortedTuples = lists:sort(
        fun({_OUid1, OuidMutualFriendCount1}, {_OUid2, OuidMutualFriendCount2}) ->
            OuidMutualFriendCount1 >= OuidMutualFriendCount2
        end, OList),
    [OUid || {OUid, _} <- SortedTuples].


fetch_friend_suggestions(Uid) ->
    Time1 = util:now_ms(),
    ContactSuggestions = model_halloapp_friends:get_contact_suggestions(Uid),
    FoFSuggestions = model_halloapp_friends:get_fof_suggestions(Uid),
    Time2 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to fetch both contact and fof suggestions: ~p", [Uid, Time2 - Time1]),

    ContactSuggestedProfiles = filter_and_convert_to_suggestions(Uid, ContactSuggestions, direct_contact, 1),
    Time3 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to filter and convert contact suggestions: ~p", [Uid, Time3 - Time2]),

    FoFSuggestedProfiles = filter_and_convert_to_suggestions(Uid, FoFSuggestions, friends_of_friends, length(ContactSuggestions)+1),
    Time4 = util:now_ms(),
    ?INFO("Uid: ~p, Time taken to filter and convert fof suggestions: ~p", [Uid, Time4 - Time3]),

    AllSuggestedProfiles = ContactSuggestedProfiles ++ FoFSuggestedProfiles,
    %% TODO: handle edgecase of empty fof suggestions.
    %% model_feed:get_active_uids code is not great.
    AllSuggestedProfiles.


%% Filter out following uids, self uids, blocked-any uids, rejected uids and uids without name/username.
%% Send in the remaining suggested profiles in ranked order.
filter_and_convert_to_suggestions(Uid, Suggestions, Reason, StartingRank) ->
    FriendSet = sets:from_list([Uid | model_halloapp_friends:get_all_friends(Uid)]),
    BlockedUidSet = sets:from_list(model_halloapp_friends:get_blocked_uids(Uid)),
    BlockedByUidSet = sets:from_list(model_halloapp_friends:get_blocked_by_uids(Uid)),
    IncomingFriendSet = sets:from_list(model_halloapp_friends:get_all_incoming_friends(Uid)),
    OutgoingFriendSet = sets:from_list(model_halloapp_friends:get_all_outgoing_friends(Uid)),
    {ok, RejectedUids} = model_accounts:get_all_rejected_suggestions(Uid),
    RejectedUidSet = sets:from_list(RejectedUids),
    %% Combine all into unacceptable list of uids.
    UnacceptedUids = sets:union([FriendSet, BlockedUidSet, BlockedByUidSet,IncomingFriendSet, OutgoingFriendSet, RejectedUidSet]),
    %% Get all profiles as well.
    SuggestedProfiles = model_accounts:get_halloapp_user_profiles(Uid, Suggestions),
    %% Filter them out, set a proper rank and return.
    FinalSuggestedProfiles = lists:filtermap(
        fun({Ouid, OuidProfile, Rank}) ->
            case sets:is_element(Ouid, UnacceptedUids) of
                true -> false;
                false ->
                    case OuidProfile#pb_halloapp_user_profile.name =/= undefined andalso
                            OuidProfile#pb_halloapp_user_profile.username =/= undefined of
                        true -> {true, #pb_friend_profile{
                                            user_profile = OuidProfile,
                                            reason = Reason,
                                            rank = Rank
                                        }
                                };
                        false -> false
                    end
            end
        end, lists:zip3(Suggestions, SuggestedProfiles, lists:seq(StartingRank, StartingRank+length(Suggestions)-1))),
    FinalSuggestedProfiles.

