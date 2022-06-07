%%%-------------------------------------------------------------------
%%% File: mod_contact_norm.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module to parallelize normalization of contacts.
%%%
%%%-------------------------------------------------------------------
-module(mod_contact_norm).
-author('murali').

-include("logger.hrl").
-include("packets.hrl").
-include("time.hrl").
-include("proc.hrl").

-define(BATCH_SIZE, 50).

%% API
-export([
    normalize/2,    %% rpc calls execute this function.
    normalize/3     %% main api.
]).

%%====================================================================
%% API
%%====================================================================

-spec normalize(Uid :: binary(), Contacts :: [pb_contact()],
        UserRegionId :: binary()) -> {ok, [pb_contact()]}.
normalize(Uid, [], _RegionId) ->
    ?WARNING("Empty contact lists for Uid: ~p", [Uid]),
    {ok, []};
normalize(Uid, Contacts, RegionId) ->
    normalize_contacts(Uid, Contacts, RegionId).

%%====================================================================
%% api
%%====================================================================

-spec normalize_contacts(Uid :: binary(), Contacts :: [pb_contact()],
        RegionId :: binary()) -> {ok, [pb_contact()]}.
normalize_contacts(Uid, Contacts, RegionId) ->
    ?INFO("Uid: ~p, NumContacts: ~p, RegionId: ~p", [Uid, length(Contacts), RegionId]),
    Batches = split_into_batches(Contacts),
    %% runs the function in parallel on the batches and returns results.
    try util_rpc:pmap({?MODULE, normalize}, [RegionId], Batches) of
        BatchResults ->
             NormalizedContacts = lists:umerge(BatchResults),
            {ok, NormalizedContacts}
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Failed parallel norm Uid: ~p", [Uid]),
            ?ERROR("Stacktrace:~s", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            normalize(Contacts, RegionId)
    end.


-spec normalize(Contacts :: [pb_contact()], RegionId :: binary()) -> [pb_contact()].
normalize(Contacts, RegionId) ->
    NormalizedContacts = lists:map(
        fun (#pb_contact{raw = undefined} = Contact) ->
                ?WARNING("Invalid contact: raw is undefined"),
                Contact#pb_contact{
                    uid = undefined,
                    normalized = undefined};
            (#pb_contact{raw = RawPhone} = Contact) ->
                NormResults = mod_libphonenumber:normalize(RawPhone, RegionId),
                case NormResults of
                    {error, Reason} ->
                        stat:count("HA/contacts", "normalize_fail"),
                        stat:count("HA/contacts", "normalize_fail_reason", 1, [{error, Reason}]),
                        Contact#pb_contact{
                            uid = undefined,
                            normalized = undefined};
                    {ok, ContactPhone} ->
                        stat:count("HA/contacts", "normalize_success"),
                        Contact#pb_contact{normalized = ContactPhone}
                end
        end, Contacts),
    NormalizedContacts.


-spec split_into_batches(Contacts :: [pb_contact()]) -> [[pb_contact()]].
split_into_batches(Contacts) ->
    split_into_batches(Contacts, []).


-spec split_into_batches(Contacts :: [pb_contact()], Acc :: [[pb_contact()]]) -> [[pb_contact()]].
split_into_batches([], Acc) -> Acc;
split_into_batches(Contacts, Acc) ->
    {Contacts1, Contacts2} = case length(Contacts) >= ?BATCH_SIZE of
        true -> lists:split(?BATCH_SIZE, Contacts);
        false -> {Contacts, []}
    end,
    split_into_batches(Contacts2, [Contacts1 | Acc]).


