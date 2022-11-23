%%%----------------------------------------------------------------------
%%% File    : mod_contacts.erl
%%%
%%% Copyright (C) 2020 HalloApp Inc.
%%%
%%%----------------------------------------------------------------------

-module(mod_contacts).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("time.hrl").
-include("contacts.hrl").
-include("friend_scoring.hrl").

-ifdef(TEST).
-export([
    hash_syncid_to_bucket/1,
    handle_delta_contacts/3,
    process_iq/1,
    obtain_potential_friends/3
]).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% IQ handlers and hooks.
-export([
    process_local_iq/1, 
    remove_user/2, 
    register_user/4, 
    re_register_user/4,
    block_uids/3,
    unblock_uids/3,
    trigger_full_contact_sync/1,
    notify_friends/3,
    set_full_sync_retry_time/0,
    set_full_sync_error_percent/1,
    set_full_sync_retry_time/1,
    get_full_sync_error_percent/0,
    get_full_sync_retry_time/0,
    normalize_and_insert_contacts/4
]).

-export([
    finish_sync/3
]).

start(Host, _Opts) ->
    ?INFO("start: ~w", [?MODULE]),
    create_contact_options_table(),
    ok = model_contacts:init(),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_contact_list, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 100),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(block_uids, Host, ?MODULE, block_uids, 50),
    ejabberd_hooks:add(unblock_uids, Host, ?MODULE, unblock_uids, 50),
    ok.

stop(Host) ->
    ?INFO("stop: ~w", [?MODULE]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_contact_list),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 100),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(block_uids, Host, ?MODULE, block_uids, 50),
    ejabberd_hooks:delete(unblock_uids, Host, ?MODULE, unblock_uids, 50),
    delete_contact_options_table(),
    ok.

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


set_full_sync_error_percent(SyncErrorPercent)
        when SyncErrorPercent >= 0 andalso SyncErrorPercent =< 100 ->
    true = ets:insert(?CONTACT_OPTIONS_TABLE,
        {sync_error_percent, SyncErrorPercent}),
    ok.


set_full_sync_retry_time() ->
    set_full_sync_retry_time(1 * ?DAYS).

set_full_sync_retry_time(SyncRetryTime) ->
    true = ets:insert(?CONTACT_OPTIONS_TABLE,
        {sync_error_retry_time, SyncRetryTime}),
    ok.


get_full_sync_error_percent() ->
    case lookup_contact_options_table(sync_error_percent) of
        [] -> undefined;
        [{sync_error_percent, SyncErrorPercent}] -> SyncErrorPercent
    end.


get_full_sync_retry_time() ->
    case lookup_contact_options_table(sync_error_retry_time) of
        [] -> undefined;
        [{sync_error_retry_time, SyncRetryTime}] -> SyncRetryTime
    end.


%%====================================================================
%% iq handlers
%%====================================================================


process_local_iq(#pb_iq{from_uid = UserId,
        payload = #pb_contact_list{type = full, sync_id = SyncId}} = IQ) ->
    case check_contact_sync_gate(UserId, SyncId) of
        allow -> process_iq(IQ);
        {deny, RetryAfterSecs} ->
            ?INFO("Uid: ~p, sync_error, retry_after: ~p", [UserId, RetryAfterSecs]),
            pb:make_error(IQ, #pb_contact_sync_error{retry_after_secs = RetryAfterSecs})
    end;
process_local_iq(#pb_iq{payload = #pb_contact_list{type = delta}} = IQ) ->
    %% Dont interrupt delta syncs.
    process_iq(IQ).


process_iq(#pb_iq{from_uid = UserId, type = set, payload = #pb_contact_list{type = full,
        contacts = Contacts, sync_id = SyncId, batch_index = Index, is_last = Last}} = IQ) ->
    Server = util:get_host(),
    StartTime = os:system_time(microsecond), 
    ?INFO("Full contact sync Uid: ~p, sync_id: ~p, batch_index: ~p, is_last: ~p, num_contacts: ~p",
            [UserId, SyncId, Index, Last, length(Contacts)]),
    stat:count("HA/contacts", "sync_full_contacts", length(Contacts)),
    case SyncId of
        undefined ->
            ?WARNING("undefined sync_id, iq: ~p", [IQ]),
            ResultIQ = pb:make_error(IQ, util:err(undefined_syncid));
        _ ->
            {ok, CurrentNumSyncContacts} = model_contacts:count_sync_contacts(UserId, SyncId),
            ReachedMaxLimit = (CurrentNumSyncContacts + length(Contacts)) >= ?MAX_CONTACTS,
            case ReachedMaxLimit of
                true ->
                    ?ERROR("Uid: ~s, has reached max number of contacts to sync", [UserId]),
                    stat:count("HA/contacts", "sync_full_finish_max_limit"),
                    spawn(?MODULE, finish_sync, [UserId, Server, SyncId]),
                    ResultIQ = pb:make_error(IQ, util:err(too_many_contacts));
                false ->
                    count_full_sync(Index),
                    ResultIQ = process_full_sync_iq(IQ)
            end
    end,
    EndTime = os:system_time(microsecond),
    T = EndTime - StartTime,
    ?INFO("Time taken: ~w us", [T]),
    ResultIQ;

process_iq(#pb_iq{from_uid = UserId, type = set,
        payload = #pb_contact_list{type = delta, contacts = Contacts,
            batch_index = _Index, is_last = _Last}} = IQ) ->
    ?INFO("Delta contact sync, Uid: ~p, num_changes: ~p", [UserId, length(Contacts)]),
    Server = util:get_host(),
    pb:make_iq_result(IQ, #pb_contact_list{type = normal,
                    contacts = handle_delta_contacts(UserId, Server, Contacts)}).


