%%%----------------------------------------------------------------------
%%% This file creates the ets table to hold all the phonenumber metadata and invokes the parser
%%% to parse the xml file.
%%% We will be adding more relevant functions here to parse a given phone-number,
%%% format it and return the result.
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

%% Normalizes a list of characters representing a phone number.
%% This strips punctuation and non-digit characters.
%% Currently we do not handle alpha or any other set of characters.
-spec normalize(list()) -> list().
normalize(PhoneNumber) ->
    re:replace(PhoneNumber, "[^0-9]", "", [global, {return,list}]).



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
%% Currently, we do not handle extensions.
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
    PhoneNumber3.


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

