%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%% When adding new top level key, make sure it is not used in another
%%% place by searching in this file. This will allow us to run against
%%% single testing redis cluster
%%% @end
%%% Created : 22. May 2020 3:23 PM
%%%-------------------------------------------------------------------
-author("nikola").

-ifndef(REDIS_KEYS_HRL).
-define(REDIS_KEYS_HRL, 1).

%% RedisAccounts (model_accounts)
-define(ACCOUNT_KEY, <<"acc:">>).
-define(DELETED_ACCOUNT_KEY, <<"dac:">>).
-define(DELETED_UID_KEY, <<"du:">>).
-define(SUBSCRIBE_KEY, <<"sub:">>).
-define(BROADCAST_KEY, <<"bro:">>).
-define(COUNT_REGISTRATIONS_KEY, <<"c_reg:">>).
-define(COUNT_ACCOUNTS_KEY, <<"c_acc:">>).
%% set -> {uid}
-define(TRACED_UIDS_KEY, <<"traced_uids:">>).
%% set -> {phone}
-define(TRACED_PHONES_KEY, <<"traced_phones:">>).
%% set -> {uid}
-define(VIDEOCALL_UIDS_KEY, <<"videocall_uids:">>).
%% SortedSet of phone invited by the user: in2:{Uid} -> zset(Phone, Ts)
-define(INVITES2_KEY, <<"in2:">>).
-define(ACTIVE_USERS_ALL_KEY, <<"active_users_all:">>).
-define(ACTIVE_USERS_IOS_KEY, <<"active_users_ios:">>).
-define(ACTIVE_USERS_ANDROID_KEY, <<"active_users_android:">>).
-define(ACTIVE_USERS_CC_KEY, <<"active_users_cc:">>).
-define(ENGAGED_USERS_ALL_KEY, <<"eu_all:">>).
-define(ENGAGED_USERS_IOS_KEY, <<"eu_ios:">>).
-define(ENGAGED_USERS_ANDROID_KEY, <<"eu_android:">>).
-define(ENGAGED_USERS_POST_KEY, <<"eu_post:">>).
-define(CONNECTED_USERS_ALL_KEY, <<"connected_users_all:">>).
% top level key clv:Android0.90 -> timestamp
-define(CLIENT_VERSION_KEY, <<"clv:">>).
% zset of all client version
-define(CLIENT_VERSION_ALL_KEY, <<"all_client_versions:">>).
-define(VERSION_KEY, <<"v:">>).
-define(OS_VERSION_KEY, <<"osv:">>).
-define(LANG_KEY, <<"l:">>).
%% To capture creation of inactive uids and start of their deletion.
-define(INACTIVE_UIDS_GEN_KEY, <<"inactive_uids_gen">>).
-define(INACTIVE_UIDS_DELETION_KEY, <<"inactive_uids_deletion">>).
-define(INACTIVE_UIDS_CHECK_KEY, <<"inactive_uids_check">>).

%% To capture list of Uids that need to be deleted because of inactivity.
-define(TO_DELETE_UIDS_KEY, <<"tdu:">>).

-define(EXPORT_DATA_KEY, <<"eda:">>).

-define(MARKETING_TAG_KEY, <<"mta:">>).

-define(STATIC_KEY_KEY, <<"skk:">>).

-define(REVERSE_STATIC_KEY_KEY, <<"rskk:">>).

% old deleted/deprecated keys
%%-define(INVITES_KEY, <<"inv:">>).


%%RedisFeed (model_feed)
-define(POST_KEY, <<"fp:">>).
-define(POST_AUDIENCE_KEY, <<"fpa:">>).
-define(POST_COMMENTS_KEY, <<"fpc:">>).
-define(COMMENT_KEY, <<"fc:">>).
-define(REVERSE_POST_KEY, <<"rfp:">>).
-define(REVERSE_COMMENT_KEY, <<"rfc:">>).
-define(REVERSE_GROUP_POST_KEY, <<"rfg:">>).
-define(COMMENT_PUSH_LIST_KEY, <<"fcp:">>).
-define(SHARE_POST_KEY, <<"fsp:">>).


%% PrivacyKeys
-define(WHITELIST_KEY, <<"whi:">>).
-define(ONLY_KEY, <<"onl:">>).
-define(BLACKLIST_KEY, <<"bla:">>).
-define(EXCEPT_KEY, <<"exc:">>).
-define(MUTE_KEY, <<"mut:">>).
-define(BLOCK_KEY, <<"blo:">>).
-define(REVERSE_BLOCK_KEY, <<"rbl:">>).

