-module(incomingproxy).

-export([init/0, request/6, response/6]).

init() ->
    Registrar = {registrar, {registrar, start_link, []}, permanent, 2000, worker, [registrar]},
    [[fun request/6, fun response/6], none, stateful, {append, [Registrar]}].


route_request(Request) ->
    {Method, URL, Header, Body} = Request,
    {User, Pass, Host, Port, Parameters} = URL,
    Loc1 = case local:homedomain(Host) of
	true ->
	    case is_request_to_me(Method, URL, Header) of
		true ->
		    {me};
		_ ->
		    request_to_homedomain(URL)
	    end;
	_ ->
	    request_to_remote(URL)
    end,
    case Loc1 of
	nomatch ->
	    logger:log(debug, "Routing: No match - trying default route"),
	    local:lookupdefault(URL);
	_ ->
	    Loc1
    end.

is_request_to_me(_, {none, _, _, _, _}, Header) ->
    true;
is_request_to_me("OPTIONS", URL, Header) ->
    % RFC3261 # 11 says a proxy that receives an OPTIONS request with a Max-Forwards less than one
    % MAY treat it as a request to the proxy.
    MaxForwards =
	case keylist:fetch("Max-Forwards", Header) of
	    [M] ->
		lists:min([255, list_to_integer(M) - 1]);
	    [] ->
		70
	end,
    if
	MaxForwards < 1 ->
	    logger:log(debug, "Routing: Request is OPTIONS and Max-Forwards < 1, treating it as a request to me."),
	    true;
	true ->
	    false
    end;
is_request_to_me(_, _, _) ->
    false.

