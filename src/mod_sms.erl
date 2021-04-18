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

-callback send_sms(Phone :: phone(), Msg :: string()) -> {ok, gateway_response()} | {error, sms_fail}.
-callback send_voice_call(Phone :: phone(), Msg :: string()) -> {ok, gateway_response()} | {error, voice_call_fail}.

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% API
-export([
    request_sms/2,
    request_otp/3,
    verify_sms/2
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

-spec request_sms(Phone :: phone(), UserAgent :: binary()) -> ok | {error, term()}.
request_sms(Phone, UserAgent) ->
    request_otp(Phone, UserAgent, sms).

-spec request_otp(Phone :: phone(), UserAgent :: binary(), Method :: atom()) -> ok | {error, term()}.
request_otp(Phone, UserAgent, Method) ->
    Code = generate_code(util:is_test_number(Phone)),
    {ok, NewAttemptId} = ejabberd_auth:try_enroll(Phone, Code),
    case util:is_test_number(Phone) of
        true -> ok;
        false ->
            {ok, OldResponses} = model_phone:get_all_gateway_responses(Phone),
            case send_otp(Phone, Code, UserAgent, Method, OldResponses) of
                {ok, SMSResponse} ->
                    ?INFO("Response: ~p", [SMSResponse]),
                    model_phone:add_gateway_response(Phone, NewAttemptId, SMSResponse),
                    ok;
                {error, Reason} = Err ->
                    ?ERROR("Unable to send ~p: ~p Phone: ~p", [Method, Reason, Phone]),
                    Err
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


%%====================================================================


-spec send_otp(Phone :: phone(), Code :: binary(), UserAgent :: binary(), Method :: atom(),
        OldResponses :: [gateway_response()]) -> {ok, gateway_response()} | {error, term()}.
send_otp(Phone, Code, UserAgent, Method, OldResponses) ->
    Msg = prepare_registration_sms(Code, UserAgent, Method),
    ?DEBUG("preparing to send otp, phone:~p msg:~s", [Phone, Msg]),
    case smart_send(Phone, Method, Msg, OldResponses) of
        {ok, SMSResponse} ->
            {ok, SMSResponse};
        {error, _Reason} = Err ->
            Err
    end.

%% TODO(vipin): Improve Msg for voice_call. Talk to Dugyu.
-spec prepare_registration_sms(Code :: binary(), UserAgent :: binary(), Method :: atom()) -> string().
prepare_registration_sms(Code, UserAgent, Method) ->
    case Method of
        voice_call ->
            DigitByDigit = string:trim(re:replace(Code,".","& . . ",[global, {return,list}])),
            Msg = io_lib:format("Your HalloApp verification code is ~s . ", [DigitByDigit]),
            io_lib:format("~s ~s ~s ~s", [Msg, Msg, Msg, Msg]);
        sms ->
            AppHash = get_app_hash(UserAgent),
            io_lib:format("Your HalloApp verification code: ~s~n~n~n~s", [Code, AppHash])
    end.
            

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
%% On callback from the provider track (success, cost). Investigative logging to track missing
%% callback.

-spec smart_send(Phone :: phone(), Method :: atom(), Msg :: string(), OldResponses :: [gateway_response()]) 
        -> {ok, gateway_response()} | {error, sms_fail} | {error, voice_call_fail}.
smart_send(Phone, Method, Msg, OldResponses) ->
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
        voice_call -> NewGateway2:send_voice_call(Phone, Msg);
        sms -> NewGateway2:send_sms(Phone, Msg)
    end,
    ?DEBUG("Result: ~p", [Result]),
    case Result of
        {ok, SMSResponse} -> 
            SMSResponse2 = SMSResponse#gateway_response{gateway = NewGateway2, method = Method},
            {ok, SMSResponse2};
        Error -> Error
    end.

