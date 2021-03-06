%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_auth_mongo).

-behaviour(ecpool_worker).

-include("emqx_auth_mongo.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/types.hrl").

-export([ register_metrics/0
        , check/3
        , description/0
        ]).

-export([ replvar/2
        , replvars/2
        , connect/1
        , query/2
        , query_multi/2
        ]).

-spec(register_metrics() -> ok).
register_metrics() ->
    lists:foreach(fun emqx_metrics:ensure/1, ?AUTH_METRICS).

check(ClientInfo = #{password := Password}, AuthResult,
      #{authquery := AuthQuery, superquery := SuperQuery}) ->
    #authquery{collection = Collection, field = Fields,
               hash = HashType, selector = Selector} = AuthQuery,
    case query(Collection, maps:from_list(replvars(Selector, ClientInfo))) of
        undefined -> emqx_metrics:inc(?AUTH_METRICS(ignore));
        {error, Reason} ->
            ?LOG(error, "[MongoDB] Can't connect to MongoDB server: ~0p", [Reason]),
            ok = emqx_metrics:inc(?AUTH_METRICS(failure)),
            {stop, AuthResult#{auth_result => not_authorized, anonymous => false}};
        UserMap ->
            Result = case [maps:get(Field, UserMap, undefined) || Field <- Fields] of
                        [undefined] -> {error, password_error};
                        [PassHash] ->
                            check_pass({PassHash, Password}, HashType);
                        [PassHash, Salt|_] ->
                            check_pass({PassHash, Salt, Password}, HashType)
                     end,
            case Result of
                ok ->
                    ok = emqx_metrics:inc(?AUTH_METRICS(success)),
                    {stop, AuthResult#{is_superuser => is_superuser(SuperQuery, ClientInfo),
                                       anonymous => false,
                                       auth_result => success}};
                {error, Error} ->
                    ?LOG(error, "[MongoDB] check auth fail: ~p", [Error]),
                    ok = emqx_metrics:inc(?AUTH_METRICS(failure)),
                    {stop, AuthResult#{auth_result => Error, anonymous => false}}
            end
    end.

check_pass(Password, HashType) ->
    case emqx_passwd:check_pass(Password, HashType) of
        ok -> ok;
        {error, _Reason} -> {error, not_authorized}
    end.

description() -> "Authentication with MongoDB".

%%--------------------------------------------------------------------
%% Is Superuser?
%%--------------------------------------------------------------------

-spec(is_superuser(maybe(#superquery{}), emqx_types:clientinfo()) -> boolean()).
is_superuser(undefined, _ClientInfo) ->
    false;
is_superuser(#superquery{collection = Coll, field = Field, selector = Selector}, ClientInfo) ->
    Row = query(Coll, maps:from_list(replvars(Selector, ClientInfo))),
    case maps:get(Field, Row, false) of
        true   -> true;
        _False -> false
    end.

replvars(VarList, ClientInfo) ->
    lists:map(fun(Var) -> replvar(Var, ClientInfo) end, VarList).

replvar({Field, <<"%u">>}, #{username := Username}) ->
    {Field, Username};
replvar({Field, <<"%c">>}, #{clientid := ClientId}) ->
    {Field, ClientId};
replvar({Field, <<"%C">>}, #{cn := CN}) ->
    {Field, CN};
replvar({Field, <<"%d">>}, #{dn := DN}) ->
    {Field, DN};
replvar(Selector, _ClientInfo) ->
    Selector.

%%--------------------------------------------------------------------
%% MongoDB Connect/Query
%%--------------------------------------------------------------------

connect(Opts) ->
    Type = proplists:get_value(type, Opts, single),
    Hosts = proplists:get_value(hosts, Opts, []),
    Options = proplists:get_value(options, Opts, []),
    WorkerOptions = proplists:get_value(worker_options, Opts, []),
    mongo_api:connect(Type, Hosts, Options, WorkerOptions).

query(Collection, Selector) ->
    ecpool:with_client(?APP, fun(Conn) -> mongo_api:find_one(Conn, Collection, Selector, #{}) end).

query_multi(Collection, SelectorList) ->
    lists:foldr(fun(Selector, Acc) ->
        case query(Collection, Selector) of
            undefined -> Acc;
            Result -> [Result|Acc]
        end
    end, [], SelectorList).
