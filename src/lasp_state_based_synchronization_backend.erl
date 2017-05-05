%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Christopher S. Meiklejohn.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(lasp_state_based_synchronization_backend).
-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_server).
-behaviour(lasp_synchronization_backend).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([blocking_sync/1]).

%% @project transaction feature
%% transaction function API
-export([enable_transaction/0,new_transaction/2]).

%% lasp_synchronization_backend callbacks
-export([extract_log_type_and_payload/1]).

-include("lasp.hrl").

%% State record.
-record(state, {store :: store(),
                gossip_peers :: [],
                actor :: binary(),
                current_transaction_id ,
                last_done_transaction_id :: dict:dict(),
                blocking_syncs :: dict:dict(),
                pending_transaction :: dict:dict() %% @project transaction feature
                }).

%%%===================================================================
%%% lasp_synchronization_backend callbacks
%%%===================================================================

%% state_based messages:
extract_log_type_and_payload({state_ack, _From, _Id, {_Id, _Type, _Metadata, State}}) ->
    [{state_ack, State}];
extract_log_type_and_payload({state_send, _Node, {Id, Type, _Metadata, State}, _AckRequired}) ->
    [{Id, State}, {Type, State}, {state_send, State}, {state_send_protocol, Id}];

%% @project adding handler for transaction_ack, transaction_send msg
extract_log_type_and_payload({transaction_ack, From, Transactions})->
  [{transaction_ack, From, Transactions}];

extract_log_type_and_payload({transaction_send, From, Transactions })->
  [{transaction_send, From, Transactions }].

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start and link to calling process.
-spec start_link(list())-> {ok, pid()} | ignore | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

blocking_sync(ObjectFilterFun) ->
    gen_server:call(?MODULE, {blocking_sync, ObjectFilterFun}, infinity).

%% @project transaction feature
%% will enable the transaction feature
enable_transaction() ->
    gen_server:call(?MODULE, {enable_transaction}, infinity).

