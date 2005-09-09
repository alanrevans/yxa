%%%-------------------------------------------------------------------
%%% File    : sipauth.erl
%%% Author  : Magnus Ahltorp <ahltorp@nada.kth.se>
%%% Descrip.: SIP authentication functions.
%%% Created : 15 Nov 2002 by Magnus Ahltorp <ahltorp@nada.kth.se>
%%%-------------------------------------------------------------------
-module(sipauth).

%%-compile(export_all).

-export([get_response/5,
	 get_response/6,
	 get_nonce/1,
	 get_user_verified/2,
	 get_user_verified_proxy/2,
	 get_challenge/0,
	 can_register/2,
	 pstn_call_check_auth/5,
	 is_allowed_pstn_dst/4,
	 can_use_address/2,
	 can_use_address_detail/2,
	 realm/0,
	 add_x_yxa_peer_auth/5,

	 test/0
	]).


-include("siprecords.hrl").

%% MD5 digest 'formula'
%%
%% A1 = username ":" realm ":" password
%% A2 = Method ":" digest-uri
%% nonce = H(timestamp ":" privatekey)
%% resp = H(H(A1) ":" nonce ":" H(A2))

%%--------------------------------------------------------------------
%% Function: realm()
%% Descrip.: Return this proxys configured authentication realm.
%% Returns : string()
%%--------------------------------------------------------------------
realm() ->
    case yxa_config:get_env(sipauth_realm) of
	{ok, Realm} -> Realm;
	none -> ""
    end.

%%--------------------------------------------------------------------
%% Function: get_nonce(Timestamp)
%%           Timestamp = string(), current time in hex
%% Descrip.: Create a nonce. Since we have not located any useful
%%           randomness functions in Erlang, and since all proxys that
%%           share authentication realm should be able to use the
%%           responses to the challenges we create here, we use the
%%           current time plus the configured sipauth_password.
%% Returns : string()
%%--------------------------------------------------------------------
get_nonce(Timestamp) when is_list(Timestamp) ->
    {ok, Password} = yxa_config:get_env(sipauth_password, ""),
    hex:to(erlang:md5([Timestamp, ":", Password])).

%%--------------------------------------------------------------------
%% Function: get_challenge()
%% Descrip.: Create a challenge tuple.
%% Returns : Challenge
%%           Challenge = {Realm, Nonce, Timestamp}
%%           Realm     = string()
%%           Nonce     = string()
%%           Timestamp = string()
%%--------------------------------------------------------------------
get_challenge() ->
    Timestamp = hex:to(util:timestamp(), 8),
    {realm(), get_nonce(Timestamp), Timestamp}.

%%--------------------------------------------------------------------
%% Function: get_response(Nonce, Method, URIstr, User, Password)
%%           get_response(Nonce, Method, URIstr, User, Password,
%%                        Realm)
%%           Nonce    = string()
%%           Method   = string()
%%           URIstr   = string()
%%           User     = string()
%%           Password = string() | nomatch
%%           Realm    = string()
%% Descrip.: Get the correct response to a challenge, given a nonce,
%%           method, URI, username and password.
%% Returns : Response |
%%           none
%%           Response = string()
%%--------------------------------------------------------------------
get_response(Nonce, Method, URIstr, User, Password) ->
    Realm = realm(),
    get_response(Nonce, Method, URIstr, User, Password, Realm).

get_response(_Nonce, _Method, _URIstr, _User, nomatch, _Realm) ->
    %% Password is nomatch - return 'none'
    none;
get_response(Nonce, Method, URIstr, User, Password, Realm) ->
    A1 = hex:to(erlang:md5([User, ":", Realm, ":", Password])),
    A2 = hex:to(erlang:md5([Method, ":", URIstr])),
    hex:to(erlang:md5([A1, ":", Nonce, ":", A2])).

