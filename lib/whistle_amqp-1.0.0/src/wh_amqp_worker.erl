%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%% Worker with a dedicated targeted queue.
%%%
%%% Inserts Queue Name as the Server-ID and proxies the AMQP request
%%% (expects responses to the request)
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(wh_amqp_worker).

-behaviour(gen_listener).

%% API
-export([start_link/1]).
-export([call/4, call/5]).
-export([cast/3]).
-export([any_resp/1]).
-export([handle_resp/2]).
-export([send_request/4]).
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-include("amqp_util.hrl").

-type publish_fun() :: fun((api_terms()) -> _).
-type validate_fun() :: fun((api_terms()) -> boolean()).

-export_type([publish_fun/0, validate_fun/0]).

-record(state, {current_msg_id :: ne_binary()
                ,client_pid :: pid()
                ,client_ref :: reference()
                ,client_from :: {pid(), reference()}
                ,client_vfun :: fun((api_terms()) -> boolean())
                ,neg_resp :: wh_json:json_object()
                ,neg_resp_count = 0 :: non_neg_integer()
                ,neg_resp_threshold = 2 :: pos_integer()
                ,req_timeout_ref :: reference()
                ,req_start_time :: wh_now()
                ,callid :: ne_binary()
                ,pool_ref :: server_ref()
                ,defer_response = undefined :: 'undefined' | wh_json:json_object()
               }).

-define(FUDGE, 2600).

-define(BINDINGS, [{self, []}]).
-define(RESPONDERS, [{{?MODULE, handle_resp}, [{<<"*">>, <<"*">>}]}]).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

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
start_link(Args) ->
    gen_listener:start_link(?MODULE, [{bindings, ?BINDINGS}
                                      ,{responders, ?RESPONDERS}
                                      ,{queue_name, ?QUEUE_NAME}
                                      ,{queue_options, ?QUEUE_OPTIONS}
                                      ,{consume_options, ?CONSUME_OPTIONS}
                                     ], [Args]).

-spec call/4 :: (server_ref(), api_terms(), wh_amqp_worker:publish_fun(), wh_amqp_worker:validate_fun()) ->
                        {'ok', wh_json:json_object()} |
                        {'error', _}.
-spec call/5 :: (server_ref(), api_terms(), wh_amqp_worker:publish_fun(), wh_amqp_worker:validate_fun(), pos_integer()) ->
                        {'ok', wh_json:json_object()} |
                        {'error', _}.
call(Srv, Req, PubFun, VFun) ->
    call(Srv, Req, PubFun, VFun, 2000).

call(Srv, Req, PubFun, VFun, Timeout) ->
    case catch poolboy:checkout(Srv, false, 1000) of
        W when is_pid(W) ->
            PoolName = pool_name_from_server_ref(Srv),
            wh_counter:dec(<<"amqp.pools.", PoolName/binary, ".available">>),
            Prop = case wh_json:is_json_object(Req) of
                       true -> wh_json:to_proplist(Req);
                       false -> Req
                   end,
            Q = gen_listener:queue_name(W),
            Reply = gen_listener:call(W, {request, Prop, PubFun, VFun, Q, Timeout}, Timeout + ?FUDGE),
            poolboy:checkin(Srv, W),
            wh_counter:inc(<<"amqp.pools.", PoolName/binary, ".available">>),
            Reply;
        full ->
            lager:debug("failed to checkout worker: full"),
            {error, pool_full};
        _Else ->
            lager:debug("poolboy error: ~p", [_Else]),
            {error, poolboy_fault}
    end.

-spec cast/3 :: (server_ref(), api_terms(), wh_amqp_worker:publish_fun()) -> 'ok' | {'error', _}.
cast(Srv, Req, PubFun) ->
    case catch poolboy:checkout(Srv, false, 1000) of
        W when is_pid(W) ->
            poolboy:checkin(Srv, W),
            Prop = case wh_json:is_json_object(Req) of
                       true -> wh_json:to_proplist(Req);
                       false -> Req
                   end,
            gen_listener:cast(W, {publish, Prop, PubFun});
        full ->
            lager:debug("failed to checkout worker: full"),
            {error, pool_full};
        _Else ->
            lager:debug("poolboy error: ~p", [_Else]),
            {error, poolboy_fault}
    end.

