-define(PRINT(Var), io:format("DEBUG: ~p:~p - ~p~n~n ~p~n~n", [?MODULE, ?LINE, ??Var, Var])).

-define(GROUPSFILE, "data/manager/groups.saturn").
-define(TREEFILE, "data/manager/tree.saturn").
-define(TREEFILE_TEST, "../include/tree_file_test.saturn").
-define(GROUPSFILE_TEST, "../include/groups_file_test.saturn").
