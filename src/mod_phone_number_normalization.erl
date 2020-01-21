%%%----------------------------------------------------------------------
%%% File    : mod_phone_number_normalization.erl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%
%%% This file handles the iq packet queries with a custom namespace (<<"ns:phonenumber:normalization">>) that we defined.
%%% We define custom xml records of the following type: "contact_list", "contact", "raw", "role", "normalized" in xmpp/specs/xmpp_codec.spec file.
%%% The module expects a "contact_list" containing "raw" phone numbers of the "contacts" of the user, normalizes these
%%% phone numbers using our custom rules and return these "normalized" phone numbers and
%%% their "roles" indicating if the "contact" is registered on halloapp or not with values "member" and "none" respectively.
%%% Currently, the normalization rules are specific to work with only US phone numbers.
%%% TODO(murali@): extend this to other international countries.
%%%----------------------------------------------------------------------

-module(mod_phone_number_normalization).

-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").

-export([start/2, stop/1, depends/2, mod_options/1, process_local_iq/1, normalize/1, normalize_contacts/2, normalize_contact/2, parse/1, certify/2, validate/2]).

start(Host, Opts) ->
    xmpp:register_codec(phone_number_normalization),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, <<"ns:phonenumber:normalization">>, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    xmpp:unregister_codec(phone_number_normalization),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, <<"ns:phonenumber:normalization">>),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

process_local_iq(#iq{type = get, to = Host,
		     sub_els = [#contact_list{ contacts = Contacts}]} = IQ) ->
	case Contacts of
		[] -> xmpp:make_iq_result(IQ);
		_ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = <<"ns:phonenumber:normalization">>, contacts = normalize_contacts(Contacts, Host)})
	end.

normalize_contacts([], Host) ->
	[];
normalize_contacts([First | Rest], Host) ->
	[normalize_contact(First, Host) | normalize_contacts(Rest, Host)].

normalize_contact({_, Raw_numbers, _}, Host) ->
	Norm_numbers = normalize(Raw_numbers),
	Roles = certify(Norm_numbers, Host),
	{Roles, Raw_numbers, Norm_numbers}.

normalize([]) ->
	[];
normalize([First | Rest]) ->
	Result = parse(First),
	if
		Result == "" ->
			normalize(Rest);
		true ->
			[Result | normalize(Rest)]
	end.

parse(Number) ->
        Num = re:replace(Number, "[^0-9]", "", [global, {return,list}]),
        case string:length(Num) of
		10 -> unicode:characters_to_list(["1", Num]);
		11 ->
			case Num of
                                "1"++_ -> Num;
                                _Else -> "" % ignore the number if first digit is not equal to 1 when the number is 11 digits.
                        end;
		_Else -> ""
        end.

certify([], Host) ->
	[];
certify([First | Rest], Host) ->
	[validate(First, Host)| certify(Rest, Host)].

%% Validates if the contact is registered with halloapp or not by looking up the passwd table.
validate(Number, Host) ->
	US = {list_to_binary(Number), jid:to_string(Host)},
	ValueList = mnesia:dirty_read(passwd, US),
	case ValueList of
		[] -> "none";
		_Else -> "member"
	end.
