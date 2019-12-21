-module(mod_phone_number_normalization).

-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").

-export([start/2, stop/1, depends/2, mod_options/1, process_local_iq/1, normalize/1, parse/1]).

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

process_local_iq(#iq{type = get,
		     sub_els = [#contact_list{ contacts = Contacts}]} = IQ) ->
	case Contacts of
		[] -> xmpp:make_iq_result(IQ);
		_ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = <<"ns:phonenumber:normalization">>, contacts = normalize_contacts(Contacts)})
	end.

normalize_contacts([]) ->
	[];
normalize_contacts([First | Rest]) ->
	[normalize_contact(First) | normalize_contacts(Rest)].

normalize_contact({_, _, Rawnumbers, _}) ->
	{contact, [], Rawnumbers, normalize(Rawnumbers)}.

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
        Num = re:replace(Number, "[^0-9+]", "", [global, {return,list}]),
        case string:length(Num) of
		10 -> unicode:characters_to_list(["+1", Num]);
		11 ->
			Firstdigit = string:slice(Num, 0, 1),
			if
				Firstdigit == "1" ->
					unicode:characters_to_list(["+", Num]);
				true ->
                                        "" % ignore the number if first digit is not equal to 1 when the number is 11 digits.
                        end;
		12 ->
			Firsttwodigits = string:slice(Num, 0, 2),
                        if
                                Firsttwodigits == "+1" ->
                                        Num;
                                true ->
                                        "" % ignore the number if first two digits are not equal to +1 when the number is 12 digits.
                        end;
		_Else -> ""
        end.