-spec any_resp/1 :: (any()) -> 'true'.
any_resp(_) -> true.

-spec handle_resp/2 :: (wh_json:json_object(), proplist()) -> 'ok'.
handle_resp(JObj, Props) ->
    gen_listener:cast(props:get_value(server, Props), {event, wh_json:get_value(<<"Msg-ID">>, JObj), JObj}).

-spec send_request/4 :: (ne_binary(), ne_binary(), function(), proplist()) -> 'ok'.
send_request(CallID, Self, PublishFun, ReqProp) ->
    put(callid, CallID),
    Prop = [{<<"Server-ID">>, Self}
            ,{<<"Call-ID">>, CallID}
            | ReqProp],
    PublishFun(Prop).

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
init([Args]) ->
    process_flag(trap_exit, true),
    put(callid, ?LOG_SYSTEM_ID),
    lager:debug("starting amqp worker"),
    NegThreshold = props:get_value(neg_resp_threshold, Args, 2),
    Pool = props:get_value(name, Args, undefined),
    PoolName = pool_name_from_server_ref(Pool),
    wh_counter:inc(<<"amqp.pools.", PoolName/binary, ".available">>),
    {ok, #state{neg_resp_threshold=NegThreshold, pool_ref=Pool}}.

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
handle_call({request, ReqProp, PublishFun, VFun, Q, Timeout}, {ClientPid, _}=From, State) ->
    _ = wh_util:put_callid(ReqProp),
    CallID = get(callid),
    Self = self(),
    ClientRef = erlang:monitor(process, ClientPid),
    ReqRef = erlang:start_timer(Timeout, Self, req_timeout),
    {ReqProp1, MsgID} = case props:get_value(<<"Msg-ID">>, ReqProp) of
                            undefined ->
                                M = wh_util:rand_hex_binary(8),
                                {[{<<"Msg-ID">>, M} | ReqProp], M};
                            M -> {ReqProp, M}
                        end,
    lager:debug("published request with msg id ~s for ~p", [MsgID, ClientPid]),
    ?MODULE:send_request(CallID, Q, PublishFun, ReqProp1),
    {noreply, State#state{
                client_pid = ClientPid
                ,client_ref = ClientRef
                ,client_from = From
                ,client_vfun = VFun
                ,neg_resp_count = 0
                ,current_msg_id = MsgID
                ,req_timeout_ref = ReqRef
                ,req_start_time = erlang:now()
                ,callid = CallID
               }};
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

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
handle_cast({publish, ReqProp, PublishFun}, State) ->
    PublishFun(ReqProp),
    {noreply, State};    
