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

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% hooks and api.
-export([
    process_local_iq/1,
    generate_follow_suggestions/1
]).


%%====================================================================
%% gen_mod api
%%====================================================================

start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_follow_suggestions_request, ?MODULE, process_local_iq),
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

generate_follow_suggestions(Uid, Phone) ->
    %% 1. Find list of contact uids.
    AppType = util_uid:get_app_type(Uid),
    {ok, ContactPhones} = model_contacts:get_contacts(Uid),
    ContactUids = maps:values(model_phone:get_uids(ContactPhones, AppType)),
    ContactUidsSet = sets:from_list(ContactUids),
 
    %% Find list of reverse contact uids.
    {ok, RevContactUids} = model_contacts:get_contact_uids(Phone, AppType),
    RevContactConsiderSet = sets:subtract(sets:from_list(RevContactUids), ContactUidsSet),
 
    %% 2. Find uids of followed by various follows
    AllFollowing = model_follow:get_all_following(Uid),
    FoFSet1 = lists:foldl(fun(Elem, Acc) ->
        FoF1 = model_follow:get_all_following(Elem),
        sets:union(Acc, sets:from_list(FoF1))
    end, sets:new(), AllFollowing),
    FoFSet = sets:union(RevContactConsiderSet, FoFSet1),
 
    {ok, RejectedUids} = model_accounts:get_all_rejected_suggestions(Uid),
 
    %% Keep only the new ones.
    AllSubtractSet = sets:union(sets:from_list(AllFollowing), sets:from_list(RejectedUids)),
    ContactSuggestionsSet = sets:subtract(ContactUidsSet, AllSubtractSet),
    FoFSuggestions1 = sets:subtract(FoFSet, AllSubtractSet),
    FoFSuggestionsSet = sets:subtract(FoFSuggestions1, ContactSuggestionsSet),
 
    %% Reverse sort ContactSuggestionsSet, FoFSuggestionsSet on number of followers
    ContactSuggestions = get_sorted_uids(Uid, ContactSuggestionsSet),
    FoFSuggestions = get_sorted_uids(Uid, FoFSuggestionsSet),
 
    %% Fetch Profiles
    ContactSuggestedProfiles =
        fetch_suggested_profiles(Uid, ContactSuggestions, direct_contact, 1),
    FoFSuggestedProfiles =
        fetch_suggested_profiles(Uid, FoFSuggestions, fof, length(ContactSuggestions) + 1),
    %% 3. TODO: Find uids that share same campus
    ContactSuggestedProfiles ++ FoFSuggestedProfiles.

get_sorted_uids(Uid, SuggestionsSet) ->
    %% fetch followers count.
    Tuples = lists:foldl(fun(Ouid, Acc) ->
        case model_follow:is_blocked_any(Uid, Ouid) orelse Uid =:= Ouid of
            true -> Acc;
            false -> Acc ++ [{Ouid, model_follow:get_followers_count(Ouid)}]
        end
    end, [], sets:to_list(SuggestionsSet)),
    
    %% Sort and extract uids.
    SortedTuples = lists:sort(fun({_, Cnt1}, {_, Cnt2}) -> Cnt1 =< Cnt2 end, Tuples),
    [Elem || {Elem, _} <- SortedTuples].

fetch_suggested_profiles(Uid, Suggestions, Reason, StartingRank) ->
    Profiles = model_accounts:get_user_profiles(Uid, Suggestions),
    ProfilesWithRank =
        lists:zip(Profiles, lists:seq(StartingRank, StartingRank + length(Profiles) - 1)),
    [#pb_suggested_profile{user_profile = UserProfile, reason = Reason, rank = Rank} ||
        {UserProfile, Rank} <- ProfilesWithRank].
 
