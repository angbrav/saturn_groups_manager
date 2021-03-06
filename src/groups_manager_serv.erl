-module(groups_manager_serv).
-behaviour(gen_server).

-include("saturn_groups_manager.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).
-export([get_datanodes/1,
         get_datanodes_ids/1,
         get_hostport/1,
         new_node/2,
         set_myid/1,
         filter_stream_leaf/1,
         filter_stream_leaf_id/1,
         new_treefile/1,
         new_groupsfile/1,
         set_treedict/2,
         interested/2,
         get_mypath/0,
         set_groupsdict/1,
         get_bucket_sample/0,
         is_leaf/1,
         get_closest_dcid/1,
         get_all_nodes/0,
         get_all_nodes_but_myself/0,
         get_delay_leaf/0,
         get_delays_internal/0,
         do_replicate/1]).

-record(state, {groups,
                map,
                tree,
                paths,
                myid,
                nleaves}).

start_link() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

is_leaf(Id) ->
    gen_server:call(?MODULE, {is_leaf, Id}, infinity).

get_mypath() ->
    gen_server:call(?MODULE, {get_mypath}, infinity).
    
do_replicate(BKey) ->
    gen_server:call(?MODULE, {do_replicate, BKey}, infinity).

get_datanodes(BKey) ->
    gen_server:call(?MODULE, {get_datanodes, BKey}, infinity).

get_datanodes_ids(BKey) ->
    gen_server:call(?MODULE, {get_datanodes_ids, BKey}, infinity).

get_closest_dcid(BKey) ->
    gen_server:call(?MODULE, {get_closest_dcid, BKey}, infinity).

interested(Id, BKey) ->
    gen_server:call(?MODULE, {interested, Id, BKey}, infinity).

get_hostport(Id) ->
    gen_server:call(?MODULE, {get_hostport, Id}, infinity).

new_node(Id, HostPort) ->
    gen_server:call(?MODULE, {new_node, Id, HostPort}, infinity).

set_myid(MyId) ->
    gen_server:call(?MODULE, {set_myid, MyId}, infinity).

filter_stream_leaf(Stream) ->
    gen_server:call(?MODULE, {filter_stream_leaf, Stream}, infinity).

filter_stream_leaf_id(Stream) ->
    gen_server:call(?MODULE, {filter_stream_leaf_id, Stream}, infinity).

new_treefile(File) ->
    gen_server:call(?MODULE, {new_treefile, File}, infinity).

new_groupsfile(File) ->
    gen_server:call(?MODULE, {new_groupsfile, File}, infinity).

set_treedict(Dict, NLeaves) ->
    gen_server:call(?MODULE, {set_treedict, Dict, NLeaves}, infinity).

set_groupsdict(Dict) ->
    gen_server:call(?MODULE, {set_groupsdict, Dict}, infinity).

get_bucket_sample() ->
    gen_server:call(?MODULE, get_bucket_sample, infinity).

get_all_nodes() ->
    gen_server:call(?MODULE, get_all_nodes, infinity).

get_all_nodes_but_myself() ->
    gen_server:call(?MODULE, get_all_nodes_but_myself, infinity).

get_delay_leaf() ->
    gen_server:call(?MODULE, get_delay_leaf, infinity).

get_delays_internal() ->
    gen_server:call(?MODULE, get_delays_internal, infinity).
    
    
init([]) ->
    lager:info("Groups file: ~p", [?GROUPSFILE]),
    {ok, GroupsFile} = file:open(?GROUPSFILE, [read]),
    Name = list_to_atom(atom_to_list(node()) ++ atom_to_list(rgroups_saturn)),
    RGroups = ets:new(Name, [set, named_table]),
    ok = replication_groups_from_file(GroupsFile, RGroups),
    file:close(GroupsFile),
     
    lager:info("Tree file: ~p", [?TREEFILE]),
    {ok, TreeFile} = file:open(?TREEFILE, [read]),
    case file:read_line(TreeFile) of
        eof ->
            lager:error("Empty file: ~p", [?TREEFILE]),
            S1 = #state{groups=RGroups, paths=dict:new(), tree=dict:new(), nleaves=0};
        {error, Reason} ->
            lager:error("Problem reading ~p file, reason: ~p", [?TREEFILE, Reason]),
            S1 = #state{groups=RGroups, paths=dict:new(), tree=dict:new(), nleaves=0};
        {ok, Line} ->
            {NLeaves, []} = string:to_integer(hd(string:tokens(Line, "\n"))),
            {Tree, Paths} = tree_from_file(TreeFile, 0, NLeaves, dict:new(), dict:new()),
            S1 = #state{groups=RGroups, paths=Paths, tree=Tree, nleaves=NLeaves}
    end,
    file:close(TreeFile),
    {ok, S1#state{map=dict:new()}}.

handle_call(get_all_nodes_but_myself, _From, S0=#state{tree=Tree, myid=MyId}) ->
    Nodes = dict:fetch_keys(Tree),
    {reply, {ok, lists:delete(MyId, Nodes)}, S0};

handle_call(get_all_nodes, _From, S0=#state{tree=Tree}) ->
    Nodes = dict:fetch_keys(Tree),
    {reply, {ok, Nodes}, S0};

handle_call({get_mypath}, _From, S0=#state{myid=MyId, paths=Paths}) ->
    {reply, {ok, dict:fetch(MyId, Paths)}, S0};

handle_call(get_bucket_sample, _From, S0=#state{myid=MyId, groups=Groups}) ->
    case find_key(ets:first(Groups), Groups, MyId) of
        {ok, Bucket} -> 
            {reply, {ok, Bucket}, S0};
        {error, not_found} ->
            {reply, {error, not_found}, S0}
    end;
    
handle_call({set_treedict, Tree, Leaves}, _From, S0) ->
    Paths = path_from_tree_dict(Tree, Leaves),
    {reply, ok, S0#state{paths=Paths, tree=Tree, nleaves=Leaves}};

handle_call(get_delay_leaf, _From, S0=#state{tree=Tree, myid=MyId, nleaves=NLeaves}) ->
    Row = dict:fetch(MyId, Tree),
    Internal = find_internal(Row, 0, NLeaves),
    Delay = lists:nth(Internal+1, Row),
    {reply, {ok, Delay}, S0};

handle_call(get_delays_internal, _From, S0=#state{tree=Tree, myid=MyId}) ->
    Row = dict:fetch(MyId, Tree),
    {Delays, _} = lists:foldl(fun(Entry, {Dict, C}) ->
                                case Entry >= 0 of
                                    true ->
                                        {dict:store(C, Entry, Dict), C+1};
                                    false ->
                                        {Dict, C+1}
                                end
                              end, {dict:new(), 0}, Row),
    case dict:size(Delays) > 3 of
        true ->
            lager:error("Tree is not binary: ~p: ~p", [MyId, Row]),
            {reply, {error, no_binary_tree}, S0};
        false ->
            {reply, {ok, Delays}, S0}
    end;

handle_call({set_groupsdict, RGroups}, _From, S0=#state{groups=Groups}) ->
    true = ets:delete_all_objects(Groups),
    lists:foreach(fun(Item) ->
                    true = ets:insert(Groups, Item)
                  end, dict:to_list(RGroups)),
    {reply, ok, S0};

handle_call({new_groupsfile, File}, _From, S0=#state{groups=Groups}) ->
    {ok, GroupsFile} = file:open(File, [read]),
    true = ets:delete_all_objects(Groups),
    ok = replication_groups_from_file(GroupsFile, Groups),
    file:close(GroupsFile),
    {reply, ok, S0};

handle_call({new_treefile, File}, _From, _S0) ->
    {ok, TreeFile} = file:open(File, [read]),
    case file:read_line(TreeFile) of
        eof ->
            lager:error("Empty file: ~p", [File]),
            S1 = #state{paths=dict:new(), tree=dict:new(), nleaves=0};
        {error, Reason} ->
            lager:error("Problem reading ~p file, reason: ~p", [File, Reason]),
            S1 = #state{paths=dict:new(), tree=dict:new(), nleaves=0};
        {ok, Line} ->
            {NLeaves, []} = string:to_integer(hd(string:tokens(Line, "\n"))),
            {Tree, Paths} = tree_from_file(TreeFile, 0, NLeaves, dict:new(), dict:new()),
            S1 = #state{paths=Paths, tree=Tree, nleaves=NLeaves}
    end,
    file:close(TreeFile),
    {reply, ok, S1};

handle_call({set_myid, MyId}, _From, S0) ->
    {reply, ok, S0#state{myid=MyId}};

handle_call({is_leaf, Id}, _From, S0=#state{nleaves=NLeaves}) ->
    {reply, {ok, is_leaf(Id, NLeaves)}, S0};

handle_call({new_node, Id, HostPort}, _From, S0=#state{map=Map0}) ->
    case dict:find(Id, Map0) of
        {ok, _Value} ->
            lager:error("Node already known"),
            {reply, ok, S0};
        error ->
            Map1 = dict:store(Id, HostPort, Map0),
            {reply, ok, S0#state{map=Map1}}
    end;

handle_call({do_replicate, BKey}, _From, S0=#state{groups=Groups, myid=MyId}) ->
    {Bucket, _Key} = BKey,
    case ets:lookup(Groups, Bucket) of 
        [] ->
            {reply, {error, unknown_key}, S0};
        [{Bucket, Value}]->
            case contains(MyId, Value) of
                true ->
                    {reply, true, S0};
                false ->
                    %lager:info("Node: ~p does not replicate: ~p (Replicas: ~p)", [MyId, BKey, Value]),
                    {reply, false, S0}
            end
    end;
        
handle_call({get_datanodes, BKey}, _From, S0=#state{groups=Groups, map=Map, myid=MyId}) ->
    {Bucket, _Key} = BKey,
    case ets:lookup(Groups, Bucket) of
        [] ->
            {reply, {error, unknown_key}, S0};
        [{Bucket, Value}] ->
            Group = lists:foldl(fun(Id, Acc) ->
                                    case Id of
                                        MyId ->
                                            Acc;
                                        _ ->
                                            case dict:find(Id, Map) of
                                                {ok, {Host,Port}} ->
                                                    Acc ++ [{Host, Port}];
                                                error -> 
                                                    Acc
                                            end
                                    end
                                end, [], Value),
            {reply, {ok, Group}, S0}
    end;

handle_call({get_closest_dcid, BKey}, _From, S0=#state{groups=Groups, myid=MyId, tree=Tree}) ->
    {Bucket, _Key} = BKey,
    case ets:lookup(Groups, Bucket) of
        [] ->
            {reply, {error, unknown_key}, S0};
        [{Bucket, Value}] ->
            {ClosestId, _} = lists:foldl(fun(Id, {_IdClosest, D0}=Acc) ->
                                            D1 = distance_datanodes(Tree, MyId, Id),
                                            case D0 of
                                                max -> {Id, D1};
                                                _ -> case (D1 > D0) of
                                                        true -> Acc;
                                                        false -> {Id, D1}
                                                     end
                                            end
                                         end, {noid, max}, Value),
            case ClosestId of
                noid ->
                    {reply, {error, no_replica_found}, S0};
                _ ->
                    {reply, {ok, ClosestId}, S0}
            end
    end;


handle_call({get_datanodes_ids, BKey}, _From, S0=#state{groups=Groups, myid=MyId}) ->
    {Bucket, _Key} = BKey,
    case ets:lookup(Groups, Bucket) of
        [] ->
            {reply, {error, unknown_key}, S0};
        [{Bucket, Value}] ->
            Group = lists:foldl(fun(Id, Acc) ->
                                    case Id of
                                        MyId ->
                                            Acc;
                                        _ ->
                                            Acc ++ [Id]
                                    end
                                end, [], Value),
            {reply, {ok, Group}, S0}
    end;

handle_call({filter_stream_leaf_id, Stream0}, _From, S0=#state{tree=Tree, nleaves=NLeaves, myid=MyId, groups=Groups, paths=Paths}) ->
    Row = dict:fetch(MyId, Tree),
    Internal = find_internal(Row, 0, NLeaves),
    Stream1 = lists:foldl(fun({BKey, Elem}, Acc) ->
                            {Bucket, _Key} = BKey,
                            case interested(Internal, Bucket, MyId, Groups, NLeaves, Paths) of
                                true ->
                                    Acc ++ [Elem];
                                false ->
                                    Acc
                            end
                          end, [], Stream0),
    {reply, {ok, Stream1, Internal}, S0};

handle_call({filter_stream_leaf, Stream0}, _From, S0=#state{tree=Tree, nleaves=NLeaves, myid=MyId, map=Map, groups=Groups, paths=Paths}) ->
    Row = dict:fetch(MyId, Tree),
    Internal = find_internal(Row, 0, NLeaves),
    Stream1 = lists:foldl(fun({BKey, Elem}, Acc) ->
                            {Bucket, _Key} = BKey,
                            case interested(Internal, Bucket, MyId, Groups, NLeaves, Paths) of
                                true ->
                                    Acc ++ [Elem];
                                false ->
                                    Acc
                            end
                          end, [], Stream0),
    IndexNode = case dict:find(Internal, Map) of
                    {ok, {Host, Port}} -> {Host, Port};
                    error ->
                        lager:error("The id: ~p is not in the map ~p",[Internal, dict:fetch_keys(Map)]),
                        no_indexnode
                end,
    {reply, {ok, Stream1, IndexNode}, S0};

handle_call({interested, Id, BKey}, _From, S0=#state{myid=MyId, groups=Groups, nleaves=NLeaves, paths=Paths}) ->
    {Bucket, _Key} = BKey,
    {reply, {ok, interested(Id, Bucket, MyId, Groups, NLeaves, Paths)}, S0};

handle_call({get_hostport, Id}, _From, S0=#state{map=Map}) ->
    case dict:find(Id, Map) of
        {ok, {Host, Port}} ->
            {reply, {ok, {Host, Port}}, S0};
        error ->
            {reply, {error, no_host}, S0}
    end.

handle_cast(_Info, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%private
interested(Id, Bucket, PreId, Groups, NLeaves, Paths) ->
    [{Bucket, Group}] = ets:lookup(Groups, Bucket),
    case is_leaf(Id, NLeaves) of
        true ->
            contains(Id, Group);
        false ->
            Links = dict:fetch(Id, Paths),
            FilteredLinks = lists:foldl(fun(Elem, Acc) ->
                                        case Elem of
                                            PreId -> Acc;
                                            _ -> Acc ++ [Elem]
                                        end
                                       end, [], Links),
            LinksExpanded = expand_links(FilteredLinks, Id, NLeaves, Paths),
            intersect(LinksExpanded, Group)
    end.
            
expand_links([], _PreId, _NLeaves, _Paths) ->
    [];
               
expand_links([H|T], PreId, NLeaves, Paths) ->
    case is_leaf(H, NLeaves) of
        true ->
            [H] ++ expand_links(T, PreId, NLeaves, Paths);
        false ->
            ExtraPath = dict:fetch(H, Paths),
            FilteredExtraPath = lists:foldl(fun(Elem, Acc) ->
                                            case Elem of
                                                PreId -> Acc;
                                                _ -> Acc ++ [Elem]
                                            end 
                                           end, [], ExtraPath),
            expand_links(FilteredExtraPath, H, NLeaves, Paths) ++ expand_links(T, PreId, NLeaves, Paths)
    end.

intersect([], _List2) ->
    false;

intersect(_List1=[H|T], List2) ->
    case contains(H, List2) of
        true ->
            true;
        false ->
            intersect(T, List2)
    end.

contains(_Id, []) ->
    false;

contains(Id, [H|T]) ->
    case H of
        Id ->
            true;
        _ ->
            contains(Id, T)
    end.

replication_groups_from_file(Device, Table)->
    case file:read_line(Device) of
        eof ->
            ok;
        {error, Reason} ->
            lager:error("Problem reading ~p file, reason: ~p", [?GROUPSFILE, Reason]),
            {error, Reason};
        {ok, "\n"} ->
            replication_groups_from_file(Device, Table);
        {ok, Line} ->
            [H|T] = string:tokens(hd(string:tokens(Line,"\n")), ","),
            ReplicationGroup = lists:foldl(fun(Elem, Acc) ->
                                            {Int, []} = string:to_integer(Elem),
                                            Acc ++ [Int]
                                           end, [], T),
            {Key, []} = string:to_integer(H),
            true = ets:insert(Table, {Key, ReplicationGroup}),
            replication_groups_from_file(Device, Table)
    end.

tree_from_file(Device, Counter, LeavesLeft, Tree0, Path0)->
    case file:read_line(Device) of
        eof ->
            {Tree0, Path0};
        {error, Reason} ->
            lager:error("Problem reading ~p file, reason: ~p", [?TREEFILE, Reason]),
            {Tree0, Path0};
        {ok, Line} ->
            List = string:tokens(hd(string:tokens(Line, "\n")), ","),
            Latencies = lists:foldl(fun(Elem, Acc) ->
                                            {Int, []} = string:to_integer(Elem),
                                            Acc ++ [Int]
                                           end, [], List),
            Tree1 = dict:store(Counter, Latencies, Tree0),
            case LeavesLeft of
                0 ->
                    {OneHopPath, _} = lists:foldl(fun(Elem, {Acc, C}) ->
                                                    {Int, []} = string:to_integer(Elem),
                                                    case Int of
                                                        -1 ->
                                                            {Acc, C+1};
                                                        _ ->
                                                            {Acc ++ [C], C+1}
                                                    end
                                                  end, {[], 0}, List),
                    Path1 = dict:store(Counter, OneHopPath, Path0),
                    tree_from_file(Device, Counter + 1, 0, Tree1, Path1);
                _ ->
                    tree_from_file(Device, Counter + 1, LeavesLeft - 1, Tree1, Path0)
            end
    end.
   
path_from_tree_dict(Tree, Leaves) ->
    lists:foldl(fun({Id, Row}, Paths0) ->
                    case (Id >= Leaves) of
                        true ->
                            {OneHopPath, _} = lists:foldl(fun(Elem, {Acc, C}) ->
                                                            case Elem of
                                                                -1 ->
                                                                    {Acc, C+1};
                                                                _ ->
                                                                    {Acc ++ [C], C+1}
                                                             end
                                                           end, {[], 0}, Row),
                            dict:store(Id, OneHopPath, Paths0);
                        false ->
                            Paths0
                    end
                end, dict:new(), dict:to_list(Tree)).

is_leaf(Id, Total) ->
    Id<Total.


find_internal([H|T], Counter, NLeaves) ->
    case (Counter<NLeaves) of
        true ->
            find_internal(T, Counter+1, NLeaves);
        false ->
            case H>=0 of
                true ->
                    Counter;
                false ->
                    find_internal(T, Counter+1, NLeaves)
            end
    end.

find_key(Key, Groups, MyId) ->
    case Key of
        '$end_of_table' ->
            {error, not_found};
        _ ->
            [{Key, Ids}] = ets:lookup(Groups, Key),
            case lists:member(MyId, Ids) of
                true ->
                    {ok, Key};
                false ->
                    find_key(ets:next(Groups, Key), Groups, MyId)
            end
    end.

distance_datanodes(Tree, MyId, Id) ->
    Row = dict:fetch(MyId, Tree),
    lists:nth(Id+1, Row).

-ifdef(TEST).
distance_datanodes_test() ->
    P1 = dict:store(0,[-1,1,2,3,-1],dict:new()),
    P2 = dict:store(1,[4,-1,5,6,-1],P1),
    P3 = dict:store(2,[7,8,-1,-1,9],P2),
    P4 = dict:store(3,[10,11,-1,-1,12],P3),
    P5 = dict:store(4,[-1,-1,13,14,-1],P4),
    D = distance_datanodes(P5, 1, 2),
    ?assertEqual(5, D).
    
interested_test() ->
    P1 = dict:store(6,[0,1,7],dict:new()),
    P2 = dict:store(7,[2,6,10],P1),
    P3 = dict:store(8,[3,9,10],P2),
    P4 = dict:store(9,[4,5,8],P3),
    P5 = dict:store(10,[7,8],P4),
    Groups = ets:new(test, [set, named_table]),
    true = ets:insert(Groups, {3, [0,1,3]}),
    ?assertEqual(true, interested(0, 3, 6, Groups, 6, P5)),
    ?assertEqual(false, interested(2, 3, 7, Groups, 6, P5)),
    ?assertEqual(true, interested(7, 3, 10, Groups, 6, P5)),
    ?assertEqual(false, interested(9, 3, 8, Groups, 6, P5)),
    true = ets:delete(Groups).

expand_links_test() ->
    P1 = dict:store(6,[0,1,7],dict:new()),
    P2 = dict:store(7,[2,6,10],P1),
    P3 = dict:store(8,[3,9,10],P2),
    P4 = dict:store(9,[4,5,8],P3),
    P5 = dict:store(10,[7,8],P4),
    Result1 = expand_links([6], 0, 6, P5),
    ?assertEqual([1,2,3,4,5], lists:sort(Result1)),
    Result2 = expand_links([7], 2, 6,P5),
    ?assertEqual([0,1,3,4,5], lists:sort(Result2)),
    Result3 = expand_links([7,8], 10, 6, P5),
    ?assertEqual([0,1,2,3,4,5], lists:sort(Result3)),
    Result4 = expand_links([7], 10, 6, P5),
    ?assertEqual([0,1,2], lists:sort(Result4)).

intersect_test() ->
    ?assertEqual(true, intersect([1,4,5], [1,2,3])),
    ?assertEqual(true, intersect([4,1,5], [1,2,3])),
    ?assertEqual(true, intersect([4,6,3], [1,2,3])),
    ?assertEqual(false, intersect([4,6,7], [1,2,3])),
    ?assertEqual(false, intersect([], [])),
    ?assertEqual(false, intersect([1], [2,3])),
    ?assertEqual(true, intersect([1], [2,1])).

contains_test() ->
    ?assertEqual(true, contains(1, [1,2,3])),
    ?assertEqual(false, contains(0, [1,2,3])),
    ?assertEqual(false, contains(0, [])).

replication_groups_from_file_test() ->
    {ok, GroupsFile} = file:open(?GROUPSFILE_TEST, [read]),
    Test = ets:new(test, [set, named_table]),
    ok = replication_groups_from_file(GroupsFile, Test),
    file:close(GroupsFile),
    ?assertEqual(3,ets:info(Test, size)),
    ?assertEqual([{0,[1,2]}],ets:lookup(Test, 0)),
    ?assertEqual([{1,[2,3]}],ets:lookup(Test, 1)),
    ?assertEqual([{2,[3,4]}],ets:lookup(Test, 2)),
    true = ets:delete(Test).

tree_from_file_test() ->
    {ok, TreeFile} = file:open(?TREEFILE_TEST, [read]),
    case file:read_line(TreeFile) of
        eof ->
            eof;
        {error, _Reason} ->
            error;
        {ok, Line} ->
            {NLeaves, []} = string:to_integer(hd(string:tokens(Line, "\n"))),
            {Tree, Paths} = tree_from_file(TreeFile, 0, NLeaves, dict:new(), dict:new()),
            ?assertEqual(3, NLeaves),

            ?assertEqual(2,length(dict:fetch_keys(Paths))),
            ?assertEqual([0,1,4],dict:fetch(3, Paths)),
            ?assertEqual([2,3],dict:fetch(4, Paths)),

            ?assertEqual(5,length(dict:fetch_keys(Tree))),
            ?assertEqual([-1,1,2,3,-1],dict:fetch(0, Tree)),
            ?assertEqual([4,-1,5,6,-1],dict:fetch(1, Tree)),
            ?assertEqual([7,8,-1,-1,9],dict:fetch(2, Tree)),
            ?assertEqual([10,11,-1,-1,12],dict:fetch(3, Tree)),
            ?assertEqual([-1,-1,13,14,-1],dict:fetch(4, Tree))
    end,
    file:close(TreeFile).

path_from_tree_dict_test() ->
    P1 = dict:store(0,[-1,1,2,3,-1],dict:new()),
    P2 = dict:store(1,[4,-1,5,6,-1],P1),
    P3 = dict:store(2,[7,8,-1,-1,9],P2),
    P4 = dict:store(3,[10,11,-1,-1,12],P3),
    P5 = dict:store(4,[-1,-1,13,14,-1],P4),
    Paths = path_from_tree_dict(P5, 3),
    ?assertEqual(2,length(dict:fetch_keys(Paths))),
    ?assertEqual([0,1,4],dict:fetch(3, Paths)),
    ?assertEqual([2,3],dict:fetch(4, Paths)).

is_leaf_test() ->
    ?assertEqual(true, is_leaf(3, 4)),
    ?assertEqual(false, is_leaf(4, 4)).

find_internal_test() ->
    List = [100, 200, 300, 100, -1, -1, 90, -1],
    NLeaves = 4,
    Index = find_internal(List, 0, NLeaves),
    ?assertEqual(6, Index).

-endif.
