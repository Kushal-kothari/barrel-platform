%% Copyright 2017, Bernard Notarianni
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

-module(barrel_metrics_SUITE).
-author("Bernard Notarianni").

-export([ all/0
        , init_per_suite/1
        , end_per_suite/1
        , init_per_testcase/2
        , end_per_testcase/2
        ]).

-export([ basic_op/1
        ]).

all() -> [ basic_op
         ].

init_per_suite(Config) ->
  {ok, _} = application:ensure_all_started(barrel_store),
  Config.

init_per_testcase(_, Config) ->
  {ok, _} = barrel_store:create_db(<<"testdb">>, #{}),
  [{db, <<"testdb">>} | Config].

end_per_testcase(_, _Config) ->
  timer:sleep(10),
  ok = barrel_store:delete_db(<<"testdb">>),
  timer:sleep(200),
  ok.

end_per_suite(Config) ->
  application:stop(barrel_store),
  _ = (catch rocksdb:destroy("docs", [])),
  Config.

basic_op(_Config) ->
  barrel_metrics:reset_counters(),
  0 = barrel_metrics:get_counter(replication_doc_reads),
  1 = barrel_metrics:incr_counter(1, replication_doc_reads),
  1 = barrel_metrics:get_counter(replication_doc_reads),
  ok.