%%--------------------------------------------------------------------
%% Function: classify_number(Number, Regexps)
%%           Number  = string() | none
%%           Regexps = list() of {Regexp, Class} tuple()
%%           Regexp  = string()
%%           Class   = atom()
%% Descrip.: Search a list of regexps until Number matches the Regexp
%%           and return the Class.
%% Returns : {ok, Class}   |
%%           {ok, unknown} |
%%           {error, E}
%%           Class = atom()
%%--------------------------------------------------------------------
classify_number(none, _Regexps) ->
    {ok, unknown};

classify_number(Number, []) when is_list(Number) ->
    {ok, unknown};

classify_number(Number, [{"^+" ++ Regexp, _Class} | Rest]) when is_list(Number) ->
    logger:log(error, "sipauth:classify_number() Skipping invalid regexp ~p (you probably "
	       "forgot to escape the plus char)", ["^+" ++ Regexp]),
    classify_number(Number, Rest);

classify_number(Number, [{Regexp, Class} | Rest]) when is_list(Number), is_list(Regexp), is_atom(Class) ->
    case regexp:first_match(Number, Regexp) of
	{match, _, _} ->
	    {ok, Class};
	nomatch ->
	    classify_number(Number, Rest);
	{error, E} ->
	    logger:log(normal, "Error in regexp ~p: ~p", [Regexp, E]),
	    {error, E}
    end.

%%--------------------------------------------------------------------
%% Function: get_user_verified(Header, Method)
%%           Header = keylist record()
%%           Method = string()
%% Descrip.: Check if there is an Authorization: header in Header and
%%           check if it contains a valid response of a challenge we
%%           supposedly sent out.
%% Returns : false                 |
%%           {stale, User}         |
%%           {authenticated, User}
%%           User = string(), SIP authentication username
%%--------------------------------------------------------------------
get_user_verified(Header, Method) ->
    case keylist:fetch('authorization', Header) of
	[] ->
	    logger:log(debug, "Auth: get_user_verified: No Authorization header, returning false"),
	    false;
	Authheader ->
	    %% XXX how do we handle multiple Authorization headers (for different realms)?
	    get_user_verified2(Method, Authheader, Header)
    end.

%%--------------------------------------------------------------------
%% Function: get_user_verified_proxy(Header, Method)
%%           Header = keylist record()
%%           Method = string()
%% Descrip.: Check if there is an Proxy-Authorization: header in
%%           Header and check if it contains a valid response of a
%%           challenge we supposedly sent out. Might throw an
%%           {siperror, ...} if something is wrong with the
%%           authorization header.
%% Returns : false                 |
%%           {stale, User}         |
%%           {authenticated, User} |
%%           throw()
%%           User = string(), SIP authentication username
%% Notes   : XXX we should verify the URI too
%%--------------------------------------------------------------------
get_user_verified_proxy(Header, Method) ->
    case keylist:fetch('proxy-authorization', Header) of
	[] ->
	    logger:log(debug, "Auth: get_user_verified_proxy: No Proxy-Authorization header, returning false"),
	    false;
	Authheader ->
	    %% XXX how do we handle multiple Proxy-Authorization headers (for different realms)?
	    get_user_verified2(Method, Authheader, Header)
    end.

