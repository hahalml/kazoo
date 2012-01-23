%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%%
%%% @end
%%% Created : 13 Jan 2012 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(whapps_maintenance).

-include_lib("whistle/include/wh_databases.hrl").
-include_lib("whistle/include/wh_log.hrl").
-include_lib("whistle/include/wh_types.hrl").

-export([migrate/0]).
-export([find_invalid_acccount_dbs/0]).
-export([refresh/0, refresh/1]).
-export([blocking_refresh/0]).
-export([purge_doc_type/2]).
-export([cleanup_aggregated_account/1]).

-define(DEVICES_CB_LIST, <<"devices/crossbar_listing">>).
-define(MAINTENANCE_VIEW_FILE, <<"views/maintenance.json">>).
-define(ACCOUNTS_AGG_VIEW_FILE, <<"views/accounts.json">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec migrate/0 :: () -> ok.
migrate() ->
    couch_mgr:db_delete(<<"crossbar_schemas">>),
    couch_mgr:db_delete(<<"registrations">>),
    ts_responder:transfer_auth(),
    stepswitch_maintenance:refresh(),
    blocking_refresh(),
    whistle_number_manager_maintenance:reconcile(all),
    whapps_config:flush(),
    XbarUpdates = [fun(L) -> lists:delete(<<"cb_cdr">>, L) end
                   ,fun(L) -> lists:delete(<<"cb_signups">>, L) end
                   ,fun(L) -> lists:delete(<<"cb_resources">>, L) end
                   ,fun(L) -> [<<"cb_phone_numbers">> | lists:delete(<<"cb_phone_numbers">>, L)] end
                   ,fun(L) -> [<<"cb_templates">> | lists:delete(<<"cb_templates">>, L)] end
                   ,fun(L) -> [<<"cb_onboard">> | lists:delete(<<"cb_onboard">>, L)] end
                  ],
    StartModules = whapps_config:get(<<"crossbar">>, <<"autoload_modules">>, []),
    whapps_config:set_default(<<"crossbar">>
                          ,<<"autoload_modules">>
                          ,lists:foldr(fun(F, L) -> F(L) end, StartModules, XbarUpdates)),
    whapps_controller:stop_app(crossbar),
    whapps_controller:start_app(crossbar),
    ok.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec find_invalid_acccount_dbs/0 :: () -> [] | [ne_binary(),...].
find_invalid_acccount_dbs() ->
    lists:foldr(fun(AccountDb, Acc) ->
                        AccountId = wh_util:format_account_id(AccountDb, raw),
                        case couch_mgr:open_doc(AccountDb, AccountId) of
                            {error, not_found} ->
                                [AccountDb|Acc];
                            {ok, _} ->
                                Acc
                        end
                end, [], whapps_util:get_all_accounts()).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec blocking_refresh/0 :: () -> 'ok'.
blocking_refresh() ->
    do_refresh().

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec refresh/0 :: () -> 'started'.
-spec refresh/1 :: (ne_binary() | nonempty_string()) -> 'ok'.
-spec refresh/2 :: (ne_binary(), wh_json:json_objects()) -> 'ok'.

refresh() ->
    spawn(fun do_refresh/0),
    started.

do_refresh() ->
    refresh(?WH_SIP_DB),
    refresh(?WH_SCHEMA_DB),
    refresh(?WH_ACCOUNTS_DB),
    Views = [whapps_util:get_view_json(whistle_apps, ?MAINTENANCE_VIEW_FILE)
             ,whapps_util:get_view_json(conference, <<"views/conference.json">>)
             |whapps_util:get_views_json(crossbar, "account") 
             ++ whapps_util:get_views_json(callflow, "views")
            ],
    Accounts = whapps_util:get_all_accounts(),
    Total = length(Accounts),
    lists:foldr(fun(AccountDb, Current) ->
                        ?LOG("refreshing database (~p/~p) '~s'", [Current, Total, AccountDb]),
                        case refresh(AccountDb, Views) of
                            ok -> Current + 1;
                            remove -> Current + 1
                        end
                end, 1, Accounts).

refresh(?WH_SIP_DB) ->
    couch_mgr:db_create(?WH_SIP_DB),
    couch_mgr:revise_doc_from_file(?WH_SIP_DB, registrar, <<"auth.json">> ),
    case couch_mgr:all_docs(?WH_SIP_DB, [{<<"include_docs">>, true}]) of
        {ok, JObjs} ->
            [cleanup_aggregated_device(wh_json:get_value(<<"doc">>, JObj)) || JObj <- JObjs];
        _ ->
            ok
    end;
refresh(?WH_SCHEMA_DB) ->
    couch_mgr:db_create(?WH_SCHEMA_DB),
    couch_mgr:revise_docs_from_folder(?WH_SCHEMA_DB, crossbar, "schemas");
refresh(?WH_ACCOUNTS_DB) ->
    couch_mgr:db_create(?WH_ACCOUNTS_DB),
    case couch_mgr:all_docs(?WH_ACCOUNTS_DB, [{<<"include_docs">>, true}]) of
        {ok, JObjs} ->
            [cleanup_aggregated_account(wh_json:get_value(<<"doc">>, JObj)) || JObj <- JObjs];
        _ ->
            ok
    end,
    couch_mgr:revise_doc_from_file(?WH_ACCOUNTS_DB, whistle_apps, ?ACCOUNTS_AGG_VIEW_FILE),
    couch_mgr:revise_doc_from_file(?WH_ACCOUNTS_DB, whistle_apps, ?MAINTENANCE_VIEW_FILE),
    ok;
refresh(<<Account/binary>>) ->
    Views = [whapps_util:get_view_json(whistle_apps, ?MAINTENANCE_VIEW_FILE)
             ,whapps_util:get_view_json(conference, <<"views/conference.json">>)
             |whapps_util:get_views_json(crossbar, "account") 
             ++ whapps_util:get_views_json(callflow, "views")
            ],
    refresh(Account, Views);
refresh(Account) ->
    refresh(wh_util:to_binary(Account)).

refresh(Account, Views) ->
    AccountDb = wh_util:format_account_id(Account, encoded),
    AccountId = wh_util:format_account_id(Account, raw),
    case couch_mgr:open_doc(AccountDb, AccountId) of
        {error, not_found} ->
            case couch_mgr:open_doc(?WH_ACCOUNTS_DB, AccountId) of
                {ok, Def} ->
                    ?LOG("account is missing its local account definition, but it was recovered from the accounts db"),
                    couch_mgr:ensure_saved(AccountDb, wh_json:delete_key(<<"_rev">>, Def));
                {error, not_found} ->
                    ?LOG("account is missing its local account definition, and it doesnt exist in the accounts db. REMOVING!")
            end,
            remove;
        {ok, JObj} ->
            couch_mgr:ensure_saved(?WH_ACCOUNTS_DB, JObj),
            AccountRealm = crossbar_util:get_account_realm(AccountDb, AccountId),
            case couch_mgr:get_results(AccountDb, ?DEVICES_CB_LIST, [{<<"include_docs">>, true}]) of
                {ok, Devices} ->
                    _ = [whapps_util:add_aggregate_device(AccountDb, wh_json:get_value(<<"doc">>, Device))
                         || Device <- Devices
                                ,wh_json:get_ne_value([<<"doc">>, <<"sip">>, <<"realm">>], Device, AccountRealm) =/= AccountRealm
                        ],
                    _ = [whapps_util:rm_aggregate_device(AccountDb, wh_json:get_value(<<"doc">>, Device)) 
                         || Device <- Devices
                                ,wh_json:get_ne_value([<<"doc">>, <<"sip">>, <<"realm">>], Device, AccountRealm) =:= AccountRealm
                        ];
                {error, _} ->
                    ok
            end,
            whapps_util:update_views(AccountDb, Views)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec cleanup_aggregated_account/1 :: (wh_json:json_object()) -> ok.
cleanup_aggregated_account(Account) ->
    AccountDb = wh_json:get_value(<<"pvt_account_db">>, Account),
    case AccountDb =/= undefined andalso (couch_mgr:db_exists(AccountDb) =/= true) of
        true ->
            ?LOG("removing aggregated account for missing db ~s", [AccountDb]),
            couch_mgr:del_doc(?WH_ACCOUNTS_DB, Account);
         false ->
            ok
    end,
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec cleanup_aggregated_device/1 :: (wh_json:json_object()) -> ok.
cleanup_aggregated_device(Device) ->
    AccountDb = wh_json:get_value(<<"pvt_account_db">>, Device),
    case AccountDb =/= undefined andalso (couch_mgr:db_exists(AccountDb) =/= true) of
        true ->
            ?LOG("removing aggregated device for missing db ~s", [AccountDb]),
            couch_mgr:del_doc(?WH_SIP_DB, Device);
         false ->
            ok
    end,
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec purge_doc_type/2 :: (ne_binary(), ne_binary()) -> ok | {error, term()}.
purge_doc_type(Type, Account) when not is_binary(Type) ->
    purge_doc_type(wh_util:to_binary(Type), Account);
purge_doc_type(Type, Account) when not is_binary(Account) ->
    purge_doc_type(Type, wh_util:to_binary(Account));
purge_doc_type(Type, Account) ->
    Db = wh_util:format_account_id(Account, encoded),
    case couch_mgr:get_results(Db, {<<"maintenance">>, <<"listing_by_type">>}, [{<<"key">>, Type}, {<<"include_docs">>, true}]) of
        {ok, JObjs} ->
            couch_mgr:del_docs(Db, [wh_json:get_value(<<"doc">>, JObj) || JObj <- JObjs]);
        {error, _}=E ->
            E
    end.