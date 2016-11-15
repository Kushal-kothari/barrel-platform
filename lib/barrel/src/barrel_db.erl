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

-module(barrel_db).
-author("Benoit Chesneau").
-behaviour(gen_server).

%% API
-export([
  start/3,
  stop/1,
  clean/1,
  infos/1,
  put/4,
  put_rev/5,
  get/3,
  delete/4,
  post/3,
  fold_by_id/4,
  changes_since/4,
  revsdiff/3,
  write_system_doc/3,
  read_system_doc/2,
  delete_system_doc/2
]).

-export([start_link/3]).

%% gen_server callbacks
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

%% internal processes
-define(default_timeout, 5000).

-define(IMAX1, 16#ffffFFFFffffFFFF).

%%%===================================================================
%%% Types
%%%===================================================================

-type state() :: #{}.

-type dbname() :: binary() | list() | atom().
-type doc() :: map().
-type rev() :: binary().
-type docid() :: binary().
-type read_options() :: [{rev, rev()} | {history, boolean()}
  | {max_history, integer()} | {ancestors, [rev()]}].
-type write_options() :: [{async, boolean()} | {timeout, integer()}].
-type db_options() :: [{creat_if_missing, boolean()}].

-export_type([
  dbname/0,
  doc/0,
  rev/0,
  docid/0,
  read_options/0,
  write_options/0,
  db_options/0
]).

%%%===================================================================
%%% API
%%%===================================================================

-spec start(binary(), atom(), db_options()) -> ok | {error, term()}.
start(Name, Store, Options) when is_binary(Name)->
  case whereis(Store) of
    PidStore when is_pid(PidStore) ->
      case gproc:where(db_key(Name)) of
        PidDb when is_pid(PidDb) ->
          ok;
        undefined ->
          case barrel_db_sup:start_db(Name, Store, Options) of
            {ok, _Pid} -> ok;
            {error, {already_started, _}} -> ok;
            {error, {{error, not_found}, _}} -> {error, not_found};
            Error -> Error
          end
      end;
    undefined ->
      {error, {unknown_store, Store}}
  end;
start(_, _, _) -> erlang:error(bad_db).

stop(Name) -> barrel_db_sup:stop_db(Name).

clean(Name) ->
  #{store := Store, id := DbId} = call(Name, get_state),
  barrel_store:clean_db(Store, Name, DbId),
  stop(Name).

infos(Name) -> call(Name, get_infos).

%% TODO: handle attachment
%% @doc get a document from its if
-spec get(dbname(), docid(), read_options())
    -> {ok, doc()} | {error, not_found} | {error, any()}.
get(Db, DocId, Options) ->
  Rev = proplists:get_value(rev, Options, <<"">>),
  WithHistory = proplists:get_value(history, Options, false),
  MaxHistory = proplists:get_value(max_history, Options, ?IMAX1),
  Ancestors = proplists:get_value(ancestors, Options, []),
  #{store := Store, id := DbId} = call(Db, get_state),
  barrel_store:get_doc(Store, DbId, DocId, Rev, WithHistory, MaxHistory, Ancestors).


%% @doc create or update a document. Return the new created revision
%% with the docid or a conflict.
-spec put(dbname(), docid(), doc(), write_options())
    -> {ok, docid(), rev()} | {error, {conflict, atom()}} | {error, any()}.
put(Db, DocId, Body, Options) when is_map(Body) ->
  Rev = barrel_doc:rev(Body),
  {Gen, _} = barrel_doc:parse_revision(Rev),
  Deleted = barrel_doc:deleted(Body),

  Lww = proplists:get_value(lww, Options, false),

  update_doc(
    Db,
    DocId,
    fun(DocInfo) ->
      #{ current_rev := CurrentRev, revtree := RevTree } = DocInfo,
      Res = case {Lww, Rev} of
              {true, _} ->
                if
                  CurrentRev /= <<>> ->
                    {CurrentGen, _} = barrel_doc:parse_revision(CurrentRev),
                    {ok, CurrentGen + 1, CurrentRev};
                  true ->
                    {ok, Gen + 1, <<>>}
                end;
              {false, <<>>} ->
                if
                  CurrentRev /= <<>> ->
                    case maps:get(CurrentRev, RevTree) of
                      #{deleted := true} ->
                        {CurrentGen, _} = barrel_doc:parse_revision(CurrentRev),
                        {ok, CurrentGen + 1, CurrentRev};
                      _ ->
                        {conflict, doc_exists}
                    end;
                  true ->
                    {ok, Gen + 1, Rev}
                end;
              {false, _} ->
                case barrel_revtree:is_leaf(Rev, RevTree) of
                  true -> {ok, Gen + 1, Rev};
                  false -> {conflict, revision_conflict}
                end
            end,

      case Res of
        {ok, NewGen, ParentRev} ->
          NewRev = barrel_doc:revid(NewGen, Rev, Body),
          RevInfo = #{  id => NewRev,  parent => ParentRev,  deleted => Deleted},
          RevTree2 = barrel_revtree:add(RevInfo, RevTree),
          Body2 = Body#{<<"_rev">> => NewRev},
          %% update the doc infos
          {WinningRev, Branched, Conflict} = barrel_revtree:winning_revision(RevTree2),
          DocInfo2 = DocInfo#{
            id => DocId,
            current_rev => WinningRev,
            branched => Branched,
            conflict => Conflict,
            revtree => RevTree2
          },
          {ok, DocInfo2, Body2, NewRev};
        Conflict ->
          Conflict
      end
    end,
    Options);
