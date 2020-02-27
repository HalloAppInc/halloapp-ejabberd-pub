%%%----------------------------------------------------------------------
%%% This file uses phone_number_mnesia to create the mnesia table to hold
%%% all the phonenumber metadata and invokes the parser
%%% to parse the xml file.
%%% We will be adding more relevant functions here to parse a given phone-number,
%%% format it and return the result.
%%% TODO(murali@): Avoid nesting more than 3 levels deep acc. to erlang style guide.
%%%
%%% File    : phone_number_util.erl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%----------------------------------------------------------------------

-module(phone_number_util).

-include("phone_number.hrl").
-include("logger.hrl").

%% API
-export([init/2, close/1, parse_phone_number/2]).

%% debug console functions
-export([create_phone_number_state/1, create_phone_number_state/2, create_phone_number_state/3,
         parse_helper/2, parse_helper_internal/2, maybe_extract_country_code/2,
         maybe_strip_national_prefix_and_carrier_code/2,
         extract_country_code/2, maybe_strip_international_prefix_and_normalize/2,
         format_number_internal/1, is_valid_number_internal/1, is_valid_number_for_region/2,
         get_region_id_for_number/1, get_region_id_for_number_from_regions_list/2,
         is_number_matching_desc/2, match_national_number_pattern/3, normalize/1,
         test_number_length/2, compare_with_national_lengths/2, get_max_length/1,
         get_min_length/1, check_region_for_parsing/2, is_viable_phone_number/1,
         build_national_number_for_parsing/1, extract_possible_number/1]).

-define(MIN_LENGTH_FOR_NSN, 2).
-define(MAX_LENGTH_FOR_NSN, 17).
-define(MAX_LENGTH_COUNTRY_CODE, 3).
-define(MAX_INPUT_STRING_LENGTH, 250).
-define(PLUS_SIGN, "+").
-define(STAR_SIGN, "*").
-define(PLUS_CHARS, "+").
-define(DIGITS, "\\p{Nd}").
-define(UNWANTED_END_CHARS, "[\\P{N}]+$").
-define(SECOND_NUMBER_START_CHARS, "[\\\\/] *x").
-define(EXTENSION_CHARS, " *x").
-define(VALID_PUNCTUATION, "-x ().\\[\\]/\\~").
-define(REGION_CODE_FOR_NON_GEO_ENTITY, "001").


init(_Host, _Opts) ->
    create_libPhoneNumber_table(),
    load_phone_number_metadata().


close(_Host) ->
    ok.


-spec load_phone_number_metadata() -> ok.
load_phone_number_metadata() ->
    FilePhoneNumberMetadata = code:priv_dir(ejabberd) ++ "/xml/" ++ ?FILE_PHONE_NUMBER_METADATA,
    ?INFO_MSG("Parsing this xml file for regionMetadata: ~p", [FilePhoneNumberMetadata]),
    case phone_number_metadata_parser:parse_xml_file(FilePhoneNumberMetadata) of
        {ok, Reason} ->
            ?INFO_MSG("Full libPhoneNumber metadata has been inserted into mnesia: ~p", [Reason]);
        {error, Reason} ->
            ?ERROR_MSG("Failed parsing the xml file for some reason: ~p", [Reason])
    end,
    ok.


%% Creates a table in mnesia to be able to store all the libphonenumber metadata.
-spec create_libPhoneNumber_table() -> ok | error.
create_libPhoneNumber_table() ->
    ?INFO_MSG("Trying to create a table for libPhoneNumber ~p in mnesia.",
                [?LIBPHONENUMBER_METADATA_TABLE]),
    case phone_number_mnesia:init() of
        ok ->
            ?INFO_MSG("Created a table for libPhoneNumber in mnesia.", []);
        _ ->
            ?ERROR_MSG("Failed creating a table for libphonenumber in mnesia", [])
    end.


