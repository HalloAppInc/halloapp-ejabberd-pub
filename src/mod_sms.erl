%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%% Created : 31. Mar 2020 10:20 AM
%%%-------------------------------------------------------------------
-module(mod_sms).
-author("nikola").
-behavior(gen_mod).

-include("logger.hrl").
-include("sms.hrl").
-include("ha_types.hrl").

-callback send_sms(Phone :: phone(), Msg :: string()) -> {ok, sms_response()} | {error, sms_fail}.

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% API
-export([
    request_sms/2
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w ~p", [?MODULE, self()]),
    ok.

stop(_Host) ->
    ?INFO("stop ~w ~p", [?MODULE, self()]),
    ok.

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

mod_options(_Host) ->
    [].


%%====================================================================
%% API
%%====================================================================

-spec request_sms(Phone :: phone(), UserAgent :: binary()) -> ok.
request_sms(Phone, UserAgent) ->
    OldSMSCode = model_phone:get_sms_code(Phone),
    {Code, AttemptList} = case OldSMSCode of
        {ok, undefined} ->
            %% Generate new SMS code.
            NewSMSCode = generate_code(util:is_test_number(Phone)),
            ?DEBUG("phone:~s generated code:~s", [Phone, NewSMSCode]),
            {NewSMSCode, []};
        {ok, OldCode} ->
            %% Fetch the list of verification attempts.
            {ok, OldVerificationAttempts} = model_phone:get_verification_attempt_list(Phone),
            {OldCode, OldVerificationAttempts}
    end,
    {ok, NewAttempt} = model_phone:add_sms_code2(Phone, Code),
    case util:is_test_number(Phone) of
        true -> ok;
        false ->
            try
                {ok, SMSResponse} = send_sms(Phone, Code, UserAgent, AttemptList),
                model_phone:add_gateway_response(Phone, NewAttempt, SMSResponse)
            catch
                Class : Reason : Stacktrace ->
                    ?ERROR("Unable to send SMS: ~s", [
                            lager:pr_stacktrace(Stacktrace, {Class, Reason})])
            end
     end.

%%====================================================================

-spec send_sms(Phone :: phone(), Code :: binary(), UserAgent :: binary(),
        OldAttemptList :: [binary()]) -> {ok, sms_response()} | no_return().
send_sms(Phone, Code, UserAgent, OldAttemptList) ->
    Msg = prepare_registration_sms(Code, UserAgent),
    ?DEBUG("preparing to send sms, phone:~p msg:~s", [Phone, Msg]),
    case smart_send(Phone, Msg, OldAttemptList) of
        {ok, SMSResponse} ->
            {ok, SMSResponse};
        {error, Error} ->
            %% TODO(vipin): Need to handle error.
            erlang:error(Error)
    end.


-spec prepare_registration_sms(Code :: binary(), UserAgent :: binary()) -> string().
prepare_registration_sms(Code, UserAgent) ->
    AppHash = get_app_hash(UserAgent),
    Msg = io_lib:format("Your HalloApp verification code: ~s~n~n~n~s", [Code, AppHash]),
    Msg.

-spec generate_code(IsDebug :: boolean()) -> binary().
generate_code(true) ->
    <<"111111">>;
generate_code(false) ->
    list_to_binary(io_lib:format("~6..0w", [crypto:rand_uniform(0, 999999)])).


-spec get_app_hash(binary()) -> binary().
get_app_hash(UserAgent) ->
    case {util_ua:is_android_debug(UserAgent), util_ua:is_android(UserAgent)} of
        {true, true} -> ?ANDROID_DEBUG_HASH;
        {false, true} -> ?ANDROID_RELEASE_HASH;
        _ -> <<"">>
    end.

%% TODO(vipin)
%% 1. Compute SMS provider to use for sending the SMS based on 'sms_provider_probability'.
%% 2. (Phone, Provider) combination that has been used in the past should not be used again to send
%%    the SMS.
%% 3. On callback from the provider track (success, cost). Investigative logging to track missing
%%    callback.
%% 4. Client should be able to request_sms on non-receipt of SMS after a certain time decided
%%    by the server.

-define(sms_gateway_probability, [{twilio, 100}, {mbird, 0}]).

-spec smart_send(Phone :: phone(), Msg :: string(), OldAttemptList :: [binary()]) 
        -> {ok, sms_response()} | {error, sms_fail}.
smart_send(Phone, Msg, OldAttemptList) ->
    NewGateway = case length(OldAttemptList) of
        0 -> twilio;
        1 -> mbird;
        _ ->
            %% TODO(vipin): Need to handle better
            twilio
    end,
    Result = NewGateway:send_sms(Phone, Msg),
    ?DEBUG("Result: ~p", [Result]),
    case Result of
        {ok, SMSResponse} -> 
            SMSResponse2 = SMSResponse#sms_response{gateway = NewGateway},
            {ok, SMSResponse2};
        Error -> Error
    end.

