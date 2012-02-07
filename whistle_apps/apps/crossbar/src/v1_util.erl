%%%-------------------------------------------------------------------
%%% @author James Aimonetti <>
%%% @copyright (C) 2012, James Aimonetti
%%% @doc
%%% Moved util functions out of v1_resource so only REST-related calls
%%% are in there.
%%% @end
%%% Created :  5 Feb 2012 by James Aimonetti <>
%%%-------------------------------------------------------------------
-module(v1_util).

-export([is_cors_preflight/1, is_cors_request/1, add_cors_headers/2
         ,allow_methods/4, parse_path_tokens/1
         ,get_req_data/2, get_http_verb/2
         ,is_authentic/2, is_permitted/2
         ,is_known_content_type/2, content_types_provided/2
        ]).

-include("crossbar.hrl").

-type cowboy_multipart_response() :: {{headers, cowboy_http:headers()} |
                                      {data, binary()} | end_of_part | eof,
                                      #http_req{}
                                     }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempts to determine if this is a cross origin resource preflight
%% request
%% @end
%%--------------------------------------------------------------------
-spec is_cors_preflight/1 :: (#http_req{}) -> {boolean(), #http_req{}}.
is_cors_preflight(Req0) ->
    case is_cors_request(Req0) of
        {true, Req1} ->
            case cowboy_http_req:method(Req1) of
                {'OPTIONS', Req2} -> {true, Req2};
                {_, Req2} -> {false, Req2}
            end;
        Nope -> Nope
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempts to determine if this is a cross origin resource sharing
%% request
%% @end
%%--------------------------------------------------------------------
-spec is_cors_request/1 :: (#http_req{}) -> {boolean(), #http_req{}}.
is_cors_request(Req0) ->
    case cowboy_http_req:header(<<"Origin">>, Req0) of
        {undefined, Req1} ->
            case cowboy_http_req:header(<<"Access-Control-Request-Method">>, Req1) of
                {undefined, Req2} ->
                    case cowboy_http_req:header(<<"Access-Control-Request-Headers">>, Req2) of
                        {undefined, Req3} -> {false, Req3};
                        {_, Req3} -> {true, Req3}
                    end;
                {_, Req2} -> {true, Req2}
            end;
        {_, Req1} -> {true, Req1}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_cors_headers/2 :: (#http_req{}, #cb_context{}) -> {'ok', #http_req{}}.
add_cors_headers(Req0, Context) ->
    lists:foldl(fun({H, V}, {ok, ReqAcc}) ->
                        cowboy_http_req:set_resp_header(H, V, ReqAcc)
                end, {ok, Req0}, get_cors_headers(Context)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec get_cors_headers/1 :: (#cb_context{}) -> [{ne_binary(), ne_binary()},...].
get_cors_headers(#cb_context{allow_methods=Allowed}) ->
    [
      {<<"Access-Control-Allow-Origin">>, <<"*">>}
     ,{<<"Access-Control-Allow-Methods">>, wh_util:join_binary([wh_util:to_binary(A) || A <- Allowed], <<", ">>)}
     ,{<<"Access-Control-Allow-Headers">>, <<"Content-Type, Depth, User-Agent, X-File-Size, X-Requested-With, If-Modified-Since, X-File-Name, Cache-Control, X-Auth-Token, If-Match">>}
     ,{<<"Access-Control-Expose-Headers">>, <<"Content-Type, X-Auth-Token, X-Request-ID, Location, Etag, ETag">>}
     ,{<<"Access-Control-Max-Age">>, wh_util:to_binary(?SECONDS_IN_DAY)}
    ].

-spec get_req_data/2 :: (#cb_context{}, #http_req{}) -> {#cb_context{}, #http_req{}}.
get_req_data(Context, Req0) ->
    {ContentType, Req1} = cowboy_http_req:header(<<"Content-Type">>, Req0),
    {QS, Req2} = cowboy_http_req:qs_vals(Req1),

    case ContentType of
        "multipart/form-data" ++ _ ->
            extract_multipart(Context#cb_context{query_json=QS}, Req2);
        "application/x-www-form-urlencoded" ++ _ ->
            extract_multipart(Context#cb_context{query_json=QS}, Req2);
        "application/json" ++ _ ->
            {JSON, Req3_1} = get_json_body(Req2),
            {Context#cb_context{req_json=JSON, query_json=QS}, Req3_1};
        "application/x-json" ++ _ ->
            {JSON, Req3_1} = get_json_body(Req2),
            {Context#cb_context{req_json=JSON, query_json=QS}, Req3_1};
        _CT ->
            ?LOG("unknown content-type: ~s", [_CT]),
            extract_file(Context#cb_context{query_json=QS}, Req2)
    end.

-spec extract_multipart/2 :: (#cb_context{}, #http_req{}) -> {#cb_context{}, #http_req{}}.
extract_multipart(#cb_context{req_files=Files}=Context, #http_req{}=Req0) ->
    case extract_multipart_content(cowboy_http_req:multipart_data(Req0), wh_json:new()) of
        {eof, Req1} -> {Context, Req1};
        {end_of_part, JObj, Req1} -> extract_multipart(Context#cb_context{req_files=[JObj|Files]}, Req1)
    end.

-spec extract_multipart_content/2 :: (cowboy_multipart_response(), wh_json:json_object()) -> {'end_of_part', wh_json:json_object(), #http_req{}} | {'eof', #http_req{}}.
extract_multipart_content({eof, _}=EOF, _) -> EOF;
extract_multipart_content({end_of_part, Req}, JObj) -> {end_of_part, JObj, Req};
extract_multipart_content({headers, Headers, Req}, JObj) ->
    extract_multipart_content(cowboy_http_req:multipart_data(Req), wh_json:set_value(<<"headers">>, Headers, JObj));
extract_multipart_content({{data, Datum}, Req}, JObj) ->
    Data = wh_json:get_value(<<"data">>, JObj),
    extract_multipart_content(cowboy_http_req:multipart_data(Req), wh_json:set_value(<<"data">>, <<Data/binary, Datum/binary>>, JObj)).

-spec extract_file/2 :: (#cb_context{}, #http_req{}) -> {#cb_context{}, #http_req{}}.
extract_file(Context, Req0) ->
    case cowboy_http_req:body(Req0) of
        {error, badarg} -> {Context, Req0};
        {ok, FileContents, Req1} ->
            {ContentType, Req2} = cowboy_http_req:header(<<"Content-Type">>, Req1),
            {ContentLength, Req3} = cowboy_http_req:header(<<"Content-Length">>, Req2),

            Headers = wh_json:from_list([{<<"content_type">>, ContentType}
                                         ,{<<"content_length">>, ContentLength}
                                        ]),
            FileJObj = wh_json:from_list([{<<"headers">>, Headers}
                                          ,{<<"contents">>, FileContents}
                                         ]),

            {Context#cb_context{req_files=[{<<"uploaded_file">>, FileJObj}]}, Req3}
    end.

-spec get_json_body/1 :: (#http_req{}) -> {wh_json:json_object(), #http_req{}} |
                                           {{'malformed', ne_binary()}, #http_req{}}.
get_json_body(Req0) ->
    case cowboy_http_req:body(Req0) of
        {ok, <<>>, Req2} -> {wh_json:new(), Req2};
        {ok, ReqBody, Req2} ->
            try wh_json:decode(ReqBody) of
                JObj ->
                    case is_valid_request_envelope(JObj) of
                        true ->
                            {ok, JObj, Req2};
                        false ->
                            ?LOG("invalid request envelope"),
                            {{malformed, <<"Invalid request envelope">>}, Req2}
                    end
            catch
                _:{badmatch, {comma,{decoder,_,S,_,_,_}}} ->
            ?LOG("failed to decode json: comma error around char ~s", [wh_util:to_list(S)]),
                    {{malformed, list_to_binary(["Failed to decode: comma error around char ", wh_util:to_list(S)])}, Req2};
                _:E ->
                    ?LOG("failed to decode json: ~p", [E]),
                    {{malformed, <<"JSON failed to validate; check your commas and curlys">>}, Req2}
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Determines if the request envelope is valid
%% @end
%%--------------------------------------------------------------------
-spec is_valid_request_envelope/1 :: (wh_json:json_object()) -> boolean().
is_valid_request_envelope(JSON) ->
    wh_json:get_value([<<"data">>], JSON, undefined) =/= undefined.


-spec get_http_verb/2 :: (http_method(), #cb_context{}) -> ne_binary().
get_http_verb(Method, #cb_context{req_data=ReqData, query_json=ReqQs}) ->
    case wh_json:get_value(<<"verb">>, ReqData) of
        undefined ->
            case wh_json:get_value(<<"verb">>, ReqQs) of
                undefined -> wh_util:to_lower_binary(Method);
                Verb -> wh_util:to_lower_binary(Verb)
            end;
        Verb -> wh_util:to_lower_binary(Verb)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will loop over the Tokens in the request path and return
%% a proplist with keys being the module and values a list of parameters
%% supplied to that module.  If the token order is improper a empty list
%% is returned.
%% @end
%%--------------------------------------------------------------------

-type cb_mod_with_tokens() :: {ne_binary(), path_tokens()}.
-spec parse_path_tokens/1 :: (wh_json:json_strings()) -> [cb_mod_with_tokens(),...] | [].
parse_path_tokens(Tokens) ->
    Loaded = [ wh_util:to_binary(Mod) || {Mod, _, _, _} <- supervisor:which_children(crossbar_module_sup) ],
    parse_path_tokens(Tokens, Loaded, []).

-spec parse_path_tokens/3 :: (wh_json:json_strings(), wh_json:json_strings(), [cb_mod_with_tokens(),...] | []) -> [cb_mod_with_tokens(),...] | [].
parse_path_tokens([], _Loaded, Events) ->
    Events;
parse_path_tokens([Mod|T], Loaded, Events) ->
    case lists:member(<<"cb_", (Mod)/binary>>, Loaded) of
        false ->
            ?LOG("failed to find ~s in loaded cb modules", [Mod]),
            [];
        true ->
            {Params, List2} = lists:splitwith(fun(Elem) -> not lists:member(<<"cb_", (Elem)/binary>>, Loaded) end, T),
            Params1 = [ wh_util:to_binary(P) || P <- Params ],
            parse_path_tokens(List2, Loaded, [{Mod, Params1} | Events])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will find the intersection of the allowed methods
%% among event respsonses.  The responses can only veto the list of
%% methods, they can not add.
%%
%% If a client passes a ?verb=(PUT|DELETE) on a POST request, ReqVerb will
%% be <<"put">> or <<"delete">>, while HttpVerb is 'POST'. If the allowed
%% methods do not include 'POST', we need to add it if allowed methods include
%% the verb in ReqVerb.
%% So, POSTing a <<"put">>, and the allowed methods include 'PUT', insert POST
%% as well.
%% POSTing a <<"delete">>, and 'DELETE' is NOT in the allowed methods, remove
%% 'POST' from the allowed methods.
%% @end
%%--------------------------------------------------------------------
-spec allow_methods/4  :: ([{term(), term()},...], http_methods(), ne_binary(), atom()) -> http_methods().
allow_methods(Responses, Available, ReqVerb, HttpVerb) ->
    case crossbar_bindings:succeeded(Responses) of
        [] -> Available;
        Succeeded ->
            AllowedSet = lists:foldr(fun({true, Response}, Acc) ->
                                             Set = sets:from_list(Response),
                                             sets:intersection(Acc, Set)
                                     end, Available, Succeeded),
            maybe_add_post_method(ReqVerb, HttpVerb, sets:to_list(AllowedSet))
    end.

%% insert 'POST' if Verb is in Allowed; otherwise remove 'POST'.
-spec maybe_add_post_method/3 :: (ne_binary(), http_methods(), [http_methods(),...]) -> [http_methods(),...].
maybe_add_post_method(Verb, 'POST', Allowed) ->
    VerbAtom = list_to_atom(string:to_upper(binary_to_list(Verb))),
    case lists:member(VerbAtom, Allowed) of
        true -> ['POST' | Allowed];
        false -> lists:delete('POST', Allowed)
    end;
maybe_add_post_method(_, _, Allowed) ->
    Allowed.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use event bindings to determine if the client has
%% provided a valid authentication token
%% @end
%%--------------------------------------------------------------------
-spec is_authentic/2 :: (#http_req{}, #cb_context{}) -> {{'false', []} | 'true', #http_req{}, #cb_context{}}.
is_authentic(Req, #cb_context{req_verb = <<"options">>}=Context) ->
    %% all OPTIONS, they are harmless (I hope) and required for CORS preflight
    {true, Req, Context};
is_authentic(Req0, Context0) ->
    Event = <<"v1_resource.authenticate">>,
    case crossbar_bindings:succeeded(crossbar_bindings:map(Event, {Req0, Context0})) of
        [] -> {{false, []}, Req0, Context0};
        [{true, {Req1, Context1}}|_] -> {true, Req1, Context1}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use event bindings to determine if the client is
%% authorized for this request
%% @end
%%--------------------------------------------------------------------
-spec is_permitted/2 :: (#http_req{}, #cb_context{}) -> {boolean(), #http_req{}, #cb_context{}}.
is_permitted(Req, #cb_context{req_verb = <<"options">>}=Context) ->
    ?LOG("options requests are permitted by default"),
    %% all all OPTIONS, they are harmless (I hope) and required for CORS preflight
    {true, Req, Context};
is_permitted(Req0, Context0) ->
    Event = <<"v1_resource.authorize">>,
    case crossbar_bindings:succeeded(crossbar_bindings:map(Event, {Req0, Context0})) of
        [] ->
            ?LOG("no on authz the request"),
            {false, Req0, Context0};
        [{true, {Req1, Context1}}|_] ->
            ?LOG("request was authz"),
            {true, Req1, Context1}
    end.

-spec is_known_content_type/2 :: (#http_req{}, #cb_context{}) -> {boolean(), #http_req{}, #cb_context{}}.
is_known_content_type(Req0, #cb_context{req_nouns=Nouns}=Context0) ->
    #cb_context{content_types_accepted=CTAs}=Context1 = lists:foldr(fun({Mod, Params}, ContextAcc) ->
                                                                           Event = <<"v1_resource.content_types_accepted.", Mod/binary>>,
                                                                           Payload = {Req0, ContextAcc, Params},
                                                                           {_, ContextAcc1, _} = crossbar_bindings:fold(Event, Payload),
                                                                           ContextAcc1
                                                                   end, Context0, Nouns),
    CTA = lists:foldr(fun({_Fun, L}, Acc) ->
                              lists:foldl(fun(ContentType, Acc1) ->
                                                  [ContentType | Acc1]
                                          end, Acc, L);
                         (L, Acc) ->
                              lists:foldl(fun(ContentType, Acc1) ->
                                                  [ContentType | Acc1]
                                          end, Acc, L)
                      end, [], CTAs),

    {CT, Req1} = cowboy_http_req:header(<<"Content-Type">>, Req0, ?DEFAULT_CONTENT_TYPE),
    ?LOG("is ~s acceptable: ~s", [CT, lists:member(CT, CTA)]),
    {lists:member(CT, CTA), Req1, Context1#cb_context{content_types_accepted=CTA}}.

-spec content_types_provided/2 :: (#http_req{}, #cb_context{}) -> {[{ne_binary(), ne_binary(), proplist()},...] | [], #http_req{}}.
content_types_provided(Req0, Context0) ->
    {[], Req0}.