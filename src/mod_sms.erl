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
-include("time.hrl").
-include("translate.hrl").
-include_lib("stdlib/include/assert.hrl").

-callback send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail}.
-callback send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, voice_call_fail}.

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% API
-export([
    request_sms/2,
    request_otp/4,
    verify_sms/2,
    is_too_soon/1,  %% for testing
    good_next_ts_diff/1, %% for testing
    send_otp_internal/6
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w ~p", [?MODULE, self()]),
    ok = twilio:init(),
    ok = mbird:init(),
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

-spec request_sms(Phone :: phone(), UserAgent :: binary()) -> {ok, non_neg_integer()} | {error, term()} | {error, term(), non_neg_integer()}.
request_sms(Phone, UserAgent) ->
    request_otp(Phone, <<"en-US">>, UserAgent, sms).

-spec request_otp(Phone :: phone(), LangId :: binary(), UserAgent :: binary(), Method :: atom()) ->
    {ok, non_neg_integer()} | {error, term()} | {error, term(), non_neg_integer()}.
request_otp(Phone, LangId, UserAgent, Method) ->
    Code = generate_code(util:is_test_number(Phone) andalso not config:is_prod_env()),
    case {config:is_prod_env(), util:is_test_number(Phone)} of
        {true, true} -> send_otp_to_inviter(Phone, LangId, Code, UserAgent, Method);
        {_, _} ->
            case config:is_testing_env() andalso config:get_hallo_env() =/= stress of
                %% avoid next step which is to send the sms
                % TODO: if we allow github env access to the test secrets only we can
                % have our CI test this as well.
                true ->
                    {ok, _NewAttemptId, _Timestamp} = ejabberd_auth:try_enroll(Phone, Code),
                    {ok, 30};
                false -> send_otp(Phone, LangId, Phone, Code, UserAgent, Method)
            end
    end.


-spec verify_sms(Phone :: phone(), Code :: binary()) -> match | nomatch.
verify_sms(Phone, Code) ->
    {ok, AllSMSCodes} = model_phone:get_all_sms_codes(Phone),
    case lists:search(fun({FetchedCode, _}) -> FetchedCode =:= Code end, AllSMSCodes) of
        false -> nomatch;
        {value, {_, AttemptId2}} ->
            model_phone:add_verification_success(Phone, AttemptId2),
            match
    end.

-spec send_otp_to_inviter (Phone :: phone(), LangId :: binary(), Code :: binary(), UserAgent :: binary(), Method ::
    atom()) -> {ok, non_neg_integer()} | {error, term()} | {error, term(), non_neg_integer()}.
send_otp_to_inviter(Phone, LangId, Code, UserAgent, Method)->
    {ok, InvitersList} = model_invites:get_inviters_list(Phone),
    case length(InvitersList) of 
        0 ->
            ?ERROR("No last known inviter of phone: ~p", [Phone]), 
            {error, not_invited};
        _ ->
            {Uid, _} = lists:last(InvitersList),
                case model_accounts:get_phone(Uid) of 
                    {error, missing} = Error -> 
                        ?ERROR("Missing phone of id: ~p", [Uid]),
                        Error;
                    {ok, InviterPhone} -> 
                        case test_users:is_test_uid(Uid) of
                            true -> send_otp(InviterPhone, LangId, Phone, Code, UserAgent, Method);
                            false -> {error, not_invited}
                        end
                end
    end. 

-spec send_otp(OtpPhone :: phone(), LangId :: binary(), Phone :: phone(), Code :: binary(),
        UserAgent :: binary(), Method :: atom()) -> {ok, non_neg_integer()} | {error, term()} |
        {error, term(), non_neg_integer()}.
send_otp(OtpPhone, LangId, Phone, Code, UserAgent, Method) ->
    {ok, OldResponses} = model_phone:get_all_gateway_responses(Phone),
    case is_too_soon(OldResponses) of
        {true, WaitTs} -> {error, retried_too_soon, WaitTs};
        {false, _} ->
            {ok, NewAttemptId, Timestamp} = ejabberd_auth:try_enroll(Phone, Code),
            case mod_sms:send_otp_internal(OtpPhone, LangId, Code, UserAgent, Method, OldResponses) of
                {ok, SMSResponse} ->
                    ?INFO("Response: ~p", [SMSResponse]),
                    model_phone:add_gateway_response(Phone, NewAttemptId, SMSResponse),
                    SMSResponse2 = SMSResponse#gateway_response{
                        attempt_id = NewAttemptId, attempt_ts = Timestamp},
                    AllResponses = OldResponses ++ [SMSResponse2],
                    NextTs = find_next_ts(AllResponses),
                    {ok, NextTs - Timestamp};
                {error, Reason} = Err ->
                    ?ERROR("Unable to send ~p: ~p  OtpPhone: ~p Phone: ~p ",
                        [Method, Reason, Phone, OtpPhone]),
                    Err
            end
    end.


%%====================================================================

-spec is_too_soon(OldResponses :: [gateway_response()]) -> {boolean(), integer()}.
is_too_soon(OldResponses) ->
    NextTs = find_next_ts(OldResponses),
    {NextTs > util:now(), NextTs - util:now()}.


-spec find_next_ts(OldResponses :: [gateway_response()]) -> non_neg_integer().
find_next_ts(OldResponses) ->
    %% Find the last unsuccessful attempts.
    ReverseOldResponses = lists:reverse(OldResponses),
    FailedResponses = lists:takewhile(
        fun(#gateway_response{verified = Success}) ->
            Success =/= true
        end, ReverseOldResponses),
    OldResponses2 = lists:reverse(FailedResponses),
    Len = length(OldResponses2),
    if
        Len == 0 ->
            util:now() - 10;
        true ->
            %% A good amount of time away from the last unsuccessful attempt. Please note this is
            %% approximation of exponential backoff.
            #gateway_response{attempt_ts = LastTs} = lists:nth(Len, OldResponses2),
            good_next_ts_diff(Len) + util:to_integer(LastTs)
    end.


%% 0 -> 30 seconds -> 60 seconds -> 120 seconds -> 240 seconds ...
good_next_ts_diff(NumFailedAttempts) ->
      ?assert(NumFailedAttempts > 0),
      30 * ?SECONDS * trunc(math:pow(2, NumFailedAttempts - 1)).


-spec send_otp_internal(Phone :: phone(), LangId :: binary(), Code :: binary(), UserAgent :: binary(),
    Method :: atom(), OldResponses :: [gateway_response()]) -> {ok, gateway_response()} | {error, term()}.
send_otp_internal(Phone, LangId, Code, UserAgent, Method, OldResponses) ->
    ?DEBUG("preparing to send otp, phone:~p code:~p, LangId: ~p, UserAgent: ~p",
        [Phone, Code, LangId, UserAgent]),
    case smart_send(Phone, Code, LangId, UserAgent, Method, OldResponses) of
        {ok, SMSResponse} ->
            {ok, SMSResponse};
        {error, _Reason} = Err ->
            Err
    end.


-spec generate_code(IsDebug :: boolean()) -> binary().
generate_code(true) ->
    <<"111111">>;
generate_code(false) ->
    list_to_binary(io_lib:format("~6..0w", [crypto:rand_uniform(0, 999999)])).


%% TODO(vipin)
%% On callback from the provider track (success, cost). Investigative logging to track missing
%% callback.

-spec smart_send(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary(), Method :: atom(), OldResponses :: [gateway_response()]) 
        -> {ok, gateway_response()} | {error, sms_fail} | {error, voice_call_fail}.
smart_send(Phone, Code, LangId, UserAgent, Method, OldResponses) ->
    {WorkingList, NotWorkingList} = lists:foldl(
        fun(#gateway_response{gateway = Gateway, method = Method2, status = Status}, {Working, NotWorking})
                when Method2 =:= Method ->
            case Status of
                failed -> {Working, NotWorking ++ [Gateway]};
                undelivered -> {Working, NotWorking ++ [Gateway]};
                unknown -> {Working, NotWorking ++ [Gateway]};
                _ -> {Working ++ [Gateway], NotWorking}
            end;
           (#gateway_response{gateway = _Gateway, method = _Method, status = _Status}, {Working, NotWorking}) ->
               {Working, NotWorking}
        end, {[], []}, OldResponses),
    
    WorkingSet = sets:from_list(WorkingList),
    NotWorkingSet = sets:from_list(NotWorkingList),
    ConsiderList = [twilio, mbird],
    ConsiderSet = sets:from_list(ConsiderList),

    %% Don't want to try using NotWorkingSet.
    GoodSet = sets:subtract(ConsiderSet, NotWorkingSet),

    %% In case we have gateways we have tried that we don't use any more.
    SupportedWorkingSet = sets:intersection(WorkingSet, ConsiderSet),

    %% Need to give preference to GW in GoodSet that is not in WorkingSet.
    TrySet = sets:subtract(GoodSet, SupportedWorkingSet),
    TryList = sets:to_list(TrySet),

    %% To eliminate duplicates.
    WorkingList2 = sets:to_list(SupportedWorkingSet),
    ?DEBUG("Working: ~p", [WorkingList2]),
    ?DEBUG("Not Working: ~p", [NotWorkingList]),
    ?DEBUG("Try: ~p", [TryList]),
    ?DEBUG("Consider: ~p", [ConsiderList]),

    %% If length(TryList) > 0 pick any from TryList, else if length(WorkingListi2) > 0 pick any from
    %% WorkingList2. If both have no elements pick any from ConsiderList.
    ToChooseFromList = case {length(TryList), length(WorkingList2)} of
        {0, 0} -> ConsiderList;  %% None of the GWs we have support for has worked.
        {0, _} -> WorkingList2;  %% We have tried all the GWs. Will try again using what has worked.
        {_, _} -> TryList        %% We will try using GWs we have not tried.
    end,
    ?DEBUG("Choose from: ~p", [ToChooseFromList]),

    %% Pick any.
    ToPick = p1_rand:uniform(1, length(ToChooseFromList)),
    ?DEBUG("Picked: ~p, from: ~p", [ToPick, length(ToChooseFromList)]),
    PickedGateway = lists:nth(ToPick, ToChooseFromList),

    %% Just in case there is any bug in computation of new gateway.
    NewGateway = case sets:is_element(PickedGateway, ConsiderSet) of
        true -> PickedGateway;
        false ->
            ?ERROR("Choosing twilio, Had Picked: ~p, ConsiderList: ~p", [PickedGateway, ConsiderList]),
            twilio
    end,

    %% TODO(vipin): Fix after we have approval via MessageBird.
    NewGateway2 = case mod_libphonenumber:get_cc(Phone) of
        <<"AE">> -> twilio;     %% UAE
        <<"CN">> -> twilio;     %% China
        _ -> NewGateway
    end,
    ?DEBUG("Chosen Gateway: ~p", [NewGateway2]),
    Result = case Method of
        voice_call -> NewGateway2:send_voice_call(Phone, Code, LangId, UserAgent);
        sms -> NewGateway2:send_sms(Phone, Code, LangId, UserAgent)
    end,
    ?DEBUG("Result: ~p", [Result]),
    case Result of
        {ok, SMSResponse} -> 
            SMSResponse2 = SMSResponse#gateway_response{gateway = NewGateway2, method = Method},
            {ok, SMSResponse2};
        Error -> Error
    end.
