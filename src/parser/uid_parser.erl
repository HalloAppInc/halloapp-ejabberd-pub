-module(uid_parser).

-include("packets.hrl").
-include("xmpp.hrl").

-export([
    translate_to_xmpp_uid/1,
    translate_to_pb_uid/1
]).


%% temporary change.
%% TODO(murali@): will update the compiler to be able do this directly for uid related fields.
translate_to_xmpp_uid(#pb_name{uid = Uid} = PbName) ->
    PbName#pb_name{uid = util_parser:proto_to_xmpp_uid(Uid)};

translate_to_xmpp_uid(#pb_uid_element{uid = Uid} = UidEl) ->
    UidEl#pb_uid_element{uid = util_parser:proto_to_xmpp_uid(Uid)};

translate_to_xmpp_uid(#pb_privacy_list{uid_elements = UidEls} = PbPrivacyList) ->
    NewUidEls = lists:map(fun translate_to_xmpp_uid/1, UidEls),
    PbPrivacyList#pb_privacy_list{uid_elements = NewUidEls};

translate_to_xmpp_uid(#pb_privacy_lists{lists = PrivacyLists} = PbPrivacyLists) ->
    NewLists = lists:map(fun translate_to_xmpp_uid/1, PrivacyLists),
    PbPrivacyLists#pb_privacy_lists{lists = NewLists};

translate_to_xmpp_uid(#pb_avatar{uid = Uid} = PbAvatar) ->
    PbAvatar#pb_avatar{uid = util_parser:proto_to_xmpp_uid(Uid)};

translate_to_xmpp_uid(#pb_avatars{avatars = Avatars} = PbAvatars) ->
    NewAvatars = lists:map(fun translate_to_xmpp_uid/1, Avatars),
    PbAvatars#pb_avatars{avatars = NewAvatars};

translate_to_xmpp_uid(#pb_whisper_keys{uid = Uid} = PbWhisperKeys) ->
    PbWhisperKeys#pb_whisper_keys{uid = util_parser:proto_to_xmpp_uid(Uid)};

translate_to_xmpp_uid(#pb_audience{uids = Uids} = PbAudience) ->
    NewUids = lists:map(fun util_parser:proto_to_xmpp_uid/1, Uids),
    PbAudience#pb_audience{uids = NewUids};

translate_to_xmpp_uid(#pb_post{audience = PbAudience, publisher_uid = Uid} = PbPost) ->
    PbPost#pb_post{
        audience = translate_to_xmpp_uid(PbAudience),
        publisher_uid = util_parser:proto_to_xmpp_uid(Uid)
    };

translate_to_xmpp_uid(#pb_comment{publisher_uid = Uid} = PbComment) ->
    PbComment#pb_comment{publisher_uid = util_parser:proto_to_xmpp_uid(Uid)};

translate_to_xmpp_uid(#pb_feed_item{item = Item} = PbFeedItem) when Item =/= undefined ->
    PbFeedItem#pb_feed_item{item = translate_to_xmpp_uid(Item)};

translate_to_xmpp_uid(#pb_share_stanza{uid = Uid} = PbShareStanza) ->
    PbShareStanza#pb_share_stanza{uid = util_parser:proto_to_xmpp_uid(Uid)};

translate_to_xmpp_uid(#pb_feed_item{share_stanzas = ShareStanzas} = PbFeedItem) ->
    NewShareStanzas = lists:map(fun translate_to_xmpp_uid/1, ShareStanzas),
    PbFeedItem#pb_feed_item{share_stanzas = NewShareStanzas};

translate_to_xmpp_uid(#pb_contact{uid = Uid} = PbContact) ->
	PbContact#pb_contact{uid = util_parser:proto_to_xmpp_uid(Uid)};

translate_to_xmpp_uid(#pb_contact_list{contacts = Contacts} = PbContactList) ->
	NewContacts = lists:map(fun translate_to_xmpp_uid/1, Contacts),
	PbContactList#pb_contact_list{contacts = NewContacts};

translate_to_xmpp_uid(#pb_group_feed_item{item = Item} = PbFeedItem) ->
    PbFeedItem#pb_group_feed_item{item = translate_to_xmpp_uid(Item)};

translate_to_xmpp_uid(#pb_post{publisher_uid = Uid, audience = Audience} = PbPost) ->
    PbPost#pb_post{
        publisher_uid = util_parser:proto_to_xmpp_uid(Uid),
        audience = translate_to_xmpp_uid(Audience)};

translate_to_xmpp_uid(#pb_comment{publisher_uid = Uid} = PbPost) ->
    PbPost#pb_post{publisher_uid = util_parser:proto_to_xmpp_uid(Uid)};

translate_to_xmpp_uid(#pb_audience{uids = Uids} = PbAudience) ->
    PbAudience#pb_audience{uids = lists:map(fun translate_to_xmpp_uid/1, Uids)};

translate_to_xmpp_uid(#pb_group_stanza{sender_uid = Uid, members = Members} = PbGroup) ->
    PbGroup#pb_group_stanza{
        sender_uid = util_parser:proto_to_xmpp_uid(Uid),
        members = [translate_to_xmpp_uid(M) || M <- Members]
    };

translate_to_xmpp_uid(#pb_group_member{uid = Uid} = GM) ->
    GM#pb_group_member{uid = util_parser:proto_to_xmpp_uid(Uid)};

translate_to_xmpp_uid(#pb_groups_stanza{group_stanzas = Groups} = GS) ->
    GS#pb_groups_stanza{group_stanzas = [translate_to_xmpp_uid(G) || G <- Groups]};

translate_to_xmpp_uid(PbElement) ->
    PbElement.


translate_to_pb_uid(#pb_avatar{uid = Uid} = PbAvatar) ->
    PbAvatar#pb_avatar{uid = util_parser:xmpp_to_proto_uid(Uid)};

translate_to_pb_uid(#pb_avatars{avatars = Avatars} = PbAvatars) ->
    NewAvatars = lists:map(fun translate_to_pb_uid/1, Avatars),
    PbAvatars#pb_avatars{avatars = NewAvatars};

translate_to_pb_uid(#pb_uid_element{uid = Uid} = UidEl) ->
    UidEl#pb_uid_element{uid = util_parser:xmpp_to_proto_uid(Uid)};

translate_to_pb_uid(#pb_privacy_list{uid_elements = UidEls} = PbPrivacyList) ->
    NewUidEls = lists:map(fun translate_to_pb_uid/1, UidEls),
    PbPrivacyList#pb_privacy_list{uid_elements = NewUidEls};

translate_to_pb_uid(#pb_privacy_lists{lists = PrivacyLists} = PbPrivacyLists) ->
    NewLists = lists:map(fun translate_to_pb_uid/1, PrivacyLists),
    PbPrivacyLists#pb_privacy_lists{lists = NewLists};

translate_to_pb_uid(#pb_whisper_keys{uid = Uid} = PbWhisperKeys) ->
    PbWhisperKeys#pb_whisper_keys{uid = util_parser:xmpp_to_proto_uid(Uid)};

translate_to_pb_uid(#pb_audience{uids = Uids} = PbAudience) ->
    NewUids = lists:map(fun util_parser:xmpp_to_proto_uid/1, Uids),
    PbAudience#pb_audience{uids = NewUids};

translate_to_pb_uid(#pb_post{audience = PbAudience, publisher_uid = Uid} = PbPost) ->
    PbPost#pb_post{
        audience = translate_to_pb_uid(PbAudience),
        publisher_uid = util_parser:xmpp_to_proto_uid(Uid)
    };

translate_to_pb_uid(#pb_comment{publisher_uid = Uid} = PbComment) ->
    PbComment#pb_comment{publisher_uid = util_parser:xmpp_to_proto_uid(Uid)};

translate_to_pb_uid(#pb_feed_item{item = Item} = PbFeedItem) when Item =/= undefined ->
    PbFeedItem#pb_feed_item{item = translate_to_pb_uid(Item)};

translate_to_pb_uid(#pb_share_stanza{uid = Uid} = PbShareStanza) ->
    PbShareStanza#pb_share_stanza{uid = util_parser:xmpp_to_proto_uid(Uid)};

translate_to_pb_uid(#pb_feed_item{share_stanzas = ShareStanzas} = PbFeedItem) ->
    NewShareStanzas = lists:map(fun translate_to_pb_uid/1, ShareStanzas),
    PbFeedItem#pb_feed_item{share_stanzas = NewShareStanzas};

translate_to_pb_uid(#pb_contact{uid = Uid} = PbContact) ->
	PbContact#pb_contact{uid = util_parser:xmpp_to_proto_uid(Uid)};

translate_to_pb_uid(#pb_contact_list{contacts = Contacts} = PbContactList) ->
	NewContacts = lists:map(fun translate_to_pb_uid/1, Contacts),
	PbContactList#pb_contact_list{contacts = NewContacts};

translate_to_pb_uid(#pb_group_feed_item{item = Item} = PbFeedItem) ->
    PbFeedItem#pb_group_feed_item{item = translate_to_pb_uid(Item)};

translate_to_pb_uid(#pb_post{publisher_uid = Uid, audience = Audience} = PbPost) ->
    PbPost#pb_post{
        publisher_uid = util_parser:xmpp_to_proto_uid(Uid),
        audience = translate_to_pb_uid(Audience)};

translate_to_pb_uid(#pb_comment{publisher_uid = Uid} = PbPost) ->
    PbPost#pb_post{publisher_uid = util_parser:xmpp_to_proto_uid(Uid)};

translate_to_pb_uid(#pb_audience{uids = Uids} = PbAudience) ->
    PbAudience#pb_audience{uids = lists:map(fun translate_to_pb_uid/1, Uids)};

translate_to_pb_uid(#pb_group_stanza{sender_uid = Uid, members = Members} = PbGroup) ->
    PbGroup#pb_group_stanza{
        sender_uid = util_parser:xmpp_to_proto_uid(Uid),
        members = [translate_to_pb_uid(M) || M <- Members]
    };

translate_to_pb_uid(#pb_group_member{uid = Uid} = GM) ->
    GM#pb_group_member{uid = util_parser:xmpp_to_proto_uid(Uid)};

translate_to_pb_uid(#pb_groups_stanza{group_stanzas = Groups} = GS) ->
    GS#pb_groups_stanza{group_stanzas = [translate_to_pb_uid(G) || G <- Groups]};

translate_to_pb_uid(PbElement) ->
    PbElement.

