%%%----------------------------------------------------------------------
%%% File    : mod_libphonenumber.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%----------------------------------------------------------------------

-module(mod_libphonenumber).
-behaviour(gen_mod).

-include("phone_number.hrl").
-include("logger.hrl").

-define(US_REGION_ID, <<"US">>).

%%TODO(murali@): Add unit tests: They require mnesia and access to the resource file.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% api
-export([
    get_cc/1,
    get_region_id/1,
    normalize/2,
    prepend_plus/1,
    normalized_number/2
]).


start(Host, Opts) ->
    phone_number_util:init(Host, Opts),
    ok.

stop(Host) ->
    phone_number_util:close(Host),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


%%====================================================================
%% normalize phone numbers
%%====================================================================

-spec prepend_plus(Phone :: binary()) -> binary().
prepend_plus(RawPhone) ->
    case RawPhone of
        <<"+", _Rest/binary>> ->  RawPhone;
        _ -> <<"+", RawPhone/binary>>
    end.


% returns two letter ISO country code given well formatter phone
-spec get_cc(Phone :: binary()) -> binary().
get_cc(Phone) ->
    get_region_id(Phone).

%% TODO(murali@): ensure these numbers are already in e164 format.
-spec get_region_id(Number :: binary()) -> binary().
get_region_id(Number) ->
    try
        RawIntlNumber = prepend_plus(Number),
        Result = case phone_number_util:parse_phone_number(RawIntlNumber, ?US_REGION_ID) of
                    {ok, PhoneNumberState} ->
                        case PhoneNumberState#phone_number_state.valid of
                            true ->
                                case phone_number_util:get_region_id_for_number(PhoneNumberState) of
                                    {error, _} -> ?US_REGION_ID;
                                    Code -> Code
                                end;
                            false ->
                                ?US_REGION_ID
                        end;
                    _ ->
                        ?US_REGION_ID
                end,
        Result
    catch Class:Reason:Stacktrace ->
        ?INFO("Unable to process number: ~p, error: ~p", [Number,
            lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            % default to US region if there is a failure to process
            ?US_REGION_ID
    end.


-spec normalize(Number :: binary(), RegionId :: binary()) -> {ok, binary()} | {error, atom()}.
normalize(Number, RegionId) ->
    case phone_number_util:parse_phone_number(Number, RegionId) of
        {ok, PhoneNumberState} ->
            case PhoneNumberState#phone_number_state.valid of
                true ->
                    phone_norm:info("success parsed |~s| -> ~p", [Number, PhoneNumberState]),
                    {ok, list_to_binary(PhoneNumberState#phone_number_state.e164_value)};
                _ ->
                    phone_norm:info("Failed parsing |~s|, with reason ~s -> ~p", [Number, PhoneNumberState#phone_number_state.error_msg, PhoneNumberState]),
                    {error, PhoneNumberState#phone_number_state.error_msg}
            end;
        {error, Reason} ->
            case length(phone_number_util:normalize(binary_to_list(Number))) > 5 of
                true -> phone_norm:error("Failed parsing |~s|, with reason: ~s", [Number, Reason]);
                false -> phone_norm:warning("Failed parsing |~s|, with reason: ~s", [Number, Reason])
            end,
            {error, Reason}
    end.


-spec normalized_number(Number :: binary(), RegionId :: binary()) -> binary() | undefined.
normalized_number(Number, RegionId) ->
    NormResult = normalize(Number, RegionId),
    case NormResult of
        {error, _} -> undefined;
        {ok, Phone} -> Phone
    end.

