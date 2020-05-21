%%%----------------------------------------------------------------------------
%%% Records for message_items used in modules related to push notifications.
%%%
%%%----------------------------------------------------------------------------

-include("account.hrl").

-type sslsocket() :: ssl:socket().

-record(push_message_item, {
	id :: binary(),
	uid :: binary(),
	message :: message(),
	timestamp :: integer(),
	retry_ms :: integer(),
	push_info :: push_info()
}).

-type push_message_item() :: #push_message_item{}.

%% TODO(murali@): Store this pending/retry list info in ets tables/redis and keep the state simple.
-record(push_state, {
	pendingList :: [#push_message_item{}],
	host :: binary(),
	socket :: sslsocket(),
	dev_socket :: sslsocket()
}).

-type push_state() :: #push_state{}.


-define(GOLDEN_RATIO, 1.618).
