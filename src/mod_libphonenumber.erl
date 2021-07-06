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
%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% api
-export([
    get_cc/1,
    get_region_id/1,
    normalize/2
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

% returns two letter ISO country code given well formatter phone
-spec get_cc(Phone :: binary()) -> binary().
get_cc(Phone) ->
    get_region_id(Phone).

%% TODO(murali@): ensure these numbers are already in e164 format.
-spec get_region_id(Number :: binary()) -> binary().
get_region_id(Number) ->
    RawIntlNumber = case Number of
            <<"+", _Rest/binary>> ->  Number;
            _ -> <<"+", Number/binary>>
        end,
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
    Result.


-spec normalize(Number :: binary(), RegionId :: binary()) -> binary() | undefined.
normalize(Number, RegionId) ->
    Result = parse(Number, RegionId),
    case Result == <<"">> of
        true ->
            undefined;
        false ->
            Result
    end.


-spec parse(Number :: binary(), RegionId :: binary()) -> binary().
parse(Number, RegionId) ->
    case phone_number_util:parse_phone_number(Number, RegionId) of
        {ok, PhoneNumberState} ->
            case PhoneNumberState#phone_number_state.valid of
                true ->
                    ?INFO("success parsed |~s| -> ~p", [Number, PhoneNumberState]),
                    list_to_binary(PhoneNumberState#phone_number_state.e164_value);
                _ ->
                    ?INFO("Failed parsing |~s| -> ~p", [Number, PhoneNumberState]),
                    <<>> % Use empty string as normalized number for now.
            end;
        {error, Reason} ->
            case length(phone_number_util:normalize(binary_to_list(Number))) > 5 of
                true -> ?INFO("Failed parsing |~s|, with reason: ~s", [Number, Reason]);
                false -> ?INFO("Failed parsing |~s|, with reason: ~s", [Number, Reason])
            end,
            <<>> % Use empty string as normalized number for now.
    end.

