%%%----------------------------------------------------------------------
%%% This file creates the ets table to hold all the phonenumber metadata and invokes the parser
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

-export([init/2, close/1]).
%% Temporary for testing purposes: TODO(murali@): remove it soon!
-compile(export_all).

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
            ?INFO_MSG("Full libPhoneNumber metadata has been inserted into ets: ~p", [Reason]);
        {error, Reason} ->
            ?ERROR_MSG("Failed parsing the xml file for some reason: ~p", [Reason])
    end,
    ok.


%% Creates an in-memory table using ets to be able to store all the libphonenumber metadata.
-spec create_libPhoneNumber_table() -> ok | error.
create_libPhoneNumber_table() ->
    try
        ?INFO_MSG("Trying to create a table for libPhoneNumber ~p",
                    [?LIBPHONENUMBER_METADATA_TABLE]),
        ets:new(?LIBPHONENUMBER_METADATA_TABLE,
                [named_table, public, bag, {keypos, 2},
                {write_concurrency, true}, {read_concurrency, true}]),
        ok
    catch
        _:badarg -> 
            ?INFO_MSG("Failed to create a table for libPhoneNumber: ~p",
                        [?LIBPHONENUMBER_METADATA_TABLE]),
            error
    end.


%% TODO(murali@): Add the remaining functions here!!


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%% Strips any national prefix (such as 0, 1) present in the #phone_number_state.phone_number
%% provided and returns the updated phone_number_state.
-spec maybe_strip_national_prefix_and_carrier_code(#phone_number_state{}, #region_metadata{}) ->
                                                                        #phone_number_state{}.
maybe_strip_national_prefix_and_carrier_code(PhoneNumberState, RegionMetadata) ->
    ?DEBUG("maybe_strip_national_prefix_and_carrier_code: current input:
            PhoneNumberState: ~p, RegionMetadata: ~p",[PhoneNumberState, RegionMetadata]),
    PotentialNationalNumber = PhoneNumberState#phone_number_state.phone_number,
    Attributes = RegionMetadata#region_metadata.attributes,
    PossibleNationalPrefix = Attributes#attributes.national_prefix_for_parsing,
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
                            [{Index, Length} | _Rest] = Matches,
                            NewNationalNumber = string:slice(PotentialNationalNumber,
                                                                        Index+Length);
                        true ->
                            case Matches of
                                [{Index, Length}] ->
                                    NewNationalNumber = string:slice(PotentialNationalNumber,
                                                                        Index+Length);
                                [{Index, Length} | _Rest] ->
                                    %% Handle multiple matches here and test them!!
                                    TransformedPattern = re:replace(TransformRule, "\\$1", "",
                                                                    [global, {return,list}]),
                                    NewPotentialNationalNumber = TransformedPattern ++
                                                            string:slice(PotentialNationalNumber,
                                                                            Index+Length),
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
                                    end
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
            Res = ets:match(?LIBPHONENUMBER_METADATA_TABLE,
                            #region_metadata{attributes =
                            #attributes{country_code = PotentialCountryCode, _='_'}, _='_'}),
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
        {match, [{Index, Length} | _Rest]} ->
            PhoneNumber1 = string:slice(PhoneNumber0, Index+Length),
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
                                {match, [{Index, Length} | _Rest]} ->
                                    PhoneNumber3 = string:slice(PhoneNumber2, Index+Length),
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
                        {match, _}  ->
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
            ets:member(?LIBPHONENUMBER_METADATA_TABLE, DefaultRegionId) == false of
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
            {match, [{Index0, _}]} ->
                Index0;
            _ ->
                %% Ignore the entire string if no valid start pattern is found.
                length(PhoneNumber0)
        end,
    PhoneNumber1 = string:slice(PhoneNumber0, StartIndex),
    EndIndex =
        case re:run(PhoneNumber1, get_unwanted_end_char_pattern_matcher(), [notempty]) of
            {match, [{Index1, _}]} ->
                Index1;
            _ ->
                length(PhoneNumber1)
        end,
    PhoneNumber2 = string:slice(PhoneNumber1, 0, EndIndex),
    SecondEndIndex =
        case re:run(PhoneNumber2, get_second_number_start_pattern_matcher(), [notempty]) of
            {match, [{Index2, _}]} ->
                Index2;
            _ ->
                length(PhoneNumber2)
        end,
    PhoneNumber3 = string:slice(PhoneNumber2, 0, SecondEndIndex),
    ThirdEndIndex =
        case re:run(PhoneNumber3, get_extension_pattern_matcher(), [notempty]) of
            {match, [{Index3, _}]} ->
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