%%--------------------------------------------------------------------
%% Function: get_user_verified_yxa_peer(Header, Method)
%%           Header = keylist record()
%%           Method = string()
%% Descrip.: Check if there is an X-Yxa-Peer-Auth: header in Header
%%           and check if it authorizes this request. Might throw an
%%           {siperror, ...} if something is wrong with the
%%           authorization header.
%% Returns : false                 |
%%           {stale, User}         |
%%           {authenticated, User} |
%%           throw()
%%           User = string(), SIP authentication username
%% Notes   : XXX we should verify the URI too
%%--------------------------------------------------------------------
get_user_verified_yxa_peer(Header, Method) ->
    case keylist:fetch('x-yxa-peer-auth', Header) of
	[] ->
	    logger:log(debug, "Auth: get_user_verified_yxa_peer: No X-Yxa-Peer-Auth header, returning false"),
	    false;
	Authheader ->
	    %% XXX how do we handle multiple X-Yxa-Peer-Auth headers (for different realms)?
	    Authorization = sipheader:auth(Authheader),
	    OrigUser = User = dict:fetch("username", Authorization),
	    case yxa_config:get_env(x_yxa_peer_auth_secret) of
		{ok, Password} when is_list(Password) ->
		    Realm = dict:fetch("realm", Authorization),
		    Now = util:timestamp(),
		    do_get_user_verified2(Method, User, OrigUser, Password, Realm, Now, Authorization);
		none ->
		    logger:log(debug, "Auth: Request has X-Yxa-Peer-Auth header, but I have no configured secret"),
		    false
	    end
    end.

get_user_verified2(_Method, ["GSSAPI" ++ _R] = Authheader, _Header) ->
    Authorization = sipheader:auth(Authheader),
    Info = dict:fetch("info", Authorization),
    {_Response, Username} = gssapi:request(Info),
    %% XXX this is definately broken! What does gssapi:request() return anyways?
    Username,
    erlang:fault({error, "GSSAPI code broken and not yet fixed"});

%%--------------------------------------------------------------------
%% Function: get_user_verified2(Method, Authheader, Header)
%%           Method     = string()
%%           Authheader = [string()], the auth header in question
%%           Header     = keylist record()
%% Descrip.: Authenticate a request.
%% Returns : {authenticated, User} |
%%           {stale, User}         |
%%           false                 |
%%           throw({siperror, ...})
%%--------------------------------------------------------------------
get_user_verified2(Method, Authheader, Header) ->
    Authorization = sipheader:auth(Authheader),
    %% Remember the username the client used
    OrigUser = dict:fetch("username", Authorization),
    %% Canonify username
    User = case local:canonify_authusername(OrigUser, Header) of
	       undefined ->
		   OrigUser;
	       Res when is_list(Res) ->
		   Res
	   end,
    Password = case local:get_password_for_user(User) of
		   nomatch ->
		       nomatch;
		   PRes when is_list(PRes) ->
		       PRes
	       end,
    Realm = realm(),
    Now = util:timestamp(),
    do_get_user_verified2(Method, User, OrigUser, Password, Realm, Now, Authorization).

%% do_get_user_verified2/7 - part of get_user_verified2/3 in order to make it testable
do_get_user_verified2(Method, User, OrigUser, Password, Realm, Now, AuthDict) ->
    Opaque = case dict:find("opaque", AuthDict) of
		 error ->
		     throw({siperror, 400, "Authorization should contain opaque"});
		 {ok, Value} ->
		     Value
	     end,
    AuthURI = dict:fetch("uri", AuthDict),
    Response = dict:fetch("response", AuthDict),
    Nonce2 = get_nonce(Opaque),
    Nonce = dict:fetch("nonce", AuthDict),

    Timestamp = hex:from(Opaque),
    logger:log(debug, "Auth: timestamp: ~p now: ~p", [Timestamp, Now]),
    Response2 = get_response(Nonce2, Method, AuthURI,
			     OrigUser, Password, Realm),
    if
	Password == nomatch ->
	    logger:log(normal, "Auth: Authentication failed for non-existing user ~p", [User]),
	    false;
	Response /= Response2 ->
	    logger:log(debug, "Response ~p /= Response2 ~p", [Response, Response2]),
	    logger:log(normal, "Auth: Authentication failed for user ~p", [User]),
	    false;
	Nonce /= Nonce2 ->
	    logger:log(normal, "Auth: Nonce ~p /= ~p, authentication failed for user ~p", [Nonce, Nonce2, User]),
	    false;
	Timestamp < Now - 30 ->
	    logger:log(normal, "Auth: Timestamp ~p too old. Now: ~p, authentication failed for user ~p",
		       [Timestamp, Now, User]),
	    {stale, User};
	Timestamp > Now ->
	    logger:log(normal, "Auth: Timestamp ~p too new. Now: ~p, authentication failed for user ~p",
		       [Timestamp, Now, User]),
	    false;
	true ->
	    logger:log(debug, "Auth: User ~p authenticated", [User]),
	    {authenticated, User}
    end.

