%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%% Handle processing of the pivot call
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(pivot_call).

-behaviour(gen_listener).

%% API
-export([start_link/2
         ,handle_resp/4
         ,handle_call_event/2
         ,stop_call/2
         ,new_request/5
        ]).

%% gen_server callbacks
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-include("pivot.hrl").

-define(DEFAULT_OPTS, [{response_format, binary}]).

-record(state, {
          voice_uri :: ne_binary()
         ,cdr_uri :: ne_binary()
         ,request_format = <<"twiml">> :: ne_binary()
         ,method = 'get' :: 'get' | 'post'
         ,call :: whapps_call:call()
         ,request_id :: ibrowse_req_id()
         ,request_params = [] :: proplist()
         ,response_body :: binary()
         ,response_content_type :: ne_binary()
         ,response_pid :: pid() %% pid of the processing of the response
         ,response_ref :: reference() %% monitor ref for the pid
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Call, JObj) ->
    CallId = whapps_call:call_id(Call),

    gen_listener:start_link(?MODULE, [{bindings, [{call, [{callid, CallId}
                                                          ,{restrict_to, [events, cdr]}
                                                         ]}
                                                 ]}
                                      ,{responders, [{{?MODULE, handle_call_event}
                                                      ,[{<<"*">>, <<"*">>}]}
                                                    ]}
                                     ], [Call, JObj]).

stop_call(Srv, Call) ->
    gen_listener:cast(Srv, {stop, Call}).

new_request(Srv, Call, Uri, Method, Params) ->
    gen_listener:cast(Srv, {request, Call, Uri, Method, Params}).

handle_call_event(JObj, Props) ->
    case props:get_value(pid, Props) of
        P when is_pid(P) -> whapps_call_command:relay_event(P, JObj);
        _ -> lager:debug("ignoring event ~p", [JObj])
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Call, JObj]) ->
    put(callid, whapps_call:call_id(Call)),

    Self = self(),
    spawn(fun() ->
                  ControllerQ = gen_listener:queue_name(Self),
                  lager:debug("controller queue: ~s", [ControllerQ]),
                  gen_listener:cast(Self, {controller_queue, ControllerQ})
          end),

    Method = wht_util:http_method(wh_json:get_value(<<"HTTP-Method">>, JObj, get)),
    VoiceUri = wh_json:get_value(<<"Voice-URI">>, JObj),

    ReqFormat = wh_json:get_value(<<"Request-Format">>, JObj, <<"twiml">>),
    BaseParams = wh_json:from_list(init_req_params(ReqFormat, Call)),

    lager:debug("starting pivot req to ~s to ~s", [Method, VoiceUri]),

    ?MODULE:new_request(Self, Call, VoiceUri, Method, BaseParams),

    {ok, #state{
       cdr_uri = wh_json:get_value(<<"CDR-URI">>, JObj)
       ,call = Call
      }, hibernate}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({request, Call, Uri, Method, Params}, State) ->
    {ok, ReqId} = send_req(Call, Uri, Method, Params),
    lager:debug("sent request ~p to '~s' via '~s'", [ReqId, Uri, Method]),
    {noreply, State#state{request_id=ReqId
                          ,request_params=Params
                          ,response_content_type = <<>>
                          ,response_body = <<>>
                          ,method=Method
                          ,voice_uri=Uri
                         }};

