-module(uid_parser).

-include("packets.hrl").
-include("xmpp.hrl").

-export([
    translate_uid/1
]).


%% temporary change.
%% TODO(murali@): will update the compiler to be able do this directly for uid related fields.
translate_uid(#pb_name{uid = Uid} = PbName) ->
    PbName#pb_name{uid = util_parser:proto_to_xmpp_uid(Uid)};
translate_uid(PbElement) ->
    PbElement.