put(_, _, _, _) ->
  error(bad_doc).

%% @doc insert a specific revision to a a document. Useful for the replication.
%% It takes the document id, the doc to edit and the revision history (list of ancestors).
-spec put_rev(dbname(), docid(), doc(), [rev()], write_options())
    -> {ok, docid(), rev()} | {error, {conflict, atom()}} | {error, any()}.
put_rev(Db, DocId, Body, History, Options) ->
  [NewRev |_] = History,
  Deleted = barrel_doc:deleted(Body),
  update_doc(
    Db,
    DocId,
    fun(DocInfo) ->
      #{revtree := RevTree} = DocInfo,
      {Idx, Parent} = find_parent(History, RevTree, 0),
      if
        Idx =:= 0 -> ok;
        true ->
          ToAdd = lists:sublist(History, Idx),
          RevTree2 = edit_revtree(ToAdd, Parent, Deleted, RevTree),
          {WinningRev, Branched, Conflict} = barrel_revtree:winning_revision(RevTree2),
          DocInfo2 = DocInfo#{
            id => DocId,
            current_rev => WinningRev,
            branched => Branched,
            conflict => Conflict,
            revtree => RevTree2
          },
          Body2 = Body#{ <<"_rev">> => NewRev },
          {ok, DocInfo2, Body2, NewRev}
      end
    end,
    Options
  ).

%% @doc delete a document
-spec delete(dbname(), docid(), rev(), write_options())
    -> {ok, docid(), rev()} | {error, {conflict, atom()}} | {error, any()}.