handle_cast({set_negative_threshold, NegThreshold}, State) ->
    lager:debug("set negative threshold to ~p", [NegThreshold]),
    {noreply, State#state{neg_resp_threshold = NegThreshold}};
handle_cast({event, MsgId, JObj}, #state{current_msg_id = MsgId
                                         ,client_from = From
                                         ,client_vfun = VFun
                                         ,req_start_time = StartTime
                                         ,neg_resp_count = NegCount
                                         ,neg_resp_threshold = NegThreshold
                                        }=State) when NegCount < NegThreshold ->
    _ = wh_util:put_callid(JObj),
    case VFun(JObj) of
        true ->
            case wh_json:is_true(<<"Defer-Response">>, JObj) of
                false ->
                    lager:debug("response for msg id ~s took ~b micro to return", [MsgId, timer:now_diff(erlang:now(), StartTime)]),
                    gen_server:reply(From, {ok, JObj}),
                    {noreply, reset(State)};
                true ->
                    lager:debug("defered response for msg id ~s, waiting for primary response", [MsgId]),
                    {noreply, State#state{defer_response=JObj}}
            end;
        false ->
            lager:debug("response failed validator, waiting for more responses"),
            {noreply, State#state{neg_resp_count = NegCount + 1, neg_resp=JObj}, 0}
    end;
handle_cast({event, _MsgId, JObj}, #state{current_msg_id=_CurrMsgId}=State) ->
    _ = wh_util:put_callid(JObj),
    lager:debug("received unexpected message with old/expired message id: ~s, waiting for ~s", [_MsgId, _CurrMsgId]),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

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
handle_info(timeout, #state{neg_resp=ErrorJObj, neg_resp_count=Thresh, neg_resp_threshold=Thresh
                            ,client_from=From, defer_response=ReservedJObj
                           }=State) ->
    lager:debug("negative response threshold reached, returning last negative message"),
    case wh_util:is_empty(ReservedJObj) of
        true -> gen_server:reply(From, {error, ErrorJObj});
        false -> gen_server:reply(From, {ok, ReservedJObj})
    end,
    {noreply, reset(State)};
handle_info(timeout, State) ->
    {noreply, State};
handle_info({'DOWN', ClientRef, process, _Pid, _Reason}, #state{current_msg_id = _MsgID
                                                                ,client_ref = ClientRef
                                                                ,callid = CallID
                                                               }=State) ->
    put(callid, CallID),
    lager:debug("requestor processes ~p  died while waiting for msg id ~s", [_Pid, _MsgID]),
    {noreply, reset(State)};    
handle_info({timeout, ReqRef, req_timeout}, #state{current_msg_id= _MsgID, req_timeout_ref=ReqRef, callid=CallID
                                                   ,client_from=From, defer_response=ReservedJObj
                                                  }=State) ->
    put(callid, CallID),
    case wh_util:is_empty(ReservedJObj) of
        true -> 
            lager:debug("request timeout exceeded for msg id: ~s", [_MsgID]),
            gen_server:reply(From, {error, timeout});
        false -> 
            lager:debug("only received reserved response for msg id: ~s", [_MsgID]),
            gen_server:reply(From, {ok, ReservedJObj})
    end,
    {noreply, reset(State)};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Allows listener to pass options to handlers
%%
%% @spec handle_event(JObj, State) -> {reply, Options}
%% @end
%%--------------------------------------------------------------------
handle_event(_JObj, _State) ->
    {reply, []}.

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
terminate(_Reason, #state{pool_ref=Pool}) ->
    PoolName = pool_name_from_server_ref(Pool),
    wh_counter:dec(<<"amqp.pools.", PoolName/binary, ".available">>),
    lager:debug("amqp worker terminating: ~p", [_Reason]).

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
-spec reset/1 :: (#state{}) -> #state{}.
reset(#state{req_timeout_ref = ReqRef, client_ref = ClientRef}=State) ->
    put(callid, ?LOG_SYSTEM_ID),
    _ = case is_reference(ReqRef) of
            true -> erlang:cancel_timer(ReqRef);
            false -> ok
        end,
    _ = case is_reference(ClientRef) of
            true -> erlang:demonitor(ClientRef, [flush]);
            false -> ok
        end,
    State#state{client_pid = undefined
                ,client_ref = undefined
                ,client_from = undefined
                ,client_vfun = undefined
                ,neg_resp = undefined
                ,neg_resp_count = 0
                ,current_msg_id = undefined
                ,req_timeout_ref = undefined
                ,req_start_time = undefined
                ,callid = undefined
                ,defer_response = undefined
               }.

-spec pool_name_from_server_ref/1 :: (server_ref()) -> ne_binary().
pool_name_from_server_ref({_, Name}) when is_atom(Name)->
    wh_util:to_binary(Name);
pool_name_from_server_ref({via, _, Name}) when is_atom(Name) ->
    wh_util:to_binary(Name);
pool_name_from_server_ref(Name) when is_atom(Name) ->
    wh_util:to_binary(Name);
pool_name_from_server_ref(Pid) when is_pid(Pid) ->
    wh_util:to_binary(pid_to_list(Pid)).


    