% new keys in privacy cluster.
-define(ONLY_PHONE_KEY, <<"onp:">>).
-define(EXCEPT_PHONE_KEY, <<"exp:">>).
-define(MUTE_PHONE_KEY, <<"mup:">>).
-define(BLOCK_PHONE_KEY, <<"blp:">>).
-define(REVERSE_BLOCK_PHONE_KEY, <<"rbp:">>).
-define(BLOCK_UID_KEY, <<"bli:">>).
-define(REVERSE_BLOCK_UID_KEY, <<"rbi:">>).

%% RedisAuth
%% old deleted/deprecated key
% -define(PASSWORD_KEY, <<"pas:">>).
-define(SPUB_KEY, <<"spb:">>).


%% RedisContacts
-define(CONTACTS_KEY, <<"con:">>).
-define(SYNC_KEY, <<"sync:">>).
-define(PAST_SYNC_KEY, <<"psyn:">>).
-define(REVERSE_KEY, <<"rev:">>).
-define(PHONE_HASH_KEY, <<"rph:">>).
-define(NOT_INVITED_PHONES_KEY, <<"not_invited_phones:">>).


%% RedisAccounts (model_friends)
-define(FRIENDS_KEY, <<"fr:">>).


%% RedisMessages
-define(MESSAGE_KEY, <<"msg:">>).
-define(WITHHOLD_MESSAGE_KEY, <<"wmsg:">>).
-define(MESSAGE_QUEUE_KEY, <<"mq:">>).
-define(MESSAGE_QUEUE_TRIM_KEY, <<"mqt:">>).
-define(MESSAGE_ORDER_KEY, <<"ord:">>).
-define(PUSH_SENT_KEY, <<"psh:">>).

%% RedisPhone
-define(PHONE_KEY, <<"pho:">>).
%% old deleted key
%%-define(CODE_KEY, <<"cod:">>).
-define(VERIFICATION_ATTEMPT_LIST_KEY, <<"val:">>).
-define(VERIFICATION_ATTEMPT_ID_KEY, <<"vai:">>).
-define(INCREMENTAL_TS_KEY, <<"ITS:">>).
-define(GATEWAY_RESPONSE_ID_KEY, <<"gri:">>).
-define(INVITED_BY_KEY, <<"ibn:">>).
-define(INVITE_NOTIFICATION_KEY, <<"ink:">>).
-define(PHONE_PATTERN_KEY, <<"pp:">>).
-define(REMOTE_STATIC_KEY, <<"rs:">>).
-define(PHONE_CC_KEY, <<"pcc:">>).
-define(HASHCASH_KEY, <<"hca:">>).
-define(PHONE_ATTEMPT_KEY, <<"pca:">>).

-define(GW_SCORE_KEY, <<"scr:">>).

-define(IP_KEY, <<"ip:">>).
-define(BLOCK_IP_KEY, <<"bip:">>).

% old deleted/deprecated keys
%%-define(INVITED_BY_KEY_OLD, <<"inb:">>).


%% RedisWhisperKeys
-define(WHISPER_KEY, <<"wk:">>).
-define(OTP_KEY, <<"wotp:">>).
% -define(SUBSCRIBERS_KEY, <<"wsub:">>).
-define(E2E_STATS_QUERY_KEY, <<"e2e_stats">>).


%% RedisGroups
-define(GROUP_KEY, <<"g:">>).
-define(GROUP_MEMBERS_KEY, <<"gm:">>).
-define(USER_GROUPS_KEY, <<"ug:">>).
-define(COUNT_GROUPS_KEY, <<"c_grp:">>).
-define(GROUP_INVITE_LINK_KEY, <<"gi:">>).  % index from group invite to the gid
-define(GROUP_REMOVED_SET_KEY, <<"grs:">>). % gid -> set(uid) of user removed from the group


%% RedisSessions
-define(PID_KEY, <<"p:">>).
-define(SESSIONS_KEY, <<"ss:">>).

-define(STATIC_KEY_SESSIONS_KEY, <<"sks:">>).

% cluster key store in RedisSessions
-define(CLUSTER_KEY, <<"cluster_nodes:">>).

-endif.