handle_cast({controller_queue, ControllerQ}, #state{call=Call}=State) ->
    %% TODO: Block on waiting for controller queue
    {noreply, State#state{call=whapps_call:set_controller_queue(ControllerQ, Call)}};

handle_cast({stop, Call}, #state{cdr_uri=undefined}=State) ->
    lager:debug("no cdr callback, server going down"),
    _ = whapps_call_command:hangup(Call),
    {stop, normal, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({ibrowse_async_headers, ReqId, "200", RespHeaders}, #state{request_id=ReqId}=State) ->
    CT = wh_util:to_binary(props:get_value("Content-Type", RespHeaders)),
    lager:debug("recv 200 response, content-type: ~s", [CT]),
    {noreply, State#state{response_content_type=CT}};

handle_info({ibrowse_async_headers, ReqId, "302", RespHeaders}, #state{voice_uri=Uri
                                                                       ,method=Method
                                                                       ,request_id=ReqId
                                                                       ,request_params=Params
                                                                       ,call=Call
                                                                      }=State) ->
    Redirect = props:get_value("Location", RespHeaders),
    lager:debug("recv 302: redirect to ~s", [Redirect]),
    Redirect1 = wht_util:resolve_uri(Uri, Redirect),

    ?MODULE:new_request(self(), Call, Redirect1, Method, Params),
    {noreply, State};

handle_info({ibrowse_async_response, ReqId, Chunk}, #state{request_id=ReqId
                                                           ,response_body=RespBody
                                                          }=State) ->
    lager:debug("adding response chunk: '~s'", [Chunk]),
    {noreply, State#state{response_body = <<RespBody/binary, Chunk/binary>>}, hibernate};

handle_info({ibrowse_async_response_end, ReqId}, #state{request_id=ReqId
                                                        ,response_body=RespBody
                                                        ,response_content_type=CT
                                                        ,call=Call
                                                       }=State) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(?MODULE, handle_resp, [Call, CT, RespBody, Self]),
    lager:debug("processing resp with ~p(~p)", [Pid, Ref]),
    {noreply, State#state{request_id = undefined
                          ,request_params = []
                          ,response_body = <<>>
                          ,response_content_type = <<>>
                          ,response_pid = Pid
                          ,response_ref = Ref
                         }, hibernate};

handle_info({'DOWN', Ref, process, Pid, Reason}, #state{response_pid=Pid, response_ref=Ref}=State) ->
    lager:debug("response pid ~p(~p) down: ~p", [Pid, Ref, Reason]),
    {noreply, State#state{response_pid=undefined}};

handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling messaging bus events
%%
%% @spec handle_event(JObj, State) -> {noreply, proplist()} |
%%                                    ignore
%% @end
%%--------------------------------------------------------------------
-spec handle_event/2 :: (wh_json:json_object(), #state{}) -> gen_listener:handle_event_return().
handle_event(_JObj, #state{response_pid=Pid}) ->
    {reply, [{pid, Pid}]}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    lager:debug("pivot call terminating: ~p", [_Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec send_req/4 :: (whapps_call:call(), nonempty_string() | ne_binary(), 'get' | 'post', wh_json:json_object()) -> any().
send_req(Call, Uri, get, BaseParams) ->
    UserParams = wht_translator:get_user_vars(Call),
    Params = wh_json:set_values(wh_json:to_proplist(BaseParams), UserParams),

    send(Call, uri(Uri, wh_json:to_querystring(Params)), get, [], []);

send_req(Call, Uri, post, BaseParams) ->
    UserParams = wht_translator:get_user_vars(Call),
    Params = wh_json:set_values(wh_json:to_proplist(BaseParams), UserParams),

    send(Call, Uri, post, [{"Content-Type", "application/x-www-form-urlencoded"}], wh_json:to_querystring(Params)).

-spec send/5 :: (whapps_call:call(), iolist(), atom(), wh_proplist(), iolist()) -> 
                        'ok' | {'stop', whapps_call:call()}.
send(Call, Uri, Method, ReqHdrs, ReqBody) ->
    lager:debug("sending req to ~s via ~s", [iolist_to_binary(Uri), Method]),

    Opts = [{stream_to, self()}
            | ?DEFAULT_OPTS
           ],

    case ibrowse:send_req(wh_util:to_list(Uri), ReqHdrs, Method, ReqBody, Opts) of
        {ibrowse_req_id, ReqId} ->
            lager:debug("response coming in asynchronosly to ~p", [ReqId]),
            {ok, ReqId};
        {ok, "200", RespHdrs, RespBody} ->
            lager:debug("recv 200: ~s", [RespBody]),
            handle_resp(Call, RespHdrs, RespBody);
        {ok, "302", Hdrs, _RespBody} ->
            Redirect = props:get_value("Location", Hdrs),
            lager:debug("recv 302: redirect to ~s", [Redirect]),
            Redirect1 = wht_util:resolve_uri(Uri, Redirect),
            send(Call, Redirect1, Method, ReqHdrs, ReqBody);
        {ok, _RespCode, _Hdrs, _RespBody} ->
            lager:debug("recv other: ~s: ~s", [_RespCode, _RespBody]),
            lager:debug("other hrds: ~p", [_Hdrs]),
            {stop, Call};
        {error, {conn_failed, {error, econnrefused}}} ->
            lager:debug("connection to host refused, going down"),
            {stop, Call};
        {error, _Reason} ->
            lager:debug("error with req: ~p", [_Reason]),
            {stop, Call}
    end.

handle_resp(Call, CT, RespBody, Srv) ->
    put(callid, whapps_call:call_id(Call)),
    case handle_resp(Call, CT, RespBody) of
        {stop, Call1} -> ?MODULE:stop_call(Srv, Call1);
        {ok, Call1} -> ?MODULE:stop_call(Srv, Call1);
        {request, Call1, Uri, Method, Params} -> ?MODULE:new_request(Srv, Call1, Uri, Method, Params)
    end.

handle_resp(Call, _, <<>>) ->
    lager:debug("no response body, continuing the flow"),
    whapps_call_command:hangup(Call);
handle_resp(Call, Hdrs, RespBody) when is_list(Hdrs) ->
    handle_resp(Call, props:get_value("Content-Type", Hdrs), RespBody);
handle_resp(Call, CT, RespBody) ->
    try kzt_translator:exec(Call, wh_util:to_list(RespBody), CT) of
        {stop, _Call1}=Stop ->
            lager:debug("translator says stop"),
            Stop;
        {ok, _Call1}=OK ->
            lager:debug("translator says ok, continuing"),
            OK;
        {request, _Call1, _Uri, _Method, _Params}=Req ->
            lager:debug("translator says make request to ~s", [_Uri]),
            Req
    catch
        throw:{error, no_translators, _CT} ->
            lager:debug("unknown content type ~s, no translators", [_CT]),
            {stop, Call};
        throw:{error, unrecognized_cmds} ->
            lager:debug("no translators recognize the supplied commands: ~s", [RespBody]),
            {stop, Call}
    end.

-spec uri/2 :: (ne_binary(), iolist()) -> iolist().
uri(URI, QueryString) ->
    case mochiweb_util:urlsplit(wh_util:to_list(URI)) of
        {Scheme, Host, Path, [], Fragment} ->
            mochiweb_util:urlunsplit({Scheme, Host, Path, QueryString, Fragment});
        {Scheme, Host, Path, QS, Fragment} ->
            mochiweb_util:urlunsplit({Scheme, Host, Path, [QS, "&", QueryString], Fragment})
    end.

-spec init_req_params/2 :: (ne_binary(), whapps_call:call()) -> proplist().
init_req_params(Format, Call) ->
    FmtBin = <<"wht_", Format/binary>>,
    try 
        FmtAtom = wh_util:to_atom(FmtBin),
        FmtAtom:req_params(Call)
    catch
        error:badarg ->
            case code:where_is_file(wh_util:to_list(<<FmtBin/binary, ".beam">>)) of
                non_existing -> [];
                _Path ->
                    wh_util:to_atom(FmtBin, true),
                    init_req_params(Format, Call)
            end;
        error:undef ->
            []
    end.