%% Authenticate through X-Yxa-Peer-Auth or, if that does not exist, through Proxy-Authentication
pstn_get_user_verified(Header, Method) ->
    case get_user_verified_yxa_peer(Header, Method) of
	false ->
	    get_user_verified_proxy(Header, Method);
	{stale, User} ->
	    {stale, User};
	{authenticated, User} ->
	    {peer_authenticated, User}
    end.


%%--------------------------------------------------------------------
%% Function: pstn_call_check_auth(Method, Header, URL, ToNumberIn,
%%                                Classdefs)
%%           Method     = string()
%%           Header     = keylist record()
%%           URL        = sipurl record(), From-address in request
%%           ToNumberIn = string(), destination, local or E.164 number
%%           Classdefs  = term()
%% Descrip.: Check if the destination is allowed for this user, and
%%           check if this user may use this Address.
%% Returns : {Allowed, User, Class}
%%           Allowed = true | false
%%           User    = unknown | none | string(), SIP authentication
%%                     username
%%           Class   = atom(), the class that this ToNumberIn matched
%%--------------------------------------------------------------------
pstn_call_check_auth(Method, Header, URL, ToNumberIn, Classdefs)
  when is_list(Method), is_record(Header, keylist), is_record(URL, sipurl), is_list(ToNumberIn) ->
    ToNumber = case local:rewrite_potn_to_e164(ToNumberIn) of
		   error -> ToNumberIn;
		   N -> N
	       end,
    {ok, Class} = classify_number(ToNumber, Classdefs),
    {ok, UnauthClasses} = yxa_config:get_env(sipauth_unauth_classlist, []),
    case lists:member(Class, UnauthClasses) of
	true ->
	    %% This is a class that anyone should be allowed to call,
	    %% just check that if this is one of our SIP users, they
	    %% are permitted to use the From: address
	    logger:log(debug, "Auth: ~p is of class ~p which does not require authorization", [ToNumber, Class]),
	    Address = sipurl:print(URL),
	    case local:get_user_with_address(Address) of
		nomatch ->
		    logger:log(debug, "Auth: Address ~p does not match any of my users, no need to verify.",
			       [Address]),
		    {true, unknown, Class};
		User when is_list(User) ->
		    Allowed = local:can_use_address(User, URL),
		    {Allowed, User, Class}
	    end;
	false ->
	    case pstn_get_user_verified(Header, Method) of
		false ->
		    {false, none, Class};
		{stale, User} ->
		    {stale, User, Class};
		{peer_authenticated, User} ->
		    %% For Peer-authenticated User, we don't check to see if User might use From: address or not
		    case local:is_allowed_pstn_dst(User, ToNumber, Header, Class) of
			true ->
			    {true, User, Class};
			false ->
			    {false, User, Class}
		    end;
		{authenticated, User} ->
		    UserAllowedToUseAddress = local:can_use_address(User, URL),
		    AllowedCallToNumber = local:is_allowed_pstn_dst(User, ToNumber, Header, Class),
		    if
			UserAllowedToUseAddress /= true ->
			    logger:log(normal, "Auth: User ~p is not allowed to use address ~p (when placing PSTN "
				       "call to ~s (class ~p))", [User, sipurl:print(URL), ToNumber, Class]),
			    {false, User, Class};
			AllowedCallToNumber /= true ->
			    logger:log(normal, "Auth: User ~p not allowed to call ~p in class ~p",
				       [User, ToNumber, Class]),
			    {false, User, Class};
			true ->
			    {true, User, Class}
		    end
	    end
    end.

