-module(sms_provider).
-include("ha_types.hrl").

-callback send_sms(Phone :: phone(), Msg :: string()) -> {ok, binary()} | {error, sms_fail}.

-define(sms_provider_probability, [{twilio, 100}, {mbird, 0}]).


%% TODO(vipin)
%% 1. On request_sms for a phone, generate a new SMS code if none is present.
%% 2. Generated code to expire in 1 day.
%% 3. Compute SMS provider to use for sending the SMS based on 'sms_provider_probability'.
%% 4. (Phone, Provider) combination that has been used in the past should not be used again to send
%%    the SMS.
%% 5. Send SMS code generated above using the chosen provider.
%% 6. Track (phone, sms provider).
%% 7. On callback from the provider track (success, cost). Investigative logging to track missing
%%    callback.
%% 8. Client should be able to request_sms on non-receipt of SMS after a certain time decided
%%    by the server.