request("REGISTER", URL, Header, Body, Socket, FromIP) ->
    {User, Pass, Host, Port, Parameters} = URL,
    Request = {"REGISTER", URL, Header, Body},
    logger:log(debug, "REGISTER ~p", [sipurl:print(URL)]),
    THandler = transactionlayer:get_handler_for_request(Request),
    LogTag = get_branch_from_handler(THandler),
    case local:homedomain(Host) of
	true ->
	    LogStr = sipserver:make_logstr({request, "REGISTER", URL, Header, Body}, FromIP),
	    logger:log(debug, "~s -> processing", [LogStr]),
	    % delete any present Record-Route header (RFC3261, #10.3)
	    NewHeader = keylist:delete("Record-Route", Header),
	    {_, ToURL} = sipheader:to(keylist:fetch("To", Header)),
	    case local:can_register(NewHeader, sipurl:print(ToURL)) of
		{{true, _}, SIPuser} ->
		    Contacts = sipheader:contact(keylist:fetch("Contact", Header)),
		    logger:log(debug, "Register: Contact(s) ~p", [sipheader:contact_print(Contacts)]),
		    logger:log(debug, "~s: Registering contacts for SIP user ~p", [LogTag, SIPuser]),
		    case catch siplocation:process_register_isauth(LogTag ++ ": incomingproxy", NewHeader, SIPuser, Contacts) of
			{ok, {Status, Reason, ExtraHeaders}} ->
			    transactionlayer:send_response_handler(THandler, Status, Reason, ExtraHeaders);	
			{siperror, Status, Reason} ->
			    transactionlayer:send_response_handler(THandler, Status, Reason);
			{siperror, Status, Reason, ExtraHeaders} ->
			    transactionlayer:send_response_handler(THandler, Status, Reason, ExtraHeaders);
			_ ->
			    true
		    end;
		{stale, _} ->
		    logger:log(normal, "~s -> Authentication is STALE, sending new challenge", [LogStr]),
		    transactionlayer:send_challenge(THandler, www, true, none);
		{{false, eperm}, SipUser} when SipUser /= none ->
		    logger:log(normal, "~s: incomingproxy: SipUser ~p NOT ALLOWED to REGISTER address ~s",
				[LogTag, SipUser, sipurl:print(ToURL)]),
		    transactionlayer:send_response_handler(THandler, 403, "Forbidden");
		{{false, nomatch}, SipUser} when SipUser /= none ->
		    logger:log(normal, "~s: incomingproxy: SipUser ~p tried to REGISTER invalid address ~s",
				[LogTag, SipUser, sipurl:print(ToURL)]),
		    transactionlayer:send_response_handler(THandler, 404, "Not Found");
		{false, none} ->
		    Prio = case keylist:fetch("Authorization", Header) of
			[] -> debug;
			_ -> normal
		    end,
		    % XXX send new challenge (current behavior) or send 403 Forbidden when authentication fails?
		    logger:log(Prio, "~s -> Authentication FAILED, sending challenge", [LogStr]),
		    transactionlayer:send_challenge(THandler, www, false, 3);
		Unknown ->
		    logger:log(error, "Register: Unknown result from local:can_register() URL ~p :~n~p",
		    		[sipurl:print(URL), Unknown]),
		    transactionlayer:send_response_handler(THandler, 500, "Server Internal Error")
	    end;
	_ ->
	    logger:log(debug, "REGISTER for non-homedomain ~p", [Host]),
	    do_request({"REGISTER", URL, Header, Body}, Socket, FromIP)
    end;

request(Method, URI, Header, Body, Socket, FromIP) when Method == "ACK" ->
    LogStr = sipserver:make_logstr({request, Method, URI, Header, Body}, FromIP),
    logger:log(normal, "incomingproxy: ~s -> Forwarding ACK received in core statelessly",
    		[LogStr]),
    transportlayer:send_proxy_request(none, {Method, URI, Header, Body}, URI, []);

request(Method, URL, Header, Body, Socket, FromIP) when Method == "CANCEL" ->
    do_request({Method, URL, Header, Body}, Socket, FromIP);

% Here we have a request that is not CANCEL or ACK (or REGISTER).
% Check if the From: address matches our homedomains, and if so
% call verify_homedomain_user() to make sure the user is
% authorized and authenticated to use this From: address
request(Method, URL, Header, Body, Socket, FromIP) ->
    Request = {Method, URL, Header, Body},
    {_, FromURI} = sipheader:from(keylist:fetch("From", Header)),
    {_, _, Host, _, _} = FromURI,
    case local:homedomain(Host) of
	true ->
	    LogStr = sipserver:make_logstr({request, Method, URL, Header, Body}, FromIP),
	    case verify_homedomain_user(Socket, Request, LogStr) of
		true ->
		    do_request(Request, Socket, FromIP);
		false ->
		    logger:log(normal, "~s -> 403 Forbidden", [LogStr]),
		    transactionlayer:send_response_request(Request, 403, "Forbidden");
		drop ->
		    ok;
		Unknown ->
		    logger:log(error, "~s: Unknown result from verify_homedomain_user() :~n~p",
		    		[LogStr, Unknown]),
		    transactionlayer:send_response_request(Request, 500, "Server Internal Error")
	    end;
	_ ->
	    do_request(Request, Socket, FromIP)
    end.

verify_homedomain_user(Socket, Request, LogStr) ->
    {Method, URI, Header, Body} = Request,
    case sipserver:get_env(always_verify_homedomain_user, true) of
	true ->
	    {_, FromURI} = sipheader:from(keylist:fetch("From", Header)),
	    % Request has a From: address matching one of my domains.
	    % Verify sending user.
	    case local:get_user_verified_proxy(Header, Method) of
		{authenticated, SIPUser} ->
		    case local:can_use_address(SIPUser, sipurl:print(FromURI)) of
			true ->
			    logger:log(debug, "Request: User ~p is allowed to use From: address ~p",
			    		[SIPUser, sipurl:print(FromURI)]),
			    true;
			false ->
			    logger:log(error, "Authenticated user ~p may NOT use address ~p",
			    		[SIPUser, sipurl:print(FromURI)]),
			    false
		    end;
		stale ->
		    logger:log(debug, "Request from homedomain user: STALE authentication, sending challenge"),
		    transactionlayer:send_challenge_request(Request, proxy, true, none),
		    drop;
		false ->
		    Prio = case keylist:fetch("Proxy-Authenticate", Header) of
			[] -> debug;
			_ -> normal
		    end,
		    logger:log(Prio, "~s -> Request from unauthorized homedomain user, sending challenge",
		    		[LogStr]),
		    transactionlayer:send_challenge_request(Request, proxy, false, none),
		    drop;
		Unknown ->
		    logger:log(error, "request: Unknown result from local:get_user_verified_proxy() :~n~p", [Unknown]),
		    transactionlayer:send_response_request(Request, 500, "Server Internal Error"),
		    drop
	    end;
	_ ->
	    true
    end.

do_request(Request, Socket, FromIP) ->
    {Method, URL, OrigHeader, Body} = Request,
    logger:log(debug, "~s ~s~n",
	       [Method, sipurl:print(URL)]),
    Header = case sipserver:get_env(record_route, false) of
	true -> siprequest:add_record_route(OrigHeader);
	false -> OrigHeader
    end,
    Location = route_request({Method, URL, Header, Body}),
    logger:log(debug, "Location: ~p", [Location]),
    LogStr = sipserver:make_logstr({request, Method, URL, Header, Body}, FromIP),
    THandler = transactionlayer:get_handler_for_request(Request),
    LogTag = get_branch_from_handler(THandler),
    case Location of
	none ->
	    logger:log(normal, "~s: incomingproxy: 404 Not found", [LogTag]),
	    transactionlayer:send_response_handler(THandler, 404, "Not Found");
	{error, Errorcode} ->
	    logger:log(normal, "~s: incomingproxy: Error ~p", [LogTag, Errorcode]),
	    transactionlayer:send_response_handler(THandler, Errorcode, "Unknown code");
	{response, Returncode, Text} ->
	    logger:log(normal, "~s: incomingproxy: Response ~p ~s", [LogTag, Returncode, Text]),
	    transactionlayer:send_response_handler(THandler, Returncode, Text);
	{proxy, Loc} ->
	    logger:log(normal, "~s: incomingproxy: Proxy ~s -> ~s", [LogTag, Method, sipurl:print(Loc)]),
	    proxy_request(THandler, Request, Loc, []);
	{redirect, Loc} ->
	    logger:log(normal, "~s: incomingproxy: Redirect ~s", [LogTag, sipurl:print(Loc)]),
	    Contact = [{none, Location}],
	    ExtraHeaders = [{"Contact", sipheader:contact_print(Contact)}],
	    transactionlayer:send_response_handler(THandler, 302, "Moved Temporarily", ExtraHeaders);
	{relay, Loc} ->
	    relay_request(THandler, Request, Loc, LogTag);
	{forward, Host, Port} ->
	    logger:log(normal, "~s: incomingproxy: Forward ~s ~s to ~p",
			[LogTag, Method, sipurl:print(URL), sipurl:print_hostport(Host, Port)]),
	    AddRoute = sipheader:contact_print([{none, {none, none, Host, Port, ["lr=true"]}}]),
	    NewHeader = keylist:prepend({"Route", AddRoute}, Header),
	    NewRequest = {Method, URL, NewHeader, Body},
	    proxy_request(THandler, NewRequest, URL, []);
	{me} ->
	    request_to_me(THandler, Request, LogStr);
	_ ->
	    logger:log(error, "~s: incomingproxy: Invalid Location ~p", [LogTag, Location]),
	    transactionlayer:send_response_handler(THandler, 500, "Server Internal Error")
    end.

proxy_request(THandler, Request, DstURL, Parameters) ->
    sipserver:safe_spawn(sippipe, start, [THandler, none, Request, DstURL, none, Parameters, 900]).

relay_request(THandler, {Method, OrigURI, Header, Body}, URI, LogTag) when Method == "CANCEL"; Method == "BYE" ->
    Request = {Method, OrigURI, Header, Body},
    logger:log(normal, "~s: incomingproxy: Relay ~s (unauthenticated)", [LogTag, sipurl:print(URI)]),
    sipserver:safe_spawn(sippipe, start, [THandler, none, Request, URI, none, [], 900]);

relay_request(THandler, Request, DstURI, LogTag) ->
    {Method, URI, Header, Body} = Request,
    case sipauth:get_user_verified_proxy(Header, Method) of
	{authenticated, User} ->
	    logger:log(debug, "Relay: User ~p is authenticated", [User]),
	    logger:log(normal, "~s: incomingproxy: Relay ~s (authenticated)", [LogTag, sipurl:print(DstURI)]),
	    sipserver:safe_spawn(sippipe, start, [THandler, none, Request, DstURI, none, [], 900]);
	stale ->
	    logger:log(debug, "Relay: STALE authentication, sending challenge"),
	    logger:log(normal, "~s: incomingproxy: Relay ~s -> STALE authentication -> 407 Proxy Authentication Required",
			[LogTag, sipurl:print(DstURI)]),
	    transactionlayer:send_challenge(THandler, proxy, true, none);
	false ->
	    logger:log(debug, "Relay: Failed authentication, sending challenge"),
	    logger:log(normal, "~s: incomingproxy: Relay ~s -> 407 Proxy Authorization Required", [LogTag, sipurl:print(DstURI)]),
	    transactionlayer:send_challenge(THandler, proxy, false, none);
	Unknown ->
	    logger:log(error, "relay_request: Unknown result from sipauth:get_user_verified_proxy() :~n~p", [Unknown]),
	    transactionlayer:send_response_handler(THandler, 500, "Server Internal Error")
    end.

response(Status, Reason, Header, Body, Socket, FromIP) ->
    LogStr = sipserver:make_logstr({response, Status, Reason, Header, Body}, FromIP),
    logger:log(normal, "Response to ~s: ~p ~s, no matching transaction - proxying statelessly", [LogStr, Status, Reason]),
    Response = {Status, Reason, Header, Body},
    transportlayer:send_proxy_response(none, Response).

request_to_homedomain(URL) ->
    request_to_homedomain(URL, init).

request_to_homedomain(URL, Recursing) ->
    {User, Pass, Host, Port, Parameters} = URL,
    logger:log(debug, "Routing: Request to homedomain, URI ~p", [sipurl:print(URL)]),

    Loc1 = local:lookupuser(URL),
    logger:log(debug, "Routing: lookupuser on ~p -> ~p", [sipurl:print(URL), Loc1]),

    case Loc1 of
	none ->
	    logger:log(debug, "Routing: ~s is one of our users, returning Temporarily Unavailable",
	    		[sipurl:print(URL)]),
	    {response, 480, "Users location currently unknown"};
	nomatch ->
	    request_to_homedomain_not_sipuser(URL, Recursing);
	Loc1 ->
	    Loc1
    end.

request_to_homedomain_not_sipuser(URL, loop) ->
    none;
request_to_homedomain_not_sipuser(URL, init) ->
    {User, Pass, Host, Port, Parameters} = URL,

    Loc1 = local:lookup_homedomain_url(URL),
    logger:log(debug, "Routing: local:lookup_homedomain_url on ~s -> ~p", [sipurl:print(URL), Loc1]),

    case Loc1 of
	none ->
	    % local:lookuppotn() returns 'none' if argument is not numeric,
	    % so we don't have to check that...
	    Res1 = local:lookuppotn(User),
	    logger:log(debug, "Routing: lookuppotn on ~s -> ~p", [User, Res1]),
	    Res1;
	{proxy, NewURL} ->
	    logger:log(debug, "Routing: request_to_homedomain_not_sipuser: Calling request_to_homedomain on result of local:lookup_homedomain_url (local URL ~s)",
	    		[sipurl:print(NewURL)]),
	    request_to_homedomain(NewURL, loop);
	{relay, Dst} ->
	    logger:log(debug, "Routing: request_to_homedomain_not_sipuser: Turning relay into proxy, original request was to a local domain"),
	    {proxy, Dst};
	_ ->
	    Loc1
    end.

request_to_me(THandler, {"OPTIONS", URI, Header, Body}, LogStr) ->
    logger:log(normal, "~s (to me) -> 200 OK", [LogStr]),
    logger:log(debug, "XXX The OPTIONS response SHOULD include Accept, Accept-Encoding, Accept-Language, and Supported headers. RFC 3261 section 11"),
    transactionlayer:send_response_handler(THandler, 200, "OK");

request_to_me(THandler, Request, LogStr) ->
    {Method, URI, Header, Body} = Request,
    logger:log(debug, "Routing: Dropping non-OPTIONS request to me - I have no state"),
    logger:log(normal, "~s -> 481 Call/Transaction Does Not Exist", [LogStr]),
    transactionlayer:send_response_handler(THandler, 481, "Call/Transaction Does Not Exist").

request_to_remote(URL) ->
    case local:lookup_remote_url(URL) of
	none ->
	    case local:get_user_with_contact(URL) of
		none ->
		    {_, _, Host, _, _} = URL,
		    logger:log(debug, "Routing: ~p is not a local domain, relaying", [Host]),
		    {relay, URL};
		SIPuser ->
		    logger:log(debug, "Routing: ~p is not a local domain, but it is a registered location of SIPuser ~p. Proxying.",
			       [sipurl:print(URL), SIPuser]),
		    {proxy, URL}
	    end;		
	Location ->
	    logger:log(debug, "Routing: local:lookup_remote_url() ~s -> ~p", [sipurl:print(URL), Location]),
	    Location
    end.

get_branch_from_handler(TH) ->
    CallBranch = transactionlayer:get_branch_from_handler(TH),
    case string:rstr(CallBranch, "-UAS") of
	0 ->
	    CallBranch;
	Index when integer(Index) ->
	    BranchBase = string:substr(CallBranch, 1, Index - 1),
	    BranchBase
    end.