%%--------------------------------------------------------------------
%% Function: is_allowed_pstn_dst(User, ToNumber, Header, Class)
%%           User     = string()
%%           ToNumber = string(), destination, local or E.164 number
%%           Header   = keylist record()
%%           Class    = atom()
%% Descrip.: Check if a given User is explicitly allowed to call a
%%           number in a given Class, or if there is a Route: header
%%           present in Header.
%% Returns : true  |
%%           false
%%--------------------------------------------------------------------
is_allowed_pstn_dst(User, _ToNumber, Header, Class) ->
    case keylist:fetch('route', Header) of
	[] ->
	    case local:get_classes_for_user(User) of
		nomatch ->
		    false;
		UserAllowedClasses when is_list(UserAllowedClasses) ->
		    lists:member(Class, UserAllowedClasses)
	    end;
	R when is_list(R) ->
	    logger:log(debug, "Auth: Authenticated user ~p sends request with Route-header. Allow.", [User]),
	    true
    end.

%%--------------------------------------------------------------------
%% Function: can_use_address(User, URL)
%%           User    = string()
%%           URL     = sipurl record()
%% Descrip.: Check if a given User may use address Address as From:
%%           by using the function can_use_address_detail/2 not caring
%%           about the reason it returns.
%% Returns : true  |
%%           false
%%--------------------------------------------------------------------
can_use_address(User, URL) when is_list(User), is_record(URL, sipurl) ->
    case local:can_use_address_detail(User, URL) of
	{true, _} -> true;
	{false, _} -> false
    end.

%%--------------------------------------------------------------------
%% Function: can_use_address_detail(User, URL)
%%           User    = string()
%%           URL     = sipurl record()
%% Descrip.: Check if a given User may use address Address as From:
%% Returns : {Verdict, Reason}
%%           Verdict = true | false
%%           Reason  = ok | eperm | nomatch | error
%%--------------------------------------------------------------------
can_use_address_detail(User, URL) when is_list(User), is_record(URL, sipurl) ->
    can_use_address_detail2(User, URL, local:get_users_for_url(URL)).

%% can_use_address_detail2 - the testable part of can_use_address_detail/2
can_use_address_detail2(User, URL, URLUsers) when is_list(User), is_record(URL, sipurl), is_list(URLUsers) ->
    case URLUsers of
	[User] ->
	    logger:log(debug, "Auth: User ~p is allowed to use address ~p",
		       [User, sipurl:print(URL)]),
	    {true, ok};
	[OtherUser] ->
	    logger:log(debug, "Auth: User ~p may NOT use use address ~p (belongs to user ~p)",
		       [User, sipurl:print(URL), OtherUser]),
	    {false, eperm};
	[] ->
	    logger:log(debug, "Auth: No users found for address ~p, use by user ~p NOT permitted",
		       [sipurl:print(URL), User]),
	    {false, nomatch};
	_ ->
	    case lists:member(User, URLUsers) of
		true ->
		    {true, ok};
		false ->
		    logger:log(debug, "Auth: Use of address ~p NOT permitted. Address maps to more than one user, but not to ~p (~p)",
			       [sipurl:print(URL), User, URLUsers]),
		    {false, eperm}
	    end
    end;
can_use_address_detail2(User, URL, nomatch) when is_list(User), is_record(URL, sipurl) ->
    logger:log(debug, "Auth: No users found for address ~p, use by user ~p NOT permitted",
	       [sipurl:print(URL), User]),
    {false, nomatch}.

