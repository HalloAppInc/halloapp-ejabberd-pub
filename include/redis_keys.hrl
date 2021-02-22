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
%% store for each phone the last person to invite this phone number and timestamp
-define(INVITES_KEY, <<"inv:">>).
-define(ACTIVE_USERS_ALL_KEY, <<"active_users_all:">>).
-define(ACTIVE_USERS_IOS_KEY, <<"active_users_ios:">>).
-define(ACTIVE_USERS_ANDROID_KEY, <<"active_users_android:">>).
-define(ENGAGED_USERS_ALL_KEY, <<"eu_all:">>).
-define(ENGAGED_USERS_IOS_KEY, <<"eu_ios:">>).
-define(ENGAGED_USERS_ANDROID_KEY, <<"eu_android:">>).
-define(ENGAGED_USERS_POST_KEY, <<"eu_post:">>).
% top level key clv:Android0.90 -> timestamp
-define(CLIENT_VERSION_KEY, <<"clv:">>).
% zset of all client version
-define(CLIENT_VERSION_ALL_KEY, <<"all_client_versions:">>).
-define(VERSION_KEY, <<"v:">>).

%%RedisFeed (model_feed)
-define(POST_KEY, <<"fp:">>).
-define(POST_AUDIENCE_KEY, <<"fpa:">>).
-define(POST_COMMENTS_KEY, <<"fpc:">>).
-define(COMMENT_KEY, <<"fc:">>).
-define(REVERSE_POST_KEY, <<"rfp:">>).
-define(REVERSE_COMMENT_KEY, <<"rfc:">>).
-define(REVERSE_GROUP_POST_KEY, <<"rfg:">>).
-define(COMMENT_PUSH_LIST_KEY, <<"fcp:">>).

%% PrivacyKeys
-define(WHITELIST_KEY, <<"whi:">>).
-define(ONLY_KEY, <<"onl:">>).
-define(BLACKLIST_KEY, <<"bla:">>).
-define(EXCEPT_KEY, <<"exc:">>).
-define(MUTE_KEY, <<"mut:">>).
-define(BLOCK_KEY, <<"blo:">>).
-define(REVERSE_BLOCK_KEY, <<"rbl:">>).

%% RedisAuth
-define(PASSWORD_KEY, <<"pas:">>).
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
-define(MESSAGE_ORDER_KEY, <<"ord:">>).
-define(PUSH_SENT_KEY, <<"psh:">>).

%% RedisPhone
-define(PHONE_KEY, <<"pho:">>).
-define(CODE_KEY, <<"cod:">>).
-define(VERIFICATION_ATTEMPT_LIST_KEY, <<"val:">>).
-define(VERIFICATION_ATTEMPT_ID_KEY, <<"vai:">>).
-define(GATEWAY_RESPONSE_ID_KEY, <<"gri:">>).
-define(INVITED_BY_KEY, <<"inb:">>).
-define(INVITED_BY_KEY_NEW, <<"ibn:">>).
-define(INVITE_NOTIFICATION_KEY, <<"ink:">>).


%% RedisWhisperKeys
-define(WHISPER_KEY, <<"wk:">>).
-define(OTP_KEY, <<"wotp:">>).
-define(SUBSCRIBERS_KEY, <<"wsub:">>).

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