process_full_sync_iq(#pb_iq{from_uid = UserId, type = set, payload = #pb_contact_list{type = full,
        contacts = Contacts, sync_id = SyncId, is_last = Last}} = IQ) ->
    Server = util:get_host(),
    ResultIQ = pb:make_iq_result(IQ, #pb_contact_list{sync_id = SyncId, type = normal,
                        contacts = normalize_and_insert_contacts(UserId, Server, Contacts, SyncId)}),
    case Last of
        false -> ok;
        true ->
            stat:count("HA/contacts", "sync_full_finish"),

            case model_contacts:count_sync_contacts(UserId, SyncId) of
                {ok, 0} ->
                    ?INFO("Uid: ~p full sync with empty contacts. Will remove all contacts",
                        [UserId]),
                    stat:count("HA/contacts", "sync_full_finish_empty"),
                    remove_all_contacts(UserId, false);
                {ok, NumSyncContacts} ->
                    stat:count("HA/contacts", "sync_full_contacts_finish", NumSyncContacts),
                    %% Unfinished finish_sync will need the next full sync to send all the relevant
                    %% notifications (some might be sent more than once).
                    spawn(?MODULE, finish_sync, [UserId, Server, SyncId])
            end
    end,
    ResultIQ.


%% TODO(murali@): update remove_user to have phone in the hook arguments.
-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    ?INFO("Uid: ~p", [Uid]),
    {ok, Phone} = model_accounts:get_phone(Uid),
    remove_all_contacts(Uid, true),
    {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
    lists:foreach(
        fun(ContactId) ->
            notify_contact_about_user(<<>>, Phone, ContactId, none, normal, delete_notice)
        end, ContactUids),
    ok.


-spec re_register_user(UserId :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
re_register_user(UserId, _Server, Phone, _CampaignId) ->
    ?INFO("Uid: ~p, Phone: ~p", [UserId, Phone]),
    remove_all_contacts(UserId, false),
    %% Clear first sync status upon re-registration.
    model_accounts:delete_first_sync_status(UserId),
    model_accounts:delete_first_non_empty_sync_status(UserId),
    ok.


%% TODO: Delay notifying the users about their contact to reduce unnecessary messages to clients.
-spec register_user(UserId :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
register_user(UserId, _Server, Phone, _CampaignId) ->
    ?INFO("Uid: ~p, Phone: ~p", [UserId, Phone]),
    %% Disabled logic for contact hashing.
    % {ok, PotentialContactUids} = model_contacts:get_potential_reverse_contact_uids(Phone),
    % lists:foreach(
    %     fun(ContactId) ->
    %         probe_contact_about_user(UserId, Phone, Server, ContactId)
    %     end, PotentialContactUids),

    %% Send notifications to relevant users.
    send_new_user_notifications(UserId, Phone),
    ok.


-spec send_new_user_notifications(UserId :: binary(), UserPhone :: binary()) -> ok.
send_new_user_notifications(UserId, Phone) ->
    {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
    stat:count("HA/contacts", "add_contact", length(ContactUids)),
    %% Fetch all inviter phone numbers.
    {ok, InvitersList} = model_invites:get_inviters_list(Phone),
    InviterUidSet = sets:from_list([InviterUid || {InviterUid, _} <- InvitersList]),

    %% Send only one notification per contact - inviter/contact based.
    lists:foreach(
            fun(ContactId) ->
                case sets:is_element(ContactId, InviterUidSet) of
                    true ->
                        ?INFO("Notify Inviter: ~p about user: ~p joining", [ContactId, UserId]),
                        notify_contact_about_user(UserId, Phone, ContactId, none, normal, inviter_notice);
                    false ->
                        ?INFO("Notify Contact: ~p about user: ~p joining", [ContactId, UserId]),
                        notify_contact_about_user(UserId, Phone, ContactId, none, normal, contact_notice)
                end
            end, ContactUids),
    ok.


-spec block_uids(Uid :: binary(), Server :: binary(), Ouids :: list(binary())) -> ok.
block_uids(Uid, Server, Ouids) ->
    %% TODO(murali@): Add batched api for friends.
    lists:foreach(
        fun(Ouid) ->
            remove_friend(Uid, Server, Ouid)
        end, Ouids),
    ok.


-spec unblock_uids(Uid :: binary(), Server :: binary(), Ouids :: list(binary())) -> ok.
unblock_uids(Uid, Server, Ouids) ->
    {ok, Phone} = model_accounts:get_phone(Uid),
    {ok, ReverseBlockList} = model_privacy:get_blocked_by_uids2(Uid),
    ReverseBlockSet = sets:from_list(ReverseBlockList),
    lists:foreach(
        fun(Ouid) ->
            case model_accounts:get_phone(Ouid) of
                {ok, OPhone} ->
                    %% We now know, that Uid unblocked Ouid.
                    %% So, try and add a friend relationship between Ouid and Uid.
                    %% Ouid and Uid will be friends if both of them have each others as contacts and
                    %% if Ouid did not block Uid.
                    case model_contacts:is_contact(Uid, OPhone) andalso
                            model_contacts:is_contact(Ouid, Phone) andalso
                            not sets:is_element(Ouid, ReverseBlockSet) of
                        true ->
                            WasBlocked = true,
                            add_friend(Uid, Server, Ouid, WasBlocked),
                            notify_contact_about_user(Ouid, OPhone, Uid, friends);
                        false ->
                            ok
                    end;
                {error, missing} -> ok
            end
        end, Ouids),
    ok.


-spec trigger_full_contact_sync(Uid :: binary()) -> ok.
trigger_full_contact_sync(Uid) ->
    Server = util:get_host(),
    ?INFO("Trigger full contact sync for user: ~p", [Uid]),
    send_probe_message(<<>>, <<>>, Uid, Server),
    ok.


%%====================================================================
%% internal functions
%%====================================================================


-spec count_full_sync(Index :: non_neg_integer()) -> ok.
count_full_sync(0) ->
    stat:count("HA/contacts", "sync_full_start"),
    stat:count("HA/contacts", "sync_full_part"),
    ok;
count_full_sync(_Index) ->
    stat:count("HA/contacts", "sync_full_part"),
    ok.


-spec get_phone(UserId :: binary()) -> binary() | undefined.
get_phone(UserId) ->
    case model_accounts:get_phone(UserId) of
        {ok, Phone} -> Phone;
        {error, missing} -> undefined
    end.

-spec handle_delta_contacts(UserId :: binary(), Server :: binary(),
        Contacts :: [pb_contact()]) -> [pb_contact()].
handle_delta_contacts(UserId, Server, Contacts) ->
    {DeleteContactsList, AddContactsList} = lists:partition(
            fun(#pb_contact{action = Action}) ->
                Action =:= delete
            end, Contacts),
    ?INFO("Uid: ~p, NumDeleteContacts: ~p, NumAddContacts: ~p",
            [UserId, length(DeleteContactsList), length(AddContactsList)]),
    DeleteContactPhones = lists:foldl(
            fun(#pb_contact{normalized = undefined}, Acc) ->
                    ?ERROR("Uid: ~s, UserId, sending invalid_contacts", [UserId]),
                    %% Added on 2020-12-11 because of some client bug.
                    %% Clients must be fixing this soon. Check again in 2months.
                    Acc;
                (#pb_contact{normalized = Normalized}, Acc) ->
                    [Normalized | Acc]
            end, [], DeleteContactsList),
    remove_contact_phones(UserId, DeleteContactPhones),
    AddContacts = normalize_and_insert_contacts(UserId, Server, AddContactsList, undefined),
    AddContacts.


-spec remove_all_contacts(UserId :: binary(), IsAccountDeleted :: boolean()) -> ok.
remove_all_contacts(UserId, IsAccountDeleted) ->
    {ok, ContactPhones} = model_contacts:get_contacts(UserId),
    remove_contact_phones(UserId, ContactPhones, IsAccountDeleted).


-spec finish_sync(UserId :: binary(), Server :: binary(), SyncId :: binary()) -> ok.
finish_sync(UserId, _Server, SyncId) ->
    StartTime = os:system_time(microsecond), 
    UserPhone = get_phone(UserId),
    {ok, OldContactList} = model_contacts:get_contacts(UserId),
    {ok, NewContactList} = model_contacts:get_sync_contacts(UserId, SyncId),
    {ok, OldReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    {ok, BlockedUids} = model_privacy:get_blocked_uids2(UserId),
    {ok, BlockedByUids} = model_privacy:get_blocked_by_uids2(UserId),
    {ok, OldFriendUids} = model_friends:get_friends(UserId),
    OldFriendUidSet = sets:from_list(OldFriendUids),
    OldContactSet = sets:from_list(OldContactList),
    NewContactSet = sets:from_list(NewContactList),
    DeleteContactSet = sets:subtract(OldContactSet, NewContactSet),
    AddContactSet = sets:subtract(NewContactSet, OldContactSet),
    OldReverseContactSet = sets:from_list(OldReverseContactList),
    BlockedUidSet = sets:from_list(BlockedUids ++ BlockedByUids),

    NumOldContacts = sets:size(OldContactSet),
    NumNewContacts = sets:size(NewContactSet),
    ?INFO("Full contact sync stats: uid: ~p, old_contacts: ~p, new_contacts: ~p, "
            "add_contacts: ~p, delete_contacts: ~p", [UserId, NumOldContacts,
            NumNewContacts, sets:size(AddContactSet), sets:size(DeleteContactSet)]),
    ?INFO("Full contact sync: uid: ~p, add_contacts: ~p, delete_contacts: ~p",
                [UserId, sets:to_list(AddContactSet), sets:to_list(DeleteContactSet)]),
    stat:count("HA/contacts", "add_contact", sets:size(AddContactSet)),
    remove_contacts_and_notify(UserId, UserPhone,
            sets:to_list(DeleteContactSet), OldReverseContactSet, false),
    %% Convert Phones to pb_contact records.
    AddContacts = lists:map(
            fun(ContactPhone) ->
                #pb_contact{normalized = ContactPhone}
            end, sets:to_list(AddContactSet)),

    %% Obtain UserIds for all the normalized phone numbers.
    {_UnRegisteredContacts, RegisteredContacts} = obtain_user_ids(AddContacts),
    %% Split contacts based on friend relationships for registered contacts.
    {_NonFriendContacts, FriendContacts} = partition_friends(RegisteredContacts,
            OldReverseContactSet, BlockedUidSet),
    add_friends_and_notify(UserId, UserPhone, FriendContacts, OldFriendUidSet),

    %% finish_sync will add various contacts and their reverse mapping in the db.
    case model_contacts:finish_sync(UserId, SyncId) of
        {error, _} = Error ->
            ?ERROR("contact sync failed: ~p Uid: ~p SyncId: ~p", [Error, UserId, SyncId]);
        ok -> ok
    end,

    NumUidContacts = length(RegisteredContacts),
    NumFriendContacts = length(FriendContacts),
    ?INFO("FullSync stats: uid: ~p, NumNewContacts: ~p, NumUidContacts: ~p, NumFriendContacts: ~p",
        [UserId, NumNewContacts, NumUidContacts, NumFriendContacts]),
    stat:count("HA/contacts", "add_contact", length(AddContacts)),
    stat:count("HA/contacts", "add_uid_contact", length(RegisteredContacts)),

    %% Check if any new contacts were uploaded in this sync - if yes - then update sync status.
    %% checking this will help us set this field only for non-empty full contact sync.
    case NewContactList =/= [] of
        true ->
            {ok, Result} = model_accounts:mark_first_non_empty_sync_done(UserId),
            ?INFO("Uid: ~p, mark_first_non_empty_sync_done: ~p", [UserId, Result]);
        false -> ok
    end,

    %% Set status for first sync - could be empty/non-empty!
    {ok, IsFirstSync} = model_accounts:mark_first_sync_done(UserId),
    count_first_syncs(UserId, IsFirstSync, NumNewContacts),
    EndTime = os:system_time(microsecond),
    T = EndTime - StartTime,
    ?INFO("Time taken: ~w us", [T]),
    ok.


count_first_syncs(UserId, IsFirstSync, NumNewContacts) ->
    ?INFO("Uid: ~p, IsFirstSync: ~p, NumNewContacts: ~p", [UserId, IsFirstSync, NumNewContacts]),
    IsEmpty = NumNewContacts =:= 0,
    case IsFirstSync of
        true ->
            stat:count("HA/contacts", "first_contact_sync", 1, [{is_empty, IsEmpty}]);
        false ->
            ok
    end,
    ok.


%%====================================================================
%% add_contact
%%====================================================================


-spec normalize_and_insert_contacts(UserId :: binary(), Server :: binary(),
        Contacts :: [pb_contact()], SyncId :: undefined | binary()) -> [pb_contact()].
normalize_and_insert_contacts(UserId, _Server, [], _SyncId) ->
    ?INFO("Uid: ~p, NumContacts: ~p", [UserId, 0]),
    [];
normalize_and_insert_contacts(UserId, _Server, Contacts, SyncId) ->
    Time1 = os:system_time(microsecond),
    ?INFO("Uid: ~p, NumContacts: ~p", [UserId, length(Contacts)]),
    UserPhone = get_phone(UserId),
    UserRegionId = mod_libphonenumber:get_region_id(UserPhone),
    {ok, OldContactList} = model_contacts:get_contacts(UserId),
    {ok, OldReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    {ok, BlockedUids} = model_privacy:get_blocked_uids2(UserId),
    {ok, BlockedByUids} = model_privacy:get_blocked_by_uids2(UserId),
    {ok, OldFriendUidScores} = model_friends:get_friend_scores(UserId),
    OldFriendUidSet = sets:from_list(maps:keys(OldFriendUidScores)),
    %% TODO(murali@): remove if unused.
    _OldContactSet = sets:from_list(OldContactList),
    OldReverseContactSet = sets:from_list(OldReverseContactList),
    BlockedUidSet = sets:from_list(BlockedUids ++ BlockedByUids),

    %% Firstly, normalize all phone numbers received.
    {UnNormalizedContacts1, NormalizedContacts1} = normalize_contacts(UserId, Contacts, UserRegionId),
    Time2 = os:system_time(microsecond),
    ?INFO("Timetaken:normalize_contacts: ~w us", [Time2 - Time1]),

    %% Obtain UserIds for all the normalized phone numbers.
    {UnRegisteredContacts1, RegisteredContacts1} = obtain_user_ids(NormalizedContacts1),
    Time3 = os:system_time(microsecond),
    ?INFO("Timetaken:obtain_user_ids: ~w us", [Time3 - Time2]),

    %% Obtain potential_friends for unregistered contacts.
    UnRegisteredContacts2 = obtain_potential_friends(UserId, OldFriendUidScores, UnRegisteredContacts1),
    Time4 = os:system_time(microsecond),
    ?INFO("Timetaken:obtain_potential_friends: ~w us", [Time4 - Time3]),

    %% Obtain names for all registered contacts.
    RegisteredContacts2 = obtain_names(RegisteredContacts1),
    Time5 = os:system_time(microsecond),
    ?INFO("Timetaken:obtain_names: ~w us", [Time5 - Time4]),

    %% Split contacts based on friend relationships for registered contacts.
    {NonFriendContacts1, FriendContacts1} = partition_friends(RegisteredContacts2,
            OldReverseContactSet, BlockedUidSet),
    Time6 = os:system_time(microsecond),
    ?INFO("Timetaken:partition_friends_and_notify: ~w us", [Time6 - Time5]),

    %% Obtain avatar_id for all friend contacts.
    FriendContacts2 = obtain_avatar_ids(FriendContacts1),
    Time7 = os:system_time(microsecond),
    ?INFO("Timetaken:obtain_avatar_ids: ~w us", [Time7 - Time6]),

    NormalizedPhoneNumbers = extract_normalized(NormalizedContacts1),
    _UnRegisteredPhoneNumbers = extract_normalized(UnRegisteredContacts2),
    Time8 = os:system_time(microsecond),
    ?INFO("Timetaken:extract_normalized: ~w us", [Time8 - Time7]),

    %% Dont store hashes yet, since we disabled contact hashing.
    %% Call the batched API to insert UserId for the unregistered phone numbers.
    % model_contacts:add_reverse_hash_contacts(UserId, UnRegisteredPhoneNumbers),
    %% Call the batched API to insert the normalized phone numbers.
    %% If it is a delta-sync - undefined syncId, we need to notify contacts,
    %% otherwise, we will notify them at the end in finish_sync(...)
    case SyncId of
        undefined ->
            model_contacts:add_contacts(UserId, NormalizedPhoneNumbers),
            stat:count("HA/contacts", "add_contact", length(NormalizedPhoneNumbers)),
            stat:count("HA/contacts", "add_uid_contact", length(RegisteredContacts1)),
            add_friends_and_notify(UserId, UserPhone, FriendContacts2, OldFriendUidSet);
        _ ->
            model_contacts:sync_contacts(UserId, SyncId, NormalizedPhoneNumbers)
    end,
    Time9 = os:system_time(microsecond),
    ?INFO("Timetaken:sync/add_contacts: ~w us", [Time9 - Time8]),

    ?INFO("Uid: ~p, NumContacts: ~p, NumUidContacts: ~p, NumFriendContacts: ~p",
        [UserId, length(Contacts), length(RegisteredContacts2), length(FriendContacts2)]),

    %% Return all contacts. Includes the following:
    %% - un-normalized phone numbers
    %% - normalized but unregistered contacts
    %% - registered but non-friend contacts
    %% - registered and friend contacts.
    Result = UnNormalizedContacts1 ++ UnRegisteredContacts2 ++ NonFriendContacts1 ++ FriendContacts2,
    Result.


%% Splits contact records to unnormalized and normalized contacts.
%% Sets normalized field for normalized contacts.
-spec normalize_contacts(UserId :: binary(), Contacts :: [pb_contact()],
        UserRegionId :: binary()) -> {[pb_contact()], [pb_contact()]}.
normalize_contacts(UserId, Contacts, UserRegionId) ->
    {ok, NormContacts} = mod_contact_norm:normalize(UserId, Contacts, UserRegionId),
    lists:foldl(
        fun(#pb_contact{normalized = undefined} = Contact, {UnNormAcc, NormAcc}) ->
                {[Contact | UnNormAcc], NormAcc};
            (Contact, {UnNormAcc, NormAcc}) ->
                {UnNormAcc, [Contact | NormAcc]}
        end, {[], []}, NormContacts).


%% Splits normalized contact records to unregistered and registered contacts.
%% Sets userids for registered contacts.
-spec obtain_user_ids(NormContacts :: [pb_contact()]) -> {[pb_contact()], [pb_contact()]}.
obtain_user_ids(NormContacts) ->
    ContactPhones = extract_normalized(NormContacts),
    PhoneUidsMap = model_phone:get_uids(ContactPhones, halloapp),
    lists:foldl(
        fun(#pb_contact{normalized = ContactPhone} = Contact, {UnRegAcc, RegAcc}) ->
            ContactId = maps:get(ContactPhone, PhoneUidsMap, undefined),
            case ContactId of
                undefined ->
                    {[Contact#pb_contact{uid = undefined} | UnRegAcc], RegAcc};
                _ ->
                    {UnRegAcc, [Contact#pb_contact{uid = ContactId} | RegAcc]}
            end
        end, {[], []}, NormContacts).


%% Sets potential friends for un-registered contacts.
-spec obtain_potential_friends(Uid :: binary(), FriendUidScores :: #{binary() => integer()}, UnRegisteredContacts :: [pb_contact()]) -> [pb_contact()].
obtain_potential_friends(_Uid, FriendUidScores, UnRegisteredContacts) ->
    FriendsByScore = lists:sort(
        fun({_Uid1, Score1}, {_Uid2, Score2}) -> 
            Score1 > Score2 
        end, maps:to_list(FriendUidScores)),
    TopFriends = lists:sublist(FriendsByScore, ?CLOSE_FRIENDS_CONSIDERED),
    TopCloseFriends = [FriendUid || {FriendUid, Score} <- TopFriends, Score > ?CLOSE_FRIEND_THRESHOLD],
    {ok, CloseFriendsContacts} =  model_contacts:get_contacts(TopCloseFriends),
    PhoneToNumCloseFriendsMap = lists:foldl(
        fun(Phone, Acc) ->
            maps:update_with(Phone, fun(X) -> X + 1 end, 1, Acc)
        end,
        #{},
        lists:flatten(CloseFriendsContacts)),

    ContactPhones = extract_normalized(UnRegisteredContacts),
    PhoneToInvitersMap = model_invites:get_inviters_list(ContactPhones),
    PhoneToContactsMap = model_contacts:get_contacts_uids_size(ContactPhones),
    lists:map(
        fun(#pb_contact{normalized = ContactPhone} = Contact) ->
            NumInviters = length(maps:get(ContactPhone, PhoneToInvitersMap, [])),
            NumPotentialFriends = maps:get(ContactPhone, PhoneToContactsMap, 0),
            NumCloseFriends = maps:get(ContactPhone, PhoneToNumCloseFriendsMap, 0),
            case NumInviters >= ?MAX_INVITERS of
                %% Dont share potential friends info if the number is already invited by more than MAX_INVITERS.
                true -> Contact;
                %% TODO(murali@): change this when we switch to contact hashing.
                false -> 
                    Contact#pb_contact{num_potential_friends = NumPotentialFriends, num_potential_close_friends = NumCloseFriends}
            end
        end, UnRegisteredContacts).


%% Sets names for all registered contacts.
-spec obtain_names(RegContacts :: [pb_contact()]) -> [pb_contact()].
obtain_names(RegContacts) ->
    ContactIds = extract_uid(RegContacts),
    ContactIdNamesMap = model_accounts:get_names(ContactIds),
    lists:map(
        fun(#pb_contact{uid = ContactId} = Contact) ->
            ContactName = maps:get(ContactId, ContactIdNamesMap, undefined),
            Contact#pb_contact{name = ContactName}
        end, RegContacts).


%% Splits registered contact records to non-friend and friend contacts.
-spec partition_friends(RegContacts :: [pb_contact()], OldReverseContactSet :: sets:set(binary()),
        BlockedUidSet :: sets:set(binary())) -> {[pb_contact()], [pb_contact()]}.
partition_friends(RegContacts, OldReverseContactSet, BlockedUidSet) ->
    {NonFriendContacts, FriendContacts} = lists:foldl(
        fun(#pb_contact{normalized = _ContactPhone, uid = ContactId} = Contact,
                {NonFriendAcc, FriendAcc}) ->
            IsFriends = sets:is_element(ContactId, OldReverseContactSet) andalso
                    not sets:is_element(ContactId, BlockedUidSet),
            %% dont need to notify clients about changes in role-relationship.
            case IsFriends of
                true ->
                    {NonFriendAcc, [Contact | FriendAcc]};
                false ->
                    {[Contact | NonFriendAcc], FriendAcc}
            end
        end, {[], []}, RegContacts),
    {NonFriendContacts, FriendContacts}.


-spec add_friends_and_notify(Uid :: binary(), UserPhone :: binary(), FriendContacts :: [pb_contact()],
        OldFriendUidSet :: sets:set(binary())) -> ok.
add_friends_and_notify(Uid, UserPhone, FriendContacts, OldFriendUidSet) ->
    %% Extract current friends and add only new friends to the database.
    CurrentFriendUids = extract_uid(FriendContacts),
    %% These are the new friends we need to add to the database and let other modules know about it.
    NewFriendUids = lists:filter(
        fun(FriendUid) ->
            not sets:is_element(FriendUid, OldFriendUidSet)
        end, CurrentFriendUids),
    %% Store friend relationships in the database.
    ok = model_friends:add_friends(Uid, NewFriendUids),
    %% Notify new friends and run hooks in a separate process.
    spawn(?MODULE, notify_friends, [Uid, UserPhone, NewFriendUids]),
    ok.


-spec notify_friends(Uid :: binary(), UserPhone :: binary(), NewFriendUids :: [binary()]) -> ok.
notify_friends(Uid, UserPhone, NewFriendUids) ->
    ?INFO("Uid: ~p, Notifying friends: ~p", [Uid, NewFriendUids]),
    Server = util:get_host(),
    %% Run add_friend hook only for NewFriendUids - other modules are interested in only new changes to relationships.
    try
        lists:foreach(
            fun(FriendUid) ->
                notify_contact_about_user(Uid, UserPhone, FriendUid, friends),
                add_friend_hook(Uid, Server, FriendUid, false)
            end, NewFriendUids)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Failed notify_friends Uid: ~p, Stacktrace:~s",
                [Uid, lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    ok.


%% Sets avatar_ids for all registered contacts.
-spec obtain_avatar_ids(FriendContacts :: [pb_contact()]) -> [pb_contact()].
obtain_avatar_ids(FriendContacts) ->
    ContactIds = lists:map(
            fun(#pb_contact{uid = ContactId}) ->
                ContactId
            end, FriendContacts),
    ContactIdAvatarsMap = model_accounts:get_avatar_ids(ContactIds),
    lists:map(
        fun(#pb_contact{uid = ContactId} = Contact) ->
            AvatarId = maps:get(ContactId, ContactIdAvatarsMap, undefined),
            Contact#pb_contact{avatar_id = AvatarId}
        end, FriendContacts).


-spec add_friend(Uid :: binary(), Server :: binary(), Ouid :: binary(), WasBlocked :: boolean()) -> ok.
add_friend(Uid, Server, Ouid, WasBlocked) ->
    ?INFO("~p is friends with ~p", [Uid, Ouid]),
    model_friends:add_friend(Uid, Ouid),
    add_friend_hook(Uid, Server, Ouid, WasBlocked).


-spec add_friend_hook(Uid :: binary(), Server :: binary(), Ouid :: binary(), WasBlocked :: boolean()) -> ok.
add_friend_hook(Uid, Server, Ouid, WasBlocked) ->
    ejabberd_hooks:run(add_friend, Server, [Uid, Server, Ouid, WasBlocked]).


-spec remove_friend(Uid :: binary(), Server :: binary(), Ouid :: binary()) -> ok.
remove_friend(Uid, Server, Ouid) ->
    ?INFO("~p is no longer friends with ~p", [Uid, Ouid]),
    model_friends:remove_friend(Uid, Ouid),
    ejabberd_hooks:run(remove_friend, Server, [Uid, Server, Ouid]).


-spec extract_normalized(Contacts :: [pb_contact()]) -> [binary()].
extract_normalized(Contacts) ->
    lists:map(fun(Contact) -> Contact#pb_contact.normalized end, Contacts).


-spec extract_uid(Contacts :: [pb_contact()]) -> [binary()].
extract_uid(Contacts) ->
    lists:map(fun(Contact) -> Contact#pb_contact.uid end, Contacts).


%%====================================================================
%% delete_contact
%%====================================================================


-spec remove_contact_phones(UserId :: binary(), ContactPhones :: [binary()]) -> ok.
remove_contact_phones(UserId, ContactPhones) ->
    remove_contact_phones(UserId, ContactPhones, false).


-spec remove_contact_phones(
        UserId :: binary(), ContactPhones :: [binary()], IsAccountDeleted :: boolean()) -> ok.
remove_contact_phones(UserId, ContactPhones, IsAccountDeleted) ->
    UserPhone = get_phone(UserId),
    {ok, ReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    ReverseContactSet = sets:from_list(ReverseContactList),
    model_contacts:remove_contacts(UserId, ContactPhones),
    remove_contacts_and_notify(UserId, UserPhone, ContactPhones, ReverseContactSet, IsAccountDeleted).


-spec remove_contacts_and_notify(UserId :: binary(), UserPhone :: binary(),
        ContactPhones :: [binary()], ReverseContactSet :: sets:set(binary()),
        IsAccountDeleted :: boolean()) ->ok.
remove_contacts_and_notify(UserId, UserPhone, ContactPhones, ReverseContactSet, IsAccountDeleted) ->
    lists:foreach(
            fun(ContactPhone) ->
                remove_contact_and_notify(UserId, UserPhone, ContactPhone,
                        ReverseContactSet, IsAccountDeleted)
            end, ContactPhones).


%% Delete all associated info with the contact and the user.
-spec remove_contact_and_notify(UserId :: binary(), UserPhone :: binary(),
        ContactPhone :: binary(), ReverseContactSet :: sets:set(binary()),
        IsAccountDeleted :: boolean()) -> ok.
remove_contact_and_notify(UserId, _UserPhone, ContactPhone, ReverseContactSet, IsAccountDeleted) ->
    Server = util:get_host(),
    {ok, ContactId} = model_phone:get_uid(ContactPhone, halloapp),
    stat:count("HA/contacts", "remove_contact"),
    case ContactId of
        undefined ->
            ok;
        _ ->
            case sets:is_element(ContactId, ReverseContactSet) of
                true ->
                    remove_friend(UserId, Server, ContactId),
                    case IsAccountDeleted of
                        true ->
                            %% dont notify the contact here. we will send a separate notification.
                            ok;
                        false ->
                            %% dont need to notify clients about changes in role-relationship.
                            ok
                    end;
                false -> ok
            end,
            ejabberd_hooks:run(remove_contact, Server, [UserId, Server, ContactId])
    end.


%%====================================================================
%% notify contact
%%====================================================================


%% Notifies contact about the user using the UserId on halloapp.
-spec notify_contact_about_user(UserId :: binary(), UserPhone :: binary(),
        ContactId :: binary(), Role :: atom()) -> ok.
notify_contact_about_user(UserId, _UserPhone, UserId, _Role) ->
    ok;
notify_contact_about_user(UserId, UserPhone, ContactId, Role) ->
    notify_contact_about_user(UserId, UserPhone, ContactId, Role, normal, normal).


-spec notify_contact_about_user(UserId :: binary(), UserPhone :: binary(), ContactId :: binary(),
    Role :: atom(), MessageType :: atom(), ContactListType :: atom()) -> ok.
notify_contact_about_user(UserId, UserPhone, ContactId, Role, MessageType, ContactListType) ->
    notifications_util:send_contact_notification(UserId, UserPhone, ContactId, Role, MessageType, ContactListType).

%% Keep for now.
%%-spec probe_contact_about_user(UserId :: binary(), UserPhone :: binary(),
%%        Server :: binary(), ContactId :: binary()) -> ok.
%%probe_contact_about_user(UserId, UserPhone, Server, ContactId) ->
%%    ?INFO("UserId: ~s, ContactId: ~s", [UserId, ContactId]),
%%    <<HashValue:?PROBE_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, UserPhone),
%%    send_probe_message(UserId, HashValue, ContactId, Server),
%%    ok.


-spec send_probe_message(UserId :: binary(), HashValue :: binary(),
        ContactId :: binary(), Server :: binary()) -> ok.
send_probe_message(UserId, HashValue, ContactId, Server) ->
    Payload = #pb_contact_hash{hash = HashValue},
    Stanza = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = ContactId,
        payload = Payload
    },
    ?DEBUG("Probing contact: ~p about user: ~p using stanza: ~p",
            [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).


%%============================================================================
%% contact_sync_table helper functions
%%============================================================================


-spec check_contact_sync_gate(UserId :: binary(), SyncId :: binary()) -> allow | {deny, integer()}.
check_contact_sync_gate(UserId, SyncId) ->
    case lookup_contact_options_table(sync_error_percent) of
        [] ->
            allow;
        [{sync_error_percent, 0}] ->
            %% No error returned for any iq, process all of them.
            allow;
        [{sync_error_percent, SyncErrorPercent}] ->
            %% return error for SyncErrorPercent of users.
            %% Hash the syncid to a random bucket.
            %% Return error for all buckets with value < SyncErrorPercent
            %% This is nice because, users will receive error responses on all
            %% their full-sync iqs sent in batches. Otherwise, we could run into
            %% cases like where we process half the batch and ignore the rest.

            %% Hash the syncid to a bucket.
            Bucket = hash_syncid_to_bucket(SyncId),
            %% Return error only if the user has already finished their first full contact sync
            %% and if the SyncId falls into the first SyncErrorPercent Buckets.
            case model_accounts:is_first_sync_done(UserId) andalso Bucket < SyncErrorPercent of
                false ->
                    allow;
                true ->
                    ?INFO("Uid: ~p, deny contact_sync, SyncId: ~p", [UserId, SyncId]),
                    JitterValue = random:uniform(?MAX_JITTER_VALUE),
                    %% Calculate the jitter value and add it to the return value.
                    FinalRetryTime = case lookup_contact_options_table(sync_error_retry_time) of
                        [] -> ?DEFAULT_SYNC_RETRY_TIME + JitterValue;
                        [{sync_error_retry_time, SyncRetryTime}] -> SyncRetryTime + JitterValue
                    end,
                    {deny, FinalRetryTime}
            end
    end.


lookup_contact_options_table(Key) ->
    case ets_contact_table_exists() of
        true ->
            ets:lookup(?CONTACT_OPTIONS_TABLE, Key);
        false ->
            []
    end.


%% TODO: move all this to a common keystore table.
%% issue: https://github.com/HalloAppInc/halloapp-ejabberd/issues/2101
ets_contact_table_exists() ->
    case ets:whereis(?CONTACT_OPTIONS_TABLE) of
        undefined -> false;
        _ -> true
    end.


create_contact_options_table() ->
    ?INFO("Creating contact_sync table."),
    try
        ?INFO("Trying to create a table for contact_options in ets", []),
        ets:new(?CONTACT_OPTIONS_TABLE, [set, public, named_table, {read_concurrency, true}]),
        ok
    catch
        Error:badarg ->
            ?WARNING("Failed to create a table for contact_options in ets: ~p", [Error]),
            error
    end,
    ok.


delete_contact_options_table() ->
    case ets_contact_table_exists() of
        true ->
            ets:delete(?CONTACT_OPTIONS_TABLE);
        false ->
            []
    end.


-spec hash_syncid_to_bucket(SyncId :: binary()) -> integer().
hash_syncid_to_bucket(SyncId) ->
    crc16_redis:crc16(util:to_list(SyncId)) rem 100.

