-module(sample).
-export([add/2]).

-spec add(integer(), integer()) -> integer().
add(A, B) ->
    A + B.

hello() ->
    io:format("hello~n").