%%--------------------------------------------------------------------
%% Function: can_register(Header, ToURL)
%%           Header = keylist record()
%%           ToURL  = sipurl record()
%% Descrip.: Check if a REGISTER message authenticates OK, and check
%%           that the User returned from credentials check actually
%%           may use this To: (NOT From:, so third party registrations
%%           are not denied per se by this check).
%% Returns : {{Verdict, Reason}, User} |
%%           {stale, User}             |
%%           {false, none}
%%           Verdict = true | false
%%           Reason  = ok | eperm | nomatch | error
%%--------------------------------------------------------------------
can_register(Header, ToURL) ->
    case local:get_user_verified(Header, "REGISTER") of
	{authenticated, User} ->
	    {local:can_use_address_detail(User, ToURL), User};
	{stale, User} ->
	    {stale, User};
	_ ->
	    logger:log(debug, "Auth: Registration of address ~p NOT permitted", [sipurl:print(ToURL)]),
	    {false, none}
    end.

add_x_yxa_peer_auth(Method, URI, Header, User, Secret) when is_list(Method), is_record(URI, sipurl),
						    is_record(Header, keylist), is_list(User), is_list(Secret) ->
    {Realm, Nonce, Opaque} = get_challenge(),
    URIstr = sipurl:print(URI),
    Response = get_response(Nonce, Method, URIstr, User, Secret, Realm),
    AuthStr = print_auth_response("Digest", User, Realm, URIstr,
				  Response, Nonce, Opaque, "md5"),
    keylist:set("X-Yxa-Peer-Auth", [AuthStr], Header).
    
%%--------------------------------------------------------------------
%% Function: print_auth_response(AuthMethod, User, Realm, URIstr,
%%                               Response, Nonce, Opaque, Algorithm)
%%           All parameters are of type string()
%% Descrip.: Construct a challenge response, given a bunch of in-
%%           parameters.
%% Returns : string()
%%--------------------------------------------------------------------
print_auth_response(AuthMethod, User, Realm, URIstr, Response, Nonce, Opaque, Algorithm) ->
    Quote = "\"",
    QuoteComma = "\",",

    lists:concat([AuthMethod, " ",
		  "username=",		Quote, User,		QuoteComma,
		  "realm=",		Quote, Realm,		QuoteComma,
		  "uri=",		Quote, URIstr,		QuoteComma,
		  "response=",		Quote, Response,	QuoteComma,
		  "nonce=",		Quote, Nonce,		QuoteComma,
		  "opaque=",		Quote, Opaque,		QuoteComma,
		  "algorithm=",		Algorithm]).