-spec parse_phone_number(binary(), binary()) -> {ok, #phone_number_state{}} | {error, any()}.
parse_phone_number(PhoneNumber, DefaultRegionId) ->
    Raw = binary_to_list(PhoneNumber),
    PhoneNumberState = #phone_number_state{phone_number = Raw, raw = Raw},
    case parse_helper(PhoneNumberState, DefaultRegionId) of
        {error, Reason} ->
            ?ERROR_MSG("Failed when parsing the number: ~p, with reason: ~p",
                                                        [PhoneNumber, Reason]),
            {error, Reason};
        PhoneNumberState2 ->
            PhoneNumberState3 = is_valid_number_internal(PhoneNumberState2),
            PhoneNumberState4 = format_number_internal(PhoneNumberState3),
            ?INFO_MSG("Finished parsing the number: ~p and obtained the PhoneNumberState: ~p",
                                                        [PhoneNumber, PhoneNumberState4]),
            {ok, PhoneNumberState4}
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Parses a phone_number_state and returns a phone_number_state record filling all the
%% possible details. To do this, it ignores punctuation and white-space, as well as any text
%% before the valid start characters of the number and trims the non-number bits.
%% It will accept a number in any format (E164, national, international etc), assuming it can be
%% interpreted with the defaultRegion supplied. Curently we do not handle any alphabetic
%% characters or extensions.
%% (TODO: murali@): Handle italian leading zeros as well.
-spec parse_helper(#phone_number_state{}, binary()) -> #phone_number_state{} | {error, any()}.
parse_helper(PhoneNumberState, DefaultRegionId) ->
    PhoneNumber = PhoneNumberState#phone_number_state.phone_number,
    if
        length(PhoneNumber) < ?MIN_LENGTH_FOR_NSN orelse
                length(PhoneNumber) > ?MAX_INPUT_STRING_LENGTH ->
            {error, invalid_input};
        true ->
            PossiblePhoneNumber = build_national_number_for_parsing(PhoneNumber),
            case is_viable_phone_number(PossiblePhoneNumber) of
                {error, Res} ->
                    {error, Res};
                {ok, _} ->
                    case check_region_for_parsing(PossiblePhoneNumber, DefaultRegionId) of
                        {error, Res} ->
                            {error, Res};
                        {ok, _} ->
                            case parse_helper_internal(#phone_number_state{
                                        phone_number = PossiblePhoneNumber,
                                        raw = PhoneNumberState#phone_number_state.raw},
                                        DefaultRegionId) of
                                {error, invalid_but_retry} ->
                                    case re:run(PossiblePhoneNumber,
                                            get_plus_characters_pattern_matcher(), [notempty]) of
                                        {match, [{Index, Length} | _Rest]} ->
                                            NewPossiblePhoneNumber =
                                                string:slice(PossiblePhoneNumber, Index+Length),
                                            parse_helper_internal(
                                                #phone_number_state{
                                                    phone_number = NewPossiblePhoneNumber,
                                                    raw = PhoneNumberState#phone_number_state.raw
                                                }, DefaultRegionId);
                                        _ ->
                                            ?DEBUG("parse_helper_internal: final output:
                                                    failed to parse phone number: ~p",[invalid]),
                                            {error, invalid}
                                    end;
                                Result ->
                                    Result
                            end
                    end
            end
    end.


%% Parse helper internal function that extracts the country code and the appropriate
%% national number if possible.
-spec parse_helper_internal(#phone_number_state{}, binary()) ->
                                                    #phone_number_state{} | {error, any()}.
parse_helper_internal(PhoneNumberState, DefaultRegionId) ->
    ?DEBUG("parse_helper_internal: current input:
            PhoneNumberState: ~p, DefaultRegionId: ~p",[PhoneNumberState, DefaultRegionId]),
    PossiblePhoneNumber = PhoneNumberState#phone_number_state.phone_number,
    Raw = PhoneNumberState#phone_number_state.raw,
    case phone_number_mnesia:member(DefaultRegionId) of
        true ->
            %% Currently we are handling only the first RegionMetadata!!
            [RegionMetadata | _] = phone_number_mnesia:lookup(DefaultRegionId);
        _ ->
            RegionMetadata = undefined
    end,
    case maybe_extract_country_code(PhoneNumberState, RegionMetadata) of
        {error, _} ->
            %% strip the plus sign and try again!
            case re:run(PossiblePhoneNumber, get_plus_characters_pattern_matcher(), [notempty]) of
                {match, _} ->
                    NewRegionMetadata = undefined,
                    NormalizedNationalNumber = undefined,
                    CountryCode = undefined,
                    NewCountryCodeSource = undefined;
                _ ->
                    NewRegionMetadata = RegionMetadata,
                    NormalizedNationalNumber = PossiblePhoneNumber,
                    CountryCode = undefined,
                    NewCountryCodeSource = undefined
            end;
        #phone_number_state{country_code = "0"} = PhoneNumberState2 ->
            %% If no extracted country calling code, use the region supplied instead.
            %% The national number is just the normalized version of the number
            %% we were given to parse.
            NewRegionMetadata = RegionMetadata,
            NormalizedNationalNumber = normalize(PhoneNumberState2#phone_number_state.national_number),
            NewCountryCodeSource = PhoneNumberState2#phone_number_state.country_code_source,
            CountryCode = RegionMetadata#region_metadata.attributes#attributes.country_code;
        PhoneNumberState2 ->
            CountryCode = PhoneNumberState2#phone_number_state.country_code,
            NormalizedNationalNumber = PhoneNumberState2#phone_number_state.national_number,
            NewCountryCodeSource = PhoneNumberState2#phone_number_state.country_code_source,
            NewRegionMetadata =
            case phone_number_mnesia:match_object_on_country_code(CountryCode) of
                [Match | _Rest] ->
                    Match;
                _ ->
                    RegionMetadata
            end
    end,
    case NewRegionMetadata of
        undefined ->
            if
                NormalizedNationalNumber == undefined ->
                    ?DEBUG("parse_helper_internal: final output:
                            failed to parse phone number: ~p",[invalid_but_retry]),
                    {error, invalid_but_retry};
                length(NormalizedNationalNumber) >= ?MIN_LENGTH_FOR_NSN andalso
                                length(NormalizedNationalNumber) =< ?MAX_LENGTH_FOR_NSN ->
                    NewPhoneNumberState =
                        #phone_number_state{country_code = CountryCode,
                                            national_number = NormalizedNationalNumber,
                                            phone_number = NormalizedNationalNumber,
                                            raw = Raw,
                                            country_code_source = NewCountryCodeSource
                                            },
                    ?DEBUG("parse_helper_internal: final output:
                            PhoneNumberState: ~p",[NewPhoneNumberState]),
                    NewPhoneNumberState;
                true ->
                    ?DEBUG("parse_helper_internal: final output:
                            failed to parse phone number: ~p",[invalid]),
                    {error, invalid}
            end;
        _ ->
            NewState = maybe_strip_national_prefix_and_carrier_code(
                                                    #phone_number_state{
                                                        country_code = CountryCode,
                                                        national_number = NormalizedNationalNumber,
                                                        phone_number = NormalizedNationalNumber,
                                                        raw = Raw,
                                                        country_code_source = NewCountryCodeSource
                                                    }, NewRegionMetadata),
            PotentialNationalNumber = NewState#phone_number_state.national_number,
            Res = test_number_length(PotentialNationalNumber, NewRegionMetadata),
            if
                Res =/= tooShort andalso Res =/= isPossibleLocalOnly andalso
                                                    Res =/= invalidLength ->
                    ?DEBUG("parse_helper_internal: final output:
                            PhoneNumberState: ~p",[NewState]),
                    NewState;
                true ->
                    if
                        length(NormalizedNationalNumber) >= ?MIN_LENGTH_FOR_NSN andalso
                                    length(NormalizedNationalNumber) =< ?MAX_LENGTH_FOR_NSN ->
                            NewPhoneNumberState =
                                #phone_number_state{country_code = CountryCode,
                                                    national_number = NormalizedNationalNumber,
                                                    phone_number = NormalizedNationalNumber,
                                                    raw = Raw,
                                                    country_code_source = NewCountryCodeSource
                                                    },
                            ?DEBUG("parse_helper_internal: final output:
                            PhoneNumberState: ~p",[NewPhoneNumberState]),
                            NewPhoneNumberState;
                        true ->
                            ?DEBUG("parse_helper_internal: final output:
                                    failed to parse phone number: ~p",[invalid]),
                            {error, invalid}
                    end
            end
    end.


%% Tries to extract a country calling code from a number. This method will return zero if no
%% country calling code is considered to be present. Country calling codes are extracted in the
%% following ways:
%% - by stripping the international dialing prefix of the region the person is dialing from,
%%   if this is present in the number, and looking at the next digits
%% - by stripping the '+' sign if present and then looking at the next digits
%% - by comparing the start of the number and the country calling code of the default region.
-spec maybe_extract_country_code(#phone_number_state{}, #region_metadata{}) ->
                                                        #phone_number_state{} | {error, any()}.
maybe_extract_country_code(PhoneNumberState0, RegionMetadata) ->
    ?DEBUG("maybe_extract_country_code: current input: PhoneNumberState: ~p, RegionMetadata: ~p",
            [PhoneNumberState0, RegionMetadata]),
    PhoneNumber = PhoneNumberState0#phone_number_state.phone_number,
    if
        PhoneNumber == undefined orelse length(PhoneNumber) == 0 ->
            ?DEBUG("maybe_extract_country_code:final output:
                    failed to extract country_code: ~p",[invalid_phone_number]),
            {error, invalid_phone_number};
        true ->
            Attributes = RegionMetadata#region_metadata.attributes,
            InternationalPrefix = Attributes#attributes.international_prefix,
            PhoneNumberState1 = maybe_strip_international_prefix_and_normalize(PhoneNumberState0,
                                    InternationalPrefix),
            CountryCodeSource = PhoneNumberState1#phone_number_state.country_code_source,
            if
                CountryCodeSource =/= fromDefaultCountry ->
                    case length(PhoneNumberState1#phone_number_state.phone_number)
                                =< ?MIN_LENGTH_FOR_NSN of
                        true ->
                            ?DEBUG("maybe_extract_country_code: final output:
                                    failed to extract country_code: ~p",[invalid_phone_number]),
                            {error, invalid_phone_number};
                        false ->
                            PhoneNumberState2 = extract_country_code(PhoneNumberState1, 1),
                            NewCountryCode =
                                PhoneNumberState2#phone_number_state.country_code,
                            if
                                NewCountryCode =/= "0" ->
                                    ?DEBUG("maybe_extract_country_code: final output:
                                        PhoneNumberState: ~p",[PhoneNumberState2]),
                                    PhoneNumberState2;
                                true ->
                                    %% If this fails, they must be using a strange country
                                    %% calling code that we don't recognize,
                                    %% or that doesn't exist.
                                    ?DEBUG("maybe_extract_country_code: final output:
                                        failed to extract country_code: ~p",[invalid_country_code]),
                                    {error, invalid_country_code}
                            end
                    end;
                true ->
                    if
                        RegionMetadata =/= undefined ->
                            PotentialCountryCode = Attributes#attributes.country_code,
                            NewPhoneNumber = PhoneNumberState1#phone_number_state.phone_number,
                            case string:prefix(NewPhoneNumber, PotentialCountryCode) of
                                nomatch ->
                                    NewCountryCode = "0",
                                    NewPhoneNumberState = #phone_number_state {
                                        country_code = NewCountryCode,
                                        national_number =
                                            PhoneNumberState1#phone_number_state.phone_number,
                                        phone_number =
                                            PhoneNumberState1#phone_number_state.phone_number,
                                        raw = PhoneNumberState1#phone_number_state.raw,
                                        country_code_source =
                                            PhoneNumberState1#phone_number_state.country_code_source
                                    },
                                    ?DEBUG("maybe_extract_country_code: final output:
                                        PhoneNumberState: ~p",[NewPhoneNumberState]),
                                    NewPhoneNumberState;
                                PotentialNationalNumber ->
                                    TempPhoneNumberState =
                                        #phone_number_state{
                                            country_code =
                                            PhoneNumberState1#phone_number_state.country_code,
                                            national_number =
                                            PhoneNumberState1#phone_number_state.national_number,
                                            phone_number = PotentialNationalNumber,
                                            raw = PhoneNumberState1#phone_number_state.raw,
                                            country_code_source =
                                            PhoneNumberState1#phone_number_state.country_code_source
                                            },
                                    PhoneNumberState2 =
                                        maybe_strip_national_prefix_and_carrier_code(
                                            TempPhoneNumberState, RegionMetadata),
                                    NewPotentialNationalNumber =
                                        PhoneNumberState2#phone_number_state.national_number,
                                    Res1 = match_national_number_pattern(NewPhoneNumber,
                                                                            RegionMetadata, false),
                                    Res2 = match_national_number_pattern(NewPotentialNationalNumber,
                                                                            RegionMetadata, false),
                                    case (Res1 =/= true andalso Res2 == true) orelse
                                         test_number_length(NewPhoneNumber,
                                                            RegionMetadata) == tooLong of
                                        true ->
                                            NewPhoneNumberState = #phone_number_state {
                                                country_code = PotentialCountryCode,
                                                national_number = NewPotentialNationalNumber,
                                                phone_number =
                                                PhoneNumberState2#phone_number_state.phone_number,
                                                raw = PhoneNumberState2#phone_number_state.raw,
                                                country_code_source = fromNumberWithoutPlusSign
                                            },
                                            ?DEBUG("maybe_extract_country_code: final output:
                                                    PhoneNumberState: ~p",[NewPhoneNumberState]),
                                            NewPhoneNumberState;
                                        false ->
                                            NewCountryCode = "0",
                                            NewPhoneNumberState = #phone_number_state {
                                                country_code = NewCountryCode,
                                                national_number =
                                                PhoneNumberState1#phone_number_state.phone_number,
                                                phone_number =
                                                PhoneNumberState1#phone_number_state.phone_number,
                                                raw = PhoneNumberState1#phone_number_state.raw,
                                                country_code_source =
                                                PhoneNumberState1#phone_number_state.country_code_source
                                            },
                                            ?DEBUG("maybe_extract_country_code: final output:
                                                    PhoneNumberState: ~p",[NewPhoneNumberState]),
                                            NewPhoneNumberState
                                    end
                            end;
                        true ->
                            %% No country code present
                            NewCountryCode = "0",
                            NewPhoneNumberState = #phone_number_state {
                                country_code = NewCountryCode,
                                national_number = PhoneNumberState1#phone_number_state.phone_number,
                                phone_number = PhoneNumberState1#phone_number_state.phone_number,
                                raw = PhoneNumberState1#phone_number_state.raw,
                                country_code_source =
                                    PhoneNumberState1#phone_number_state.country_code_source
                            },
                            ?DEBUG("maybe_extract_country_code: final output:
                                    PhoneNumberState: ~p",[NewPhoneNumberState]),
                            NewPhoneNumberState
                    end
            end
    end.


%% Strips any national prefix (such as 0, 1) present in the #phone_number_state.phone_number
%% provided and returns the updated phone_number_state.
-spec maybe_strip_national_prefix_and_carrier_code(#phone_number_state{}, #region_metadata{}) ->
                                                                        #phone_number_state{}.
maybe_strip_national_prefix_and_carrier_code(PhoneNumberState, RegionMetadata) ->
    ?DEBUG("maybe_strip_national_prefix_and_carrier_code: current input:
            PhoneNumberState: ~p, RegionMetadata: ~p",[PhoneNumberState, RegionMetadata]),
    PotentialNationalNumber = PhoneNumberState#phone_number_state.phone_number,
    Attributes = RegionMetadata#region_metadata.attributes,
    PotentialNationalPrefix = Attributes#attributes.national_prefix_for_parsing,
    case PotentialNationalPrefix of
        undefined ->
            PossibleNationalPrefix = Attributes#attributes.national_prefix;
        _ ->
            PossibleNationalPrefix = PotentialNationalPrefix
    end,
    if
        PotentialNationalNumber == undefined orelse
            length(PotentialNationalNumber) == 0 orelse
                PossibleNationalPrefix == undefined orelse
                    length(PossibleNationalPrefix) == 0 ->
            NewNationalNumber = PotentialNationalNumber;
        true ->
            {ok, Matcher} = re:compile(PossibleNationalPrefix, [caseless]),
            case re:run(PotentialNationalNumber, Matcher, [notempty]) of
                {match, Matches} ->
                    Result0 = match_national_number_pattern(PotentialNationalNumber,
                                                            RegionMetadata, false),
                    TransformRule = Attributes#attributes.national_prefix_transform_rule,
                    if
                        TransformRule == undefined ->
                            case Matches of
                                [{0, Length}| _Rest] ->
                                    NewPotentialNationalNumber =
                                            string:slice(PotentialNationalNumber, Length),
                                    Result1 =
                                        match_national_number_pattern(NewPotentialNationalNumber,
                                                                        RegionMetadata, false),
                                    case Result0 == true andalso Result1 == false of
                                        true ->
                                            NewNationalNumber = PotentialNationalNumber;
                                        false ->
                                            NewNationalNumber = NewPotentialNationalNumber
                                    end;
                                _ ->
                                    NewNationalNumber = PotentialNationalNumber
                            end;
                        true ->
                            case Matches of
                                [{0, Length}] ->
                                    NewNationalNumber = string:slice(PotentialNationalNumber,
                                                                        Length);
                                [{0, Length} | _Rest] ->
                                    %% Handle multiple matches here and test them!!
                                    TransformedPattern = re:replace(TransformRule, "\\$1", "",
                                                                    [global, {return,list}]),
                                    NewPotentialNationalNumber = TransformedPattern ++
                                                            string:slice(PotentialNationalNumber,
                                                                            Length),
                                    Result1 =
                                        match_national_number_pattern(NewPotentialNationalNumber,
                                                                        RegionMetadata, false),
                                    case Result0 of
                                        true ->
                                            case Result1 of
                                                true ->
                                                    NewNationalNumber = NewPotentialNationalNumber;
                                                false ->
                                                    NewNationalNumber = PotentialNationalNumber
                                            end;
                                        false ->
                                            NewNationalNumber = NewPotentialNationalNumber
                                    end;
                                _ ->
                                    NewNationalNumber = PotentialNationalNumber
                            end
                    end;
                _ ->
                    NewNationalNumber = PotentialNationalNumber
            end
    end,
    NewPhoneNumberState = #phone_number_state {
        country_code = PhoneNumberState#phone_number_state.country_code,
        national_number = NewNationalNumber,
        phone_number = PhoneNumberState#phone_number_state.phone_number,
        raw = PhoneNumberState#phone_number_state.raw,
        country_code_source = PhoneNumberState#phone_number_state.country_code_source
    },
    ?DEBUG("maybe_strip_national_prefix_and_carrier_code:
            final output: PhoneNumberState: ~p",[NewPhoneNumberState]),
    NewPhoneNumberState.


%% Extracts country calling code from the given phone_number, returns it and places the
%% remaining number in national_number. It assumes that the leading plus sign or IDD has
%% already been removed. Returns 0 as the country code if phone_number doesn't start with
%% a valid country calling code, and sets national_number to be phone_number's value.
 -spec extract_country_code(#phone_number_state{}, integer()) -> #phone_number_state{}.
extract_country_code(PhoneNumberState, Count) ->
    ?DEBUG("extract_country_code: current input: PhoneNumberState: ~p, Count: ~p",
            [PhoneNumberState, Count]),
    PhoneNumber = PhoneNumberState#phone_number_state.phone_number,
    if
        Count > ?MAX_LENGTH_COUNTRY_CODE ->
            NewPhoneNumberState = #phone_number_state {
                country_code = "0",
                national_number = PhoneNumberState#phone_number_state.phone_number,
                phone_number = PhoneNumberState#phone_number_state.phone_number,
                raw = PhoneNumberState#phone_number_state.raw,
                country_code_source = PhoneNumberState#phone_number_state.country_code_source
            },
            ?DEBUG("extract_country_code: final output: PhoneNumberState: ~p",
                    [NewPhoneNumberState]),
            NewPhoneNumberState;
        true ->
            PotentialCountryCode = string:slice(PhoneNumber, 0, Count),
            Res = phone_number_mnesia:match_object_on_country_code(PotentialCountryCode),
            case Res of
                [_Match | _Rest] ->
                    NewPhoneNumberState = #phone_number_state {
                        country_code = PotentialCountryCode,
                        national_number = string:slice(PhoneNumber, Count),
                        phone_number = PhoneNumberState#phone_number_state.phone_number,
                        raw = PhoneNumberState#phone_number_state.raw,
                        country_code_source =
                            PhoneNumberState#phone_number_state.country_code_source
                    },
                    ?DEBUG("extract_country_code: final output: PhoneNumberState: ~p",
                            [NewPhoneNumberState]),
                    NewPhoneNumberState;
                _ ->
                    extract_country_code(PhoneNumberState, Count + 1)
            end
    end.


%% Strips any international prefix (such as +, 00, 011) present in the number provided, normalizes
%% the resulting number, and returns the phone_number_state with updated phone_number and
%% country_code_source.
-spec maybe_strip_international_prefix_and_normalize(#phone_number_state{}, list()) ->
                                                        #phone_number_state{}.
maybe_strip_international_prefix_and_normalize(PhoneNumberState, InternationalPrefix) ->
    ?DEBUG("maybe_strip_international_prefix_and_normalize: current input:
            PhoneNumberState: ~p, InternationalPrefix: ~p", [PhoneNumberState,
                                                                InternationalPrefix]),
    PhoneNumber0 = PhoneNumberState#phone_number_state.phone_number,
    case re:run(PhoneNumber0, get_plus_characters_pattern_matcher(), [notempty]) of
        {match, [{0, Length} | _Rest]} ->
            PhoneNumber1 = string:slice(PhoneNumber0, Length),
            NewPhoneNumber = normalize(PhoneNumber1),
            NewCountryCodeSource = fromNumberWithPlusSign;
        _ ->
            case InternationalPrefix == undefined orelse length(InternationalPrefix) == 0 of
                true ->
                    NewPhoneNumber = normalize(PhoneNumber0),
                    NewCountryCodeSource = fromDefaultCountry;
                false ->
                    case re:compile(InternationalPrefix, [caseless]) of
                        {error, _} ->
                            NewPhoneNumber = normalize(PhoneNumber0),
                            NewCountryCodeSource = fromDefaultCountry;
                        {ok, Pattern} ->
                            PhoneNumber2 = normalize(PhoneNumber0),
                            case re:run(PhoneNumber2, Pattern, [notempty]) of
                                {match, [{0, Length} | _Rest]} ->
                                    PhoneNumber3 = string:slice(PhoneNumber2, Length),
                                    case PhoneNumber3 of
                                        "0"++_ ->
                                            NewPhoneNumber = PhoneNumber2,
                                            NewCountryCodeSource = fromDefaultCountry;
                                        _ ->
                                            NewPhoneNumber = PhoneNumber3,
                                            NewCountryCodeSource = fromNumberWithIdd
                                    end;
                                _ ->
                                    NewPhoneNumber = PhoneNumber2,
                                    NewCountryCodeSource = fromDefaultCountry
                            end
                    end
            end
    end,
    NewPhoneNumberState = #phone_number_state {
        country_code = PhoneNumberState#phone_number_state.country_code,
        national_number = PhoneNumberState#phone_number_state.national_number,
        phone_number = NewPhoneNumber,
        raw = PhoneNumberState#phone_number_state.raw,
        country_code_source = NewCountryCodeSource
    },
    ?DEBUG("maybe_strip_international_prefix_and_normalize:
            final output: PhoneNumberState: ~p",[NewPhoneNumberState]),
    NewPhoneNumberState.


%% Formats the parsed number using the country code and national number in the following format:
%% e164_value will be 'CountryCode' followed by the national number. We won't be using + here.
-spec format_number_internal(#phone_number_state{}) -> #phone_number_state{}.
format_number_internal(PhoneNumberState) ->
    ?DEBUG("format_number_internal:
            current input: PhoneNumberState: ~p",[PhoneNumberState]),
    CountryCode = PhoneNumberState#phone_number_state.country_code,
    NationalNumber = PhoneNumberState#phone_number_state.national_number,
    case CountryCode of
        undefined ->
            NewPhoneNumberState = PhoneNumberState;
        _ ->
            case NationalNumber of
                undefined ->
                    NewPhoneNumberState = PhoneNumberState;
                _ ->
                    NewPhoneNumberState = PhoneNumberState#phone_number_state{
                                                    e164_value = CountryCode++NationalNumber}
            end
    end,
    ?DEBUG("format_number_internal:
            final output: PhoneNumberState: ~p",[NewPhoneNumberState]),
    NewPhoneNumberState.



%% Tests whether a phone number matches a valid pattern. Note this doesn't verify the number
%% is actually in use, which is impossible to tell by just looking at a number itself. It only
%% verifies whether the parsed, canonicalised number is valid: not whether a particular series of
%% digits entered by the user is diallable from the region provided when parsing.
-spec is_valid_number_internal(#phone_number_state{}) -> #phone_number_state{}.
is_valid_number_internal(PhoneNumberState) ->
    ?DEBUG("is_valid_number_internal:
            current input: PhoneNumberState: ~p",[PhoneNumberState]),
    RegionId = get_region_id_for_number(PhoneNumberState),
    case RegionId of
        {error, _} ->
            NewPhoneNumberState = PhoneNumberState;
        _ ->
            Valid = is_valid_number_for_region(PhoneNumberState, RegionId),
            NewPhoneNumberState = PhoneNumberState#phone_number_state{valid = Valid}
    end,
    ?DEBUG("is_valid_number_internal:
            final output: PhoneNumberState: ~p",[NewPhoneNumberState]),
    NewPhoneNumberState.



%% Tests whether a phone number is valid for a certain region. Note this doesn't verify the number
%% is actually in use, which is impossible to tell by just looking at a number itself. If the
%% country calling code is not the same as the country calling code for the region, this
%% immediately exits with false. After this, the specific number pattern rules for the region are
%% examined. This is useful for determining for example whether a particular number is valid for
%% Canada, rather than just a valid NANPA number.
%% Uses the national number mentioned in the phone_number_state.
-spec is_valid_number_for_region(#phone_number_state{}, binary()) -> boolean().
is_valid_number_for_region(PhoneNumberState, RegionId) ->
    PhoneNumber = PhoneNumberState#phone_number_state.national_number,
    case phone_number_mnesia:lookup(RegionId) of
        [] ->
            false;
        [RegionMetadata | _Rest] ->
            CountryCode = PhoneNumberState#phone_number_state.country_code,
            if
                RegionMetadata == [] orelse CountryCode == undefined orelse
                    (RegionId =/= ?REGION_CODE_FOR_NON_GEO_ENTITY andalso
                        CountryCode =/=
                            RegionMetadata#region_metadata.attributes#attributes.country_code) ->
                                %% Either the region code was invalid, or the country calling code
                                %% for this number does not match that of the region code.
                                false;
                true ->
                    is_number_matching_desc(PhoneNumber, RegionMetadata)
            end
    end.



 %% Returns the region where a phone number is from. This could be used for geocoding at the region
 %% level. Only guarantees correct results for valid, full numbers (not short-codes, or invalid
 %% numbers).
 -spec get_region_id_for_number(#phone_number_state{}) -> binary() | {error, atom()}.
 get_region_id_for_number(PhoneNumberState) ->
    CountryCode = PhoneNumberState#phone_number_state.country_code,
    Matches = phone_number_mnesia:match_object_on_country_code(CountryCode),
    ?DEBUG("get_region_id_for_number: ~p, ~p, ~p", [PhoneNumberState, CountryCode, Matches]),
    case Matches of
        [] ->
            {error, invalid_phone_number1};
        [Match] ->
            Match#region_metadata.id;
        _ ->
            get_region_id_for_number_from_regions_list(PhoneNumberState, Matches)
    end.



%% Returns the region which has the matching leading digits or when the mobile description matches.
%% Uses the national number mentioned in the phone_number_state.
-spec get_region_id_for_number_from_regions_list(#phone_number_state{}, [#region_metadata{}]) ->
                                                    binary() | {error, atom()}.
get_region_id_for_number_from_regions_list(_PhoneNumberState, []) ->
    {error, invalid_phone_number};

get_region_id_for_number_from_regions_list(PhoneNumberState, [RegionMetadata | Rest]) ->
    PhoneNumber = PhoneNumberState#phone_number_state.national_number,
    LeadingDigits = RegionMetadata#region_metadata.attributes#attributes.leading_digits,
    case LeadingDigits of
        undefined ->
            case is_number_matching_desc(PhoneNumber, RegionMetadata) of
                true ->
                    RegionMetadata#region_metadata.id;
                false ->
                    get_region_id_for_number_from_regions_list(PhoneNumberState, Rest)
            end;
        _ ->
            case re:run(PhoneNumber, LeadingDigits, [notempty]) of
                {match, [{0, _} | _Rest]} ->
                    RegionMetadata#region_metadata.id;
                _ ->
                    get_region_id_for_number_from_regions_list(PhoneNumberState, Rest)
            end
    end.



%% Checks if the number is matching the mobile description of the region and returns a boolean.
-spec is_number_matching_desc(list(), #region_metadata{}) -> boolean().
is_number_matching_desc(PhoneNumber, RegionMetadata) ->

    if
        PhoneNumber == undefined orelse length(PhoneNumber) == 0 orelse
            RegionMetadata == undefined ->
                false;
        true ->
            TestLength = test_number_length(PhoneNumber, RegionMetadata),
            case TestLength of
                isPossible ->
                    match_national_number_pattern(PhoneNumber, RegionMetadata, false);
                _ ->
                    false
            end
    end.


%% Matches the phone_number with the pattern in the mobile description and returns true if the
%% regex matches and false otherwise.
%% Returns the default value if the phone_number or RegionMetadata is undefined.
-spec match_national_number_pattern(list(), #region_metadata{}, boolean()) -> boolean().
match_national_number_pattern(PhoneNumber, RegionMetadata, DefaultValue) ->
    if
        PhoneNumber == undefined orelse length(PhoneNumber) == 0 orelse
            RegionMetadata == undefined ->
            DefaultValue;
        true ->
            Mobile = RegionMetadata#region_metadata.mobile,
            case Mobile of
                undefined ->
                    DefaultValue;
                _Else ->
                    Pattern = Mobile#mobile.pattern,
                    {ok, Matcher} = re:compile(Pattern, [caseless]),
                    case re:run(PhoneNumber, Matcher, [notempty]) of
                        {match, [{0, _} | _Rest]}  ->
                            true;
                        _ ->
                            false
                    end
            end
    end.


%% Normalizes a list of characters representing a phone number.
%% This strips punctuation and non-digit characters.
%% Currently we do not handle alpha or any other set of characters.
-spec normalize(list()) -> list().
normalize(PhoneNumber) ->
    re:replace(PhoneNumber, "[^0-9]", "", [global, {return,list}]).


%% Helper method to check a phone_number length against possible lengths for this region,
%% based on the metadata being passed in, and determine whether it matches,
%% or is too short or too long.
-spec test_number_length(list(), #region_metadata{}) -> atom().
test_number_length(PhoneNumber, RegionMetadata) ->
    case RegionMetadata  of
        undefined ->
            invalidLength;
        _ ->
            Mobile = RegionMetadata#region_metadata.mobile,
            case Mobile of
                undefined ->
                    invalidLength;
                _ ->
                    LocalLengths = Mobile#mobile.local_only_lengths,
                    NationalLengths = Mobile#mobile.national_lengths,
                    case NationalLengths of
                        undefined ->
                            invalidLength;
                        _ ->
                            case LocalLengths of
                                undefined ->
                                    compare_with_national_lengths(PhoneNumber, NationalLengths);
                                _ ->
                                    case length(PhoneNumber) >= get_min_length(LocalLengths)
                                            andalso length(PhoneNumber) =<
                                                            get_max_length(LocalLengths) of
                                        true ->
                                            isPossibleLocalOnly;
                                        false ->
                                            compare_with_national_lengths(PhoneNumber,
                                                                            NationalLengths)
                                    end
                            end
                    end
            end
    end.


%% Compares the phone number with the national lengths and returns the relevant atom.
-spec compare_with_national_lengths(list(), list()) -> atom().
compare_with_national_lengths(PhoneNumber, NationalLengths) ->
    case get_min_length(NationalLengths) > length(PhoneNumber) of
        true ->
            tooShort;
        false ->
            case length(PhoneNumber) >= get_min_length(NationalLengths)
                    andalso length(PhoneNumber) =< get_max_length(NationalLengths) of
                true ->
                    isPossible;
                false ->
                    case get_max_length(NationalLengths) < length(PhoneNumber) of
                        true ->
                            tooLong;
                        false ->
                            invalidLength
                    end
            end
    end.


%% Gets the max length from a list indicating the range of lengths possible.
%% Ex: [7-10] should return 10.
%% Accepted forms are: "[7-10]", "7,10",  "7".
-spec get_max_length(list()) -> integer().
get_max_length(PossibleLengths) ->
    case string:find(PossibleLengths, "-") of
        nomatch ->
            case string:find(PossibleLengths, ",") of
                nomatch ->
                    list_to_integer(PossibleLengths);
                _ ->
                    Lengths = string:split(PossibleLengths, ","),
                    list_to_integer(lists:nth(2, Lengths))
            end;
        _ ->
            PossibleLengthString = re:replace(PossibleLengths, "[\\[\\]]",
                                                "", [global, {return,list}]),
            Lengths = string:split(PossibleLengthString, "-"),
            list_to_integer(lists:nth(2, Lengths))
    end.


%% Gets the min length from a list indicating the range of lengths possible.
%% Ex: [7-10] should return 7.
%% Accepted forms are: "[7-10]", "7,10",  "7".
-spec get_min_length(list()) -> integer().
get_min_length(PossibleLengths) ->
    case string:find(PossibleLengths, "-") of
        nomatch ->
            case string:find(PossibleLengths, ",") of
                nomatch ->
                    list_to_integer(PossibleLengths);
                _ ->
                    Lengths = string:split(PossibleLengths, ","),
                    list_to_integer(lists:nth(1, Lengths))
            end;
        _ ->
            PossibleLengthString = re:replace(PossibleLengths, "[\\[\\]]",
                                                "", [global, {return,list}]),
            Lengths = string:split(PossibleLengthString, "-"),
            list_to_integer(lists:nth(1, Lengths))
    end.


%% Checks to see that the region code used is valid, or if it is not valid, that the number to
%% parse starts with a + symbol so that we can attempt to infer the region from the number.
%% Returns false if it cannot use the region provided and the region cannot be inferred.
-spec check_region_for_parsing(list(), binary()) -> {ok, valid_phone_number | valid_region}
                                                    | {error, invalid}.
check_region_for_parsing(PhoneNumber, DefaultRegionId) ->
    case DefaultRegionId == undefined orelse DefaultRegionId == <<"">> orelse
            phone_number_mnesia:member(DefaultRegionId) == false of
        true ->
            case PhoneNumber == undefined orelse PhoneNumber == "" orelse
                    re:run(PhoneNumber, get_plus_characters_pattern_matcher(),
                            [notempty, {capture, none}]) =/= match of
                true ->
                    {error, invalid};
                false ->
                    {ok, valid_phone_number}
            end;
        false ->
            {ok, valid_region}
    end.


%% Checks to see if the string of characters could possibly be a phone number at all. At the
%% moment, checks to see that the string begins with at least 2 digits, ignoring any punctuation
%% commonly found in phone numbers.
%% This method does not require the number to be normalized in advance - but does assume that
%% leading non-number symbols have been removed, such as by the method extract_possible_number().
-spec is_viable_phone_number(list) -> {ok, valid} | {error, too_short | invalid_chars}.
is_viable_phone_number(PhoneNumber) ->
    case length(PhoneNumber) < ?MIN_LENGTH_FOR_NSN of
        true ->
            {error, too_short};
        false ->
            case re:run(PhoneNumber, get_valid_phone_number_pattern_matcher(),
                        [notempty, {capture, none}]) =/= match of
                true ->{error, invalid_chars};
                false ->
                    {ok, valid}
            end
    end.


%% Extracts a possible number out of the given number and returns it.
%% Currently, we do not handle the number if it is written in RFC3966.
-spec build_national_number_for_parsing(list()) -> list().
build_national_number_for_parsing(PhoneNumber) ->
    extract_possible_number(PhoneNumber).


%% Attempts to extract a possible number from the string passed in. This currently strips all
%% leading characters that cannot be used to start a phone number. Characters that can be used to
%% start a phone number are defined using the matcher in get_valid_start_char_pattern_matcher().
%% If none of these characters are found in the number passed in, an empty string is returned.
%% This function also attempts to strip off any alternative extensions or endings if two or more
%% are present, such as in the case of: (530) 583-6985 x302/x2303.
%% The second extension here makes this actually two phone numbers,
%% (530) 583-6985 x302 and (530) 583-6985 x2303. We remove the second extension so that the first
%% number is parsed correctly.
%% Currently, we do not handle extensions, so we strip them off.
-spec extract_possible_number(list()) -> list().
extract_possible_number(PhoneNumber0) ->
    StartIndex =
        case re:run(PhoneNumber0, get_valid_start_char_pattern_matcher(), [notempty]) of
            {match, [{Index0, _} | _Rest0]} ->
                Index0;
            _ ->
                %% Ignore the entire string if no valid start pattern is found.
                length(PhoneNumber0)
        end,
    PhoneNumber1 = string:slice(PhoneNumber0, StartIndex),
    EndIndex =
        case re:run(PhoneNumber1, get_unwanted_end_char_pattern_matcher(), [notempty]) of
            {match, [{Index1, _} | _Rest1]} ->
                Index1;
            _ ->
                length(PhoneNumber1)
        end,
    PhoneNumber2 = string:slice(PhoneNumber1, 0, EndIndex),
    SecondEndIndex =
        case re:run(PhoneNumber2, get_second_number_start_pattern_matcher(), [notempty]) of
            {match, [{Index2, _} | _Rest2]} ->
                Index2;
            _ ->
                length(PhoneNumber2)
        end,
    PhoneNumber3 = string:slice(PhoneNumber2, 0, SecondEndIndex),
    ThirdEndIndex =
        case re:run(PhoneNumber3, get_extension_pattern_matcher(), [notempty]) of
            {match, [{Index3, _} | _Rest3]} ->
                Index3;
            _ ->
                length(PhoneNumber3)
        end,
    PhoneNumber4 = string:slice(PhoneNumber3, 0, ThirdEndIndex),
    PhoneNumber4.


%% Regular expression of acceptable characters that may start a phone number for the purposes of
%% parsing. This allows us to strip away meaningless prefixes to phone numbers that may be
%% mistakenly given to us. This consists of digits and the plus symbol. This
%% does not contain alpha characters, although they may be used later in the number and are
%% handled separately. It also does not include other punctuation, as this will be stripped
%% later during parsing and is of no information value when parsing a number.
-spec get_valid_start_char_pattern_matcher() -> re:mp().
get_valid_start_char_pattern_matcher() ->
    ValidStartChar = "[" ++ ?PLUS_CHARS ++ ?DIGITS ++ "]",
    {ok, Matcher} = re:compile(ValidStartChar),
    Matcher.


%% Regular expression of trailing characters that we want to remove. We remove all characters that
%% are not numerical characters. We also remove the hash character here as we currently do not
%% support phone number extensions.
-spec get_unwanted_end_char_pattern_matcher() -> re:mp().
get_unwanted_end_char_pattern_matcher() ->
    {ok, Matcher} = re:compile(?UNWANTED_END_CHARS, [caseless]),
    Matcher.


%% Regular expression of characters typically used to start a second phone number for the purposes
%% of parsing. This allows us to strip off parts of the number that are actually the start of
%% another number, such as for: (530) 583-6985 x302/x2303 -> the second extension here makes this
%% actually two phone numbers, (530) 583-6985 x302 and (530) 583-6985 x2303. We remove the second
%% extension so that the first number is parsed correctly.
-spec get_second_number_start_pattern_matcher() -> re:mp().
get_second_number_start_pattern_matcher() ->
    {ok, Matcher} = re:compile(?SECOND_NUMBER_START_CHARS, [caseless]),
    Matcher.


%% Regular expression to help us match the extension in the phone number that start with 'x'.
-spec get_extension_pattern_matcher() ->re:mp().
get_extension_pattern_matcher() ->
    {ok, Matcher} = re:compile(?EXTENSION_CHARS, [caseless]),
    Matcher.


%% Regular expression to help us parse the plus characters in the phone number.
-spec get_plus_characters_pattern_matcher() -> re:mp().
get_plus_characters_pattern_matcher() ->
    {ok, Matcher} = re:compile("[" ++ ?PLUS_CHARS ++ "]+", [caseless]),
    Matcher.


%% Regular expression of viable phone numbers. This is location independent. Checks we have at
%% least three leading digits, and only valid punctuation and
%% digits in the phone number. Does not include extension data.
%% The symbol 'x' is allowed here as valid punctuation since it is often used as a placeholder for
%% carrier codes, for example in Brazilian phone numbers. We also allow multiple "+" characters at
%% the start.
%% Corresponds to the following:
%% [digits]{minLengthNsn}|
%% plus_sign*(([punctuation]|[star])*[digits]){3,}([punctuation]|[star]|[digits])*
%%
%% The first reg-ex is to allow short numbers (two digits long) to be parsed if they are entered
%% as "15" etc, but only if there is no punctuation in them. The second expression restricts the
%% number of digits to three or more and also only digits, but then allows them to be in
%% international form, and to have punctuation.
%% We currently do not support extensions or alphabets in the phone number.
-spec get_valid_phone_number_pattern_matcher() -> re:mp().
get_valid_phone_number_pattern_matcher() ->
    ValidPhoneNumber = ?DIGITS ++ "{" ++ integer_to_list(?MIN_LENGTH_FOR_NSN) ++ "}" ++ "|"
                       ++ "[" ++ ?PLUS_CHARS ++ "]*+(?:[" ++ ?VALID_PUNCTUATION ++ ?STAR_SIGN ++
                       "]*" ++ ?DIGITS ++ "){3,}["
                       ++ ?VALID_PUNCTUATION ++ ?STAR_SIGN ++ ?DIGITS ++ "]*",
    {ok, Matcher} = re:compile(ValidPhoneNumber, [caseless]),
    Matcher.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% debug functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

create_phone_number_state(PhoneNumber) ->
    #phone_number_state{phone_number = PhoneNumber}.

create_phone_number_state(NationalNumber, CountryCode) ->
    #phone_number_state{national_number = NationalNumber,
                        country_code = CountryCode}.

create_phone_number_state(PhoneNumber, NationalNumber, CountryCode) ->
    #phone_number_state{phone_number = PhoneNumber,
                        national_number = NationalNumber,
                        country_code = CountryCode}.
