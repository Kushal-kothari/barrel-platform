%% Copyright 2016, Bernard Notarianni
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

-module(barrel_http_reply).
-author("Bernard Notarianni").

-export([doc/3]).
-export([json/3]).
-export([code/3]).

doc(Doc, Req, State ) ->
  Json = jsx:encode(Doc),
  json(Json, Req, State).

json(Json, Req, State) ->
  Headers = [{<<"content-type">>, <<"application/json">>}],
  reply(200, Headers, Json, Req, State).

code(HttpCode, Req, State ) ->
  reply(HttpCode, [], [], Req, State).

reply(HttpCode, Headers, Content, Req, State) ->
  H = [{<<"server">>, <<"BarrelDB (Erlang/OTP)">>} | Headers],
  {ok, Req2} = cowboy_req:reply(HttpCode, H, Content, Req),
  {ok, Req2, State}.