delete(Db, DocId, RevId, Options) ->
  put(Db, DocId, #{ <<"_id">> => DocId, <<"_rev">> => RevId, <<"_deleted">> => true }, Options).

%% @doc create a document . Like put but only create a document without updating the old one.
%% A doc shouldn't have revision. Optionnaly the document ID can be set in the doc.
-spec post(dbname(),  doc(), write_options())
    -> {ok, docid(), rev()} | {error, {conflict, atom()}} | {error, any()}.
post(_Db, #{<<"_rev">> := _Rev}, _Options) -> {error, not_found};
post(Db, Doc, Options) ->
  DocId = case barrel_doc:id(Doc) of
            undefined -> barrel_lib:uniqid();
            Id -> Id
          end,
  put(Db, DocId, Doc#{<<"_id">> => DocId}, Options).

%% @doc fold all docs by Id
fold_by_id(Db, Fun, Acc, Opts) ->
  #{store := Store, id := DbId} = call(Db, get_state),
  barrel_store:fold_by_id(Store, DbId, Fun, Acc, Opts).

%% @doc fold all changes since last sequence
changes_since(Db, Since0, Fun, Acc) when is_integer(Since0) ->
  #{store := Store, id := DbId} = call(Db, get_state),
  Since = if
            Since0 > 0 -> Since0 + 1;
            true -> Since0
          end,
  barrel_store:changes_since(Store, DbId, Since, Fun, Acc).

revsdiff(Db, DocId, RevIds) ->
  #{store := Store, id := DbId} = call(Db, get_state),

  case barrel_store:get_doc_info(Store, DbId, DocId) of
    {ok, #{revtree := RevTree}} -> revsdiff1(RevTree, RevIds);
    {error, not_found} -> {ok, RevIds, []};
    Error -> Error
  end.

revsdiff1(RevTree, RevIds) ->
  {Missing, PossibleAncestors} = lists:foldl(
    fun(RevId, {M, A} = Acc) ->
      case barrel_revtree:contains(RevId, RevTree) of
        true -> Acc;
        false ->
          M2 = [RevId | M],
          {Gen, _} = barrel_doc:parse_revision(RevId),
          A2 = barrel_revtree:fold_leafs(
            fun(#{ id := Id}=RevInfo, A1) ->
              Parent = maps:get(parent, RevInfo, <<"">>),
              case lists:member(Id, RevIds) of
                true ->
                  {PGen, _} = barrel_doc:parse_revision(Id),
                  if
                    PGen < Gen -> [Id | A1];
                    PGen =:= Gen, Parent =/= <<"">> -> [Parent | A1];
                    true -> A1
                  end;
                false -> A1
              end
            end, A, RevTree),
          {M2, A2}
      end
    end, {[], []}, RevIds),
  {ok, lists:reverse(Missing), lists:usort(PossibleAncestors)}.

edit_revtree([RevId], Parent, Deleted, Tree) ->
  case Deleted of
    true ->
      barrel_revtree:add(#{ id => RevId, parent => Parent, deleted => true}, Tree);
    false ->
      barrel_revtree:add(#{ id => RevId, parent => Parent}, Tree)
  end;
edit_revtree([RevId | Rest], Parent, Deleted, Tree) ->
  Tree2 = barrel_revtree:add(#{ id => RevId, parent => Parent}, Tree),
  edit_revtree(Rest, Parent, Deleted, Tree2);
edit_revtree([], _Parent, _Deleted, Tree) ->
  Tree.

find_parent([RevId | Rest], RevTree, I) ->
  case barrel_revtree:contains(RevId, RevTree) of
    true -> {I, RevId};
    false -> find_parent(Rest, RevTree, I+1)
  end;
find_parent([], _RevTree, I) ->
  {I, <<"">>}.

update_doc(Db, DocId, Fun, Options) ->
  #{id := DbId} = call(Db, get_state),
  barrel_transactor:update_doc(DbId, DocId, Fun, Options).

write_system_doc(Db, DocId, Doc) ->
  #{store := Store, id := DbId} = call(Db, get_state),
  barrel_store:write_system_doc(Store, DbId, DocId, Doc).

read_system_doc(Db, DocId) ->
  #{store := Store, id := DbId} = call(Db, get_state),
  barrel_store:read_system_doc(Store, DbId, DocId).

delete_system_doc(Db, DocId) ->
  #{store := Store, id := DbId} = call(Db, get_state),
  barrel_store:delete_system_doc(Store, DbId, DocId).

-spec start_link(dbname(), atom(), db_options()) -> {ok, pid()}.
start_link(Name, Store, Options) ->
  gen_server:start_link(via(Name), ?MODULE, [Name, Store, Options], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%%%
-spec init(term()) -> {ok, state()}.
init([Name, Store, Options]) ->
  case init_db(Name, Store, Options) of
    {ok, State} ->
      process_flag(trap_exit, true),
      {ok, State};
    Error ->
      {stop, Error}
  end.

-spec handle_call(term(), term(), state()) -> {reply, term(), state()}.
handle_call(get_infos, _From, State) ->
  Infos = get_infos(State),
  {reply, {ok, Infos}, State};

handle_call(get_state, _From, State) ->
  {reply, State, State};

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
  {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({updated, Seq}, State = #{ name := Name }) ->
  barrel_db_event:notify(Name, db_updated),
  {noreply, State#{update_seq => Seq}};

handle_info({'EXIT', Pid, Reason},State) ->
  #{id := DbId,
    name := Name,
    store := Store,
    writer := WriterPid,
    options := Options}=State,
  if
    Pid =:= WriterPid ->
      lager:info("~p writer crashed: ~p~n", [Name, Reason]),
      %% the writer crashed, respawn it
      UpdateSeq = barrel_store:last_update_seq(Store, DbId),
      {ok, NewWriter} = barrel_transactor:start_link(self(), DbId, Store, Options),
      lager:info("~p new writer spawned: dbid=~p store=~p~n", [Name, DbId, Store]),
      {noreply, State#{update_seq => UpdateSeq, writer => NewWriter}};
    true ->
      {noreply, State}
  end;
handle_info(_Info, State) ->
  {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{writer := Writer}) ->
  exit(Writer, normal),
  ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

via(Name) ->
  {via, gproc, db_key(Name)}.

db_key(Name) -> {n, l, {barrel_db, Name}}.

call(Name, Req) -> gen_server:call(via(Name), Req).

init_db(Name, Store, Options) ->
  case barrel_store:open_db(Store, Name, Options) of
    {ok, {DbId, UpdateSeq}} ->
      %% spawn writer actor
      {ok, WriterPid} = barrel_transactor:start_link(self(), DbId, Store, UpdateSeq),
      %% return state
      {ok, #{
        id => DbId,
        store => Store,
        writer => WriterPid,
        name => Name,
        update_seq => UpdateSeq,
        options => Options
      }};
    Error ->
      Error
  end.

%% TODO: retrieve status from the store
get_infos(State) ->
  #{ id := Id, name := Name, store := Store} = State,
  #{
    id => Id,
    name => Name,
    store => Store
  }.