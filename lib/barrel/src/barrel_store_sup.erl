%% Copyright 2016, Benoit Chesneau
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

%% Created by benoitc on 03/09/16.

-module(barrel_store_sup).
-author("Benoit Chesneau").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

-spec init(any()) ->
  {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
  {ok, Stores} = application:get_env(barrel, stores),
  Children = lists:map(
    fun({Name, Config}) ->
      storage_spec(Name, Config)
    end, Stores),
  
  {ok, {{one_for_one, 5, 10}, Children}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
storage_spec(Name, Config) when is_map(Config) ->
  #{id => Name,
    start => {barrel_store, start_link, [Name, Config]},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [barrel_store]}.