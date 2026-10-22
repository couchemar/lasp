-module(comments).
-export([ann/0, greet/1, add/2, triple/3, noop/0, oneliner/1]).

%% don't parse this: foo/1' bar/2'
%% see ann/0' and compile:forms/2' for details

ann() ->
    annotation.

greet(Name) ->
    io:format("hello ~s~n", [Name]).

add(A, B) ->
    A + B.

triple(X, Y, Z) ->
    X + Y + Z.

noop() -> ok.

oneliner(X) -> X.  % trailing comment can't break this