%% @project transaction feature
%% NEW API function
new_transaction(Transaction, Actor)->
  gen_server:call(?MODULE, {transaction, Transaction, Actor}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init([term()]) -> {ok, #state{}}.
init([Store, Actor]) ->
    %% Seed the process at initialization.
    ?SYNC_BACKEND:seed(),

    %% @project  disable the schedule_state_synchronization here
    %% Schedule periodic state synchronization.
    % case lasp_config:get(blocking_sync, false) of
    %     true ->
    %         case partisan_config:get(tag, undefined) of
    %             server ->
    %                 schedule_state_synchronization();
    %             _ ->
    %                 ok
    %         end;
    %     false ->
    %         schedule_state_synchronization()
    % end,


    %% Schedule periodic plumtree refresh.
    schedule_plumtree_peer_refresh(),

    BlockingSyncs = dict:new(),
    PendingTrans  = dict:new(), % @project buffer of pending transaction

    % @project start transaction schedule instead of schedule_state_synchronization()
    schedule_transaction_sync(),


    {ok, #state{gossip_peers=[],
                blocking_syncs=BlockingSyncs,
                store=Store,
                pending_transaction=PendingTrans,
                current_transaction_id=0,
                last_done_transaction_id=dict:new(),
                actor=Actor}}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.

handle_call({blocking_sync, ObjectFilterFun}, From,
            #state{gossip_peers=GossipPeers,
                   store=Store,
                   blocking_syncs=BlockingSyncs0}=State) ->
    %% Get the peers to synchronize with.
    Members = case ?SYNC_BACKEND:broadcast_tree_mode() of
        true ->
            GossipPeers;
        false ->
            {ok, Members1} = ?SYNC_BACKEND:membership(),
            Members1
    end,

    %% Remove ourself and compute exchange peers.
    Peers = ?SYNC_BACKEND:compute_exchange(?SYNC_BACKEND:without_me(Members)),

    case length(Peers) > 0 of
         true ->
            %% Send the object.
            SyncFun = fun(Peer) ->
                            {ok, Os} = init_state_sync(Peer, ObjectFilterFun, true, Store),
                            [{Peer, O} || O <- Os]
                      end,
            Objects = lists:flatmap(SyncFun, Peers),

            %% Mark response as waiting.
            BlockingSyncs = dict:store(From, Objects, BlockingSyncs0),

            % lager:info("Blocking sync initialized for ~p ~p", [From, Objects]),
            {noreply, State#state{blocking_syncs=BlockingSyncs}};
        false ->
            % lager:info("No peers, not blocking.", []),
            {reply, ok, State}
    end;

%% @project transaction feature
%% handler
%% For each Peers, append the transaction in the pending_transaction
%% Buffer
handle_call({transaction, Transaction, CRDTActor},  _From,
              #state{pending_transaction=PendingTrans,
              current_transaction_id=Tid,
              gossip_peers=GossipPeers}=State ) ->


  NewPending = update_pending(PendingTrans, GossipPeers),
   % For each peer, add the current transaction to the buffer
   % of pending transaction
   AddPending = dict:fold(fun(K,V,Acc)->
                    % add CurrTrans into buffer of pending transaction
                    % and update Transaction id
                    Trans = lists:append([{Transaction,CRDTActor, Tid + 1}], V),
                    % store the Buffer for this peer
                    dict:store(K, Trans, Acc)
                  end,dict:new(),NewPending),
    %
    % Update State with new set of pending_transaction
    {reply, ok, State#state{pending_transaction=AddPending, current_transaction_id=Tid+1}};



handle_call(Msg, _From, State) ->
    _ = lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.

handle_cast({state_ack, From, Id, {Id, _Type, _Metadata, Value}},
            #state{store=Store,
                   blocking_syncs=BlockingSyncs0}=State) ->
    % lager:info("Received ack from ~p for ~p with value ~p", [From, Id, Value]),

    BlockingSyncs = dict:fold(fun(K, V, Acc) ->
                % lager:info("Was waiting ~p ~p", [Key, Value]),
                StillWaiting = lists:delete({From, Id}, V),
                % lager:info("Now waiting ~p ~p", [Key, StillWaiting]),
                case length(StillWaiting) == 0 of
                    true ->
                        %% Bind value locally from server response.
                        %% TODO: Do we have to merge metadata here?
                        {ok, _} = ?CORE:bind_var(Id, Value, Store),

                        %% Reply to return from the blocking operation.
                        gen_server:reply(K, ok),

                        Acc;
                    false ->
                        dict:store(K, StillWaiting, Acc)
                end
              end, dict:new(), BlockingSyncs0),
    {noreply, State#state{blocking_syncs=BlockingSyncs}};

%% @project transaction feature
%% param:
%%   From:  node that sent the ack
%%   Transactions: Buffer of pending_transaction
%%                 [{Transaction,CRDTActor},..]
%% Clear the set of Transaction in Transactions, from
%% the pending_transaction for the peer From
handle_cast({transaction_ack, From, Transactions},
            #state{store=_,
                  pending_transaction=PendingTrans0}=State) ->
  %
  PendingTrans = lists:foldl(fun(Trans,Acc)->
                    % get current Buffer of pending_transaction for node From
                    Buffer = dict:fetch(From,Acc),
                    % remove current transaction from Buffer
                    NewBuf = lists:delete(Trans, Buffer),
                    % update PendingTrans
                    dict:store(From,NewBuf,Acc)
                  end,PendingTrans0,Transactions),
  %
  % Update State with new set of pending_transaction
  {noreply, State#state{pending_transaction=PendingTrans}};

%% TODO should I consider the case of empty Transactions
%%       schedule [] ??
% handle_cast({transaction_send, _From, [] },
%             #state{store=_, actor=_}=State) ->
%   % do nothing when receiving empty buffer
%   {noreply, State};

%% @project transaction feature
%% param:
%%   From: node that sent the transaction_send message
%%   Transactions: Buffer of pending_transaction
%%                 [{Transaction,CRDTActor},..]
%% Process received transaction
%% Send back the transaction_ack
handle_cast({transaction_send, From, Transactions },
            #state{store=Store,last_done_transaction_id=Last_id,
            gossip_peers=GossipPeers,
             actor=Actor}=State) ->
  % Updae  Last id dictionary
  Last = update_last_id(Last_id,GossipPeers),
  %% get Last_id_node for this node (From)
  Last_id_node = dict:fetch(From, Last),
  % call process the transactions schedule received
  New_LastID_Node = process_transaction_shedule(Transactions,Store, Actor,State,Last_id_node),

  %%
  New_LastID = dict:store(From,New_LastID_Node,Last),

  % Acknowledge the transactions schedule recived
  ?SYNC_BACKEND:send(?MODULE, {transaction_ack, node(), Transactions}, From),

  {noreply, State#state{last_done_transaction_id=New_LastID}};





handle_cast({state_send, From, {Id, Type, _Metadata, Value}, AckRequired},
            #state{store=Store, actor=Actor}=State) ->
    lasp_marathon_simulations:log_message_queue_size("state_send"),

    {ok, Object} = ?CORE:receive_value(Store, {state_send,
                                       From,
                                       {Id, Type, _Metadata, Value},
                                       ?CLOCK_INCR(Actor),
                                       ?CLOCK_INIT(Actor)}),

    case AckRequired of
        true ->
            ?SYNC_BACKEND:send(?MODULE, {state_ack, node(), Id, Object}, From);
        false ->
            ok
    end,

    %% Send back just the updated state for the object received.
    case ?SYNC_BACKEND:client_server_mode() andalso
         ?SYNC_BACKEND:i_am_server() andalso
         ?SYNC_BACKEND:reactive_server() of
        true ->
            ObjectFilterFun = fun(Id1) ->
                                      Id =:= Id1
                              end,
            init_state_sync(From, ObjectFilterFun, false, Store),
            ok;
        false ->
            ok
    end,

    {noreply, State};

handle_cast(Msg, State) ->
    _ = lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.

handle_info({state_sync, ObjectFilterFun},
            #state{store=Store, gossip_peers=GossipPeers} = State) ->
    lasp_marathon_simulations:log_message_queue_size("state_sync"),

    % PeerServiceManager = lasp_config:peer_service_manager(),
    % lasp_logger:extended("Beginning state synchronization: ~p",
    %                      [PeerServiceManager]),

    Members = case ?SYNC_BACKEND:broadcast_tree_mode() of
        true ->
            GossipPeers;
        false ->
            {ok, Members1} = ?SYNC_BACKEND:membership(),
            Members1
    end,

    %% Remove ourself and compute exchange peers.
    Peers = ?SYNC_BACKEND:compute_exchange(?SYNC_BACKEND:without_me(Members)),

    % lasp_logger:extended("Beginning sync for peers: ~p", [Peers]),

    %% Ship buffered updates for the fanout value.
    SyncFun = fun(Peer) ->
                      case lasp_config:get(reverse_topological_sync,
                                           ?REVERSE_TOPOLOGICAL_SYNC) of
                          true ->
                              init_reverse_topological_sync(Peer, ObjectFilterFun, Store);
                          false ->
                              init_state_sync(Peer, ObjectFilterFun, false, Store)
                      end
              end,
    lists:foreach(SyncFun, Peers),

    %% Schedule next synchronization.
    schedule_state_synchronization(),

    {noreply, State};

%% @project transaction feature
%% when receiving a transaction_sync msg,
%% will send for each peer the corresponding buffer of
%% pending transaction
handle_info({transaction_sync},
            #state{store=_,pending_transaction=PendingTrans,
            gossip_peers=GossipPeers} = State) ->
  %
  % updating the list of pending transaction, might be that
  % new nodes arrived
  NewPending = update_pending(PendingTrans, GossipPeers),
  % get keys, and for each key send complete buffer
  % of pending_transaction
  Keys = dict:fetch_keys(NewPending),
  SendBufferFct = fun(Key) ->
    Buffer = dict:fetch(Key,NewPending),
    case Buffer of
      [] ->
        ok;
      List ->
        % Sending transaction_send msg
        ?SYNC_BACKEND:send(?MODULE, {transaction_send, node(), List}, Key)
    end
  end,

  lists:foreach(SendBufferFct,Keys),

  % restart schedule
  schedule_transaction_sync(),

  {noreply, State#state{pending_transaction=NewPending}};

handle_info({enable_transaction}, State) ->
  gen_server:call(?MODULE, {enable_transaction}, infinity),
  {noreply, State};


handle_info(plumtree_peer_refresh, State) ->
    %% TODO: Temporary hack until the Plumtree can propagate tree
    %% information in the metadata messages.  Therefore, manually poll
    %% periodically with jitter.
    {ok, Servers} = sprinter_backend:servers(),

    GossipPeers = case length(Servers) of
        0 ->
            [];
        _ ->
            Root = hd(Servers),
            plumtree_gossip_peers(Root)
    end,

    %% Schedule next synchronization.
    schedule_plumtree_peer_refresh(),

    {noreply, State#state{gossip_peers=GossipPeers}};

handle_info(Msg, State) ->
    _ = lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) ->
    {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @project transaction feature
%% update pending Transaction according to Members
%% If new nodes arrive in the system, this will
%% add a new buffer for this new nodes
update_pending(PendingTrans0,GossipPeers) ->
  % get peers
  Members = case ?SYNC_BACKEND:broadcast_tree_mode() of
      true ->
          GossipPeers;
      false ->
          {ok, Members1} = ?SYNC_BACKEND:membership(),
          Members1
  end,

  %% Remove ourself and compute exchange peers.
  Peers = ?SYNC_BACKEND:compute_exchange(?SYNC_BACKEND:without_me(Members)),

  % Build buffer per Peer
  PendingTrans = lists:foldl(fun(E,Acc) ->
                          case dict:is_key(E,Acc) of
                            true ->
                              Acc;
                            false ->
                              dict:store(E,[],Acc)
                          end
                      end,PendingTrans0,Peers),
  %
  PendingTrans.


%% @project transaction feature
%% last_done_transaction_id according to Members
%% If new nodes arrive in the system, this will
%% add a new buffer for this new nodes
update_last_id(Lastdone,GossipPeers) ->
  % get peers
  Members = case ?SYNC_BACKEND:broadcast_tree_mode() of
      true ->
          GossipPeers;
      false ->
          {ok, Members1} = ?SYNC_BACKEND:membership(),
          Members1
  end,

  %% Remove ourself and compute exchange peers.
  Peers = ?SYNC_BACKEND:compute_exchange(?SYNC_BACKEND:without_me(Members)),

  % Build buffer per Peer
  Last = lists:foldl(fun(E,Acc) ->
                          case dict:is_key(E,Acc) of
                            true ->
                              Acc;
                            false ->
                              dict:store(E,0,Acc)
                          end
                      end,Lastdone,Peers),
  %
  Last.


%% @project transaction feature
%% process a transaction schedule :Transactions
%%  as [{Transaction,CRDTActor},..]
%% received from another node
process_transaction_shedule(Transactions,Store, Actor,State,Last_id) ->
  % for each Tranction in the schedule,
  % call process_single_transaction
  SingleTransactionFct = fun(Trans) ->
    case Last_id >= element(3,Trans) of
      true ->
        %% if the id of the current Trans is smaller or
        %% equal than the ID of the last processed transaction
        %% just ignored this transaction
        ok;
      false ->
        %% this is a new transaction not yet seen
        process_single_transaction(Trans,Actor,Store,State)
    end
  end,
  %
  lists:foreach(SingleTransactionFct, Transactions),
  %% get the last transaction
  LastT = lists:last(Transactions),
  %% return the ID of the last Transaction
  element(3, LastT).


%% @project transaction feature
%% process a single transaction, by applying in order,
%% the operation for the corresponding id
%% calling transaction_update function from distribution_backend
%% cf this function to understand what it does
process_single_transaction(Transaction,Actor,Store,State) ->
  % get CRDTActor from transaction
  CRDTActor = element(2,Transaction),
  Operations = element(1,Transaction),
  %% @question For some reason cannot directly access distribution_backend
  %%           with lasp_distribution_backend:transaction_update
  Backend = lasp_config:get(distribution_backend,
                            lasp_distribution_backend),
  _ = Backend:transaction_update(Operations, CRDTActor, Store, Actor,State, []).



%% @project transaction feature
%% periodically send the content of pending_transaction Buffers
schedule_transaction_sync()->
  % TODO add parameter ShouldSync like
  %      in schedule_state_synchronization ??
  ShouldSync = true
          andalso (not ?SYNC_BACKEND:tutorial_mode())
          andalso (
            ?SYNC_BACKEND:peer_to_peer_mode()
            orelse
            (
             ?SYNC_BACKEND:client_server_mode()
             andalso
             not (?SYNC_BACKEND:i_am_server() andalso ?SYNC_BACKEND:reactive_server())
            )
          ),
  %
  % TODO @question should it have jitter and stuff ??
  case ShouldSync of
      true ->
          Interval = lasp_config:get(state_interval, 10000),
          case lasp_config:get(jitter, false) of
              true ->
                  %% Add random jitter.
                  MinimalInterval = round(Interval * 0.10),

                  case MinimalInterval of
                      0 ->
                          %% No jitter.
                          timer:send_after(Interval, {transaction_sync});
                      JitterInterval ->
                          Jitter = rand_compat:uniform(JitterInterval * 2) - JitterInterval,
                          timer:send_after(Interval + Jitter, {transaction_sync})
                  end;
              false ->
                  timer:send_after(Interval, {transaction_sync})
          end;
      false ->
          ok
  end.


%% @private
schedule_state_synchronization() ->
    ShouldSync = true
            andalso (not ?SYNC_BACKEND:tutorial_mode())
            andalso (
              ?SYNC_BACKEND:peer_to_peer_mode()
              orelse
              (
               ?SYNC_BACKEND:client_server_mode()
               andalso
               not (?SYNC_BACKEND:i_am_server() andalso ?SYNC_BACKEND:reactive_server())
              )
            ),

    case ShouldSync of
        true ->
            Interval = lasp_config:get(state_interval, 10000),
            ObjectFilterFun = fun(_) -> true end,
            case lasp_config:get(jitter, false) of
                true ->
                    %% Add random jitter.
                    MinimalInterval = round(Interval * 0.10),

                    case MinimalInterval of
                        0 ->
                            %% No jitter.
                            timer:send_after(Interval, {state_sync, ObjectFilterFun});
                        JitterInterval ->
                            Jitter = rand_compat:uniform(JitterInterval * 2) - JitterInterval,
                            timer:send_after(Interval + Jitter, {state_sync, ObjectFilterFun})
                    end;
                false ->
                    timer:send_after(Interval, {state_sync, ObjectFilterFun})
            end;
        false ->
            ok
    end.

%% @private
schedule_plumtree_peer_refresh() ->
    case ?SYNC_BACKEND:broadcast_tree_mode() of
        true ->
            Interval = lasp_config:get(plumtree_peer_refresh_interval,
                                       ?PLUMTREE_PEER_REFRESH_INTERVAL),
            Jitter = rand_compat:uniform(Interval),
            timer:send_after(Jitter + ?PLUMTREE_PEER_REFRESH_INTERVAL,
                             plumtree_peer_refresh);
        false ->
            ok
    end.

%% @private
init_reverse_topological_sync(Peer, ObjectFilterFun, Store) ->
    % lasp_logger:extended("Initializing reverse toplogical state synchronization with peer: ~p", [Peer]),

    SendFun = fun({Id, #dv{type=Type, metadata=Metadata, value=Value}}) ->
                    case orddict:find(dynamic, Metadata) of
                        {ok, true} ->
                            %% Ignore: this is a dynamic variable.
                            ok;
                        _ ->
                            case ObjectFilterFun(Id) of
                                true ->
                                    ?SYNC_BACKEND:send(?MODULE, {state_send, node(), {Id, Type, Metadata, Value}, false}, Peer);
                                false ->
                                    ok
                            end
                    end
               end,

    SyncFun = fun({{_, _Type} = Id, _Depth}) ->
                      {ok, Object} = lasp_storage_backend:do(get, [Store, Id]),
                      SendFun({Id, Object});
                 (_) ->
                      ok
              end,

    {ok, Vertices} = lasp_dependence_dag:vertices(),

    SortFun = fun({_, A}, {_, B}) ->
                      A > B;
                 (_, _) ->
                      true
              end,
    SortedVertices = lists:sort(SortFun, Vertices),

    lists:map(SyncFun, SortedVertices),

    % lasp_logger:extended("Completed back propagation state synchronization with peer: ~p", [Peer]),

    ok.

%% @private
init_state_sync(Peer, ObjectFilterFun, Blocking, Store) ->
    % lasp_logger:extended("Initializing state propagation with peer: ~p", [Peer]),
    Function = fun({Id, #dv{type=Type, metadata=Metadata, value=Value}}, Acc0) ->
                    case orddict:find(dynamic, Metadata) of
                        {ok, true} ->
                            %% Ignore: this is a dynamic variable.
                            Acc0;
                        _ ->
                            case ObjectFilterFun(Id) of
                                true ->
                                    ?SYNC_BACKEND:send(?MODULE, {state_send, node(), {Id, Type, Metadata, Value}, Blocking}, Peer),
                                    [Id|Acc0];
                                false ->
                                    Acc0
                            end
                    end
               end,
    %% TODO: Should this be parallel?
    {ok, Objects} = lasp_storage_backend:do(fold, [Store, Function, []]),
    % lasp_logger:extended("Completed state propagation with peer: ~p", [Peer]),
    {ok, Objects}.

%% @private
plumtree_gossip_peers(Root) ->
    {ok, Nodes} = sprinter_backend:nodes(),
    Tree = sprinter_backend:debug_get_tree(Root, Nodes),
    FolderFun = fun({Node, Peers}, In) ->
                        case Peers of
                            down ->
                                In;
                            {Eager, _Lazy} ->
                                case lists:member(node(), Eager) of
                                    true ->
                                        In ++ [Node];
                                    false ->
                                        In
                                end
                        end
                end,
    InLinks = lists:foldl(FolderFun, [], Tree),

    {EagerPeers, _LazyPeers} = plumtree_broadcast:debug_get_peers(node(), Root),
    OutLinks = ordsets:to_list(EagerPeers),

    GossipPeers = lists:usort(InLinks ++ OutLinks),
    lager:info("PLUMTREE DEBUG: Gossip Peers: ~p", [GossipPeers]),

    GossipPeers.