%%====================================================================
%% Test functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: test()
%% Descrip.: autotest callback
%% Returns : ok | throw()
%%--------------------------------------------------------------------
test() ->

    %% test classify_number(Number, RegexpList)
    %%--------------------------------------------------------------------
    ClassifyRegexp1 = [{"^123", internal},
		       {"^00", external}
		      ],
    autotest:mark(?LINE, "classify_number/2 - 1"),
    {ok, unknown} = classify_number(none, []),

    autotest:mark(?LINE, "classify_number/2 - 2"),
    %% test normal case #1
    {ok, internal} = classify_number("1234", ClassifyRegexp1),

    autotest:mark(?LINE, "classify_number/2 - 3"),
    %% test normal case #2
    {ok, external} = classify_number("00234", ClassifyRegexp1),

    autotest:mark(?LINE, "classify_number/2 - 4"),
    %% test unmatched number
    {ok, unknown} = classify_number("9", ClassifyRegexp1),

    autotest:mark(?LINE, "classify_number/2 - 5"),
    %% test invalid regexp (circumflex-plus), should be skipped
    {ok, unknown} = classify_number("+123", [{"^+1", internal}]),

    autotest:mark(?LINE, "classify_number/2 - 6"),
    %% test invalid regexp
    {error, _} = classify_number("+123", [{"unbalanced (", internal}]),


    %% test can_use_address_detail2(User, URL, URLUsers)
    %%--------------------------------------------------------------------
    CanUseURL1 = sipurl:parse("sip:ft@example.org"),

    autotest:mark(?LINE, "can_use_address_detail2/3 - 1"),
    {true, ok} = can_use_address_detail2("ft", CanUseURL1, ["ft"]),

    autotest:mark(?LINE, "can_use_address_detail2/3 - 2"),
    {false, eperm} = can_use_address_detail2("ft", CanUseURL1, ["not-ft"]),

    autotest:mark(?LINE, "can_use_address_detail2/3 - 3"),
    {false, nomatch} = can_use_address_detail2("ft", CanUseURL1, []),

    autotest:mark(?LINE, "can_use_address_detail2/3 - 3"),
    {true, ok} = can_use_address_detail2("ft", CanUseURL1, ["foo", "ft", "bar"]),

    autotest:mark(?LINE, "can_use_address_detail2/3 - 3"),
    {false, eperm} = can_use_address_detail2("ft", CanUseURL1, ["foo", "bar"]),

    autotest:mark(?LINE, "can_use_address_detail2/3 - 1"),
    {false, nomatch} = can_use_address_detail2("ft", CanUseURL1, nomatch),


    %% Auth tests
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "auth - 0"),
    AuthNow1		= 11000000,
    AuthTimestamp1	= hex:to(AuthNow1, 8),
    AuthOpaque1		= AuthTimestamp1,
    AuthMethod1		= "INVITE",
    AuthURI1		= "sip:ft@example.org",
    AuthUser1		= "ft.test",
    AuthPassword1	= "foo",
    AuthRealm1		= "yxa-test",
    AuthNonce1		= get_nonce(AuthTimestamp1),	%% The nonce is MD5 of AuthTimestamp1 colon OurSecret

    AuthCorrectResponse1 = get_response(AuthNonce1, AuthMethod1, AuthURI1, AuthUser1, AuthPassword1, AuthRealm1),
    AuthResponse1 = print_auth_response("Digest", AuthUser1, AuthRealm1, AuthURI1, AuthCorrectResponse1,
					AuthNonce1, AuthOpaque1, "md5"),
    AuthDict1 = sipheader:auth([AuthResponse1]),


    %% test get_nonce(Timestamp)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_nonce/1 - 1"),
    "22d10c95a33616d16599317751534c4d" = get_nonce(hex:to(0, 8)),

    autotest:mark(?LINE, "get_nonce/1 - 2"),
    "2b9d0abeef571102304778343b31a5e1" = get_nonce(hex:to(11000000, 8)),

    autotest:mark(?LINE, "get_nonce/1 - 3"),
    "be7ef379132a226876b70668ee46dc8f" = get_nonce(hex:to(22000000, 8)),


    %% test do_get_user_verified2(Method, User, UAuser, Password, Realm, Now, AuthDict)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "do_get_user_verified2/7 - 1"),
    %% Correct response (AuthDict1)
    {authenticated, "canon-user"} =
	do_get_user_verified2(AuthMethod1, "canon-user", AuthUser1, AuthPassword1,
			      AuthRealm1, AuthNow1, AuthDict1),

    autotest:mark(?LINE, "do_get_user_verified2/7 - 2"),
    %% Correct response, time in the future
    false =
	do_get_user_verified2(AuthMethod1, "canon-user", AuthUser1, AuthPassword1,
			      AuthRealm1, AuthNow1 - 1, AuthDict1),

    autotest:mark(?LINE, "do_get_user_verified2/7 - 3"),
    %% Correct response, time since challenge: 30 seconds
    {authenticated, "canon-user"} =
	do_get_user_verified2(AuthMethod1, "canon-user", AuthUser1, AuthPassword1,
			      AuthRealm1, AuthNow1 + 30, AuthDict1),

    autotest:mark(?LINE, "do_get_user_verified2/7 - 4"),
    %% Correct response, time since challenge: 31 seconds = stale
    {stale, "canon-user"} =
	do_get_user_verified2(AuthMethod1, "canon-user", AuthUser1, AuthPassword1,
			      AuthRealm1, AuthNow1 + 31, AuthDict1),

    autotest:mark(?LINE, "do_get_user_verified2/7 - 5"),
    %% Invalid password
    false =
	do_get_user_verified2(AuthMethod1, "canon-user", AuthUser1, "incorrect",
			      AuthRealm1, AuthNow1, AuthDict1),

    autotest:mark(?LINE, "do_get_user_verified2/7 - 6"),
    %% Invalid user, indicated by password 'nomatch'
    false =
	do_get_user_verified2(AuthMethod1, "canon-user", AuthUser1, nomatch,
			      AuthRealm1, AuthNow1, AuthDict1),

    autotest:mark(?LINE, "do_get_user_verified2/7 - 7"),
    %% Wrong 'nonce' parameter
    false =
	do_get_user_verified2(AuthMethod1, "canon-user", AuthUser1, AuthPassword1,
			      AuthRealm1, AuthNow1, dict:store("nonce", "0a1b2c", AuthDict1)),

    autotest:mark(?LINE, "do_get_user_verified2/7 - 8"),
    %% Missing 'opaque' parameter
    {siperror, 400, "Authorization should contain opaque"} =
	(catch do_get_user_verified2(AuthMethod1, "canon-user", AuthUser1, nomatch,
			      AuthRealm1, AuthNow1, dict:erase("opaque", AuthDict1))),


    %% test get_challenge()
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_challenge/0 - 1.1"),
    {_Realm, ChallengeNonce1, ChallengeTimestamp1} = get_challenge(),

    autotest:mark(?LINE, "get_challenge/0 - 1.1"),
    %% verify results as good as we can
    ChallengeNonce1 = get_nonce(ChallengeTimestamp1),
    true = (ChallengeTimestamp1 > 11000000),


    %% test get_user_verified(Header, Method)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_user_verified/2 - 1"),
    %% Test without Authorization header - that is the only thing we can test
    %% here. The testable parts of this code is tested above (do_get_user_verified2).
    false = get_user_verified(keylist:from_list([]), "INVITE"),


    %% test get_user_verified_proxy(Header, Method)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_user_verified_proxy/2 - 1"),
    %% Test without Authorization header - that is the only thing we can test
    %% here. The testable parts of this code is tested above (do_get_user_verified2).
    false = get_user_verified(keylist:from_list([]), "INVITE"),


    %% test pstn_call_check_auth(Method, Header, URL, ToNumberIn, Classdefs)
    %% Not much can be tested in this function, but some is better than nothing
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "pstn_call_check_auth/5 - 1"),
    {false, none, testclass} = pstn_call_check_auth("INVITE", keylist:from_list([]),
						    sipurl:parse("sip:ft@example.org"),
						    "123456789", [{"^123", testclass}]),


    %% test is_allowed_pstn_dst(User, ToNumber, Header, Class)
    %% Not much can be tested in this function, but some is better than nothing
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "is_allowed_pstn_dst/4 - 1"),
    %% test request with Route header
    true = is_allowed_pstn_dst("ft.testuser", "123456789", keylist:from_list([{"Route", "sip:example.org"}]),
			       testclass),

    %% This test depends on too much unspecified things in sipuserdb
    %%autotest:mark(?LINE, "is_allowed_pstn_dst/4 - 2 (disabled)"),
    %%%% test general unknown user/number/class
    %%false = is_allowed_pstn_dst("ft.testuser", "123456789", keylist:from_list([]), testclass),


    %% test can_use_address(User, URL)
    %% Not much can be tested in this function, but some is better than nothing
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "can_use_address/2 - 1"),
    false = can_use_address("ft.testuser", sipurl:parse("sip:not-homedomain.example.org")),


    %% test can_register(Header, ToURL)
    %% Not much can be tested in this function, but some is better than nothing
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "can_register/2 - 1"),
    {false, none} = can_register(keylist:from_list([]), sipurl:parse("sip:ft@example.org")),

    ok.