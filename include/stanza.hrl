-include("packets.hrl").

-type stanza() :: iq() | presence() | message() | chat_state() | ack().
