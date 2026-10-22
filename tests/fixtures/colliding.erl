ann() -> 0.

af_atom(A) -> A.

af_int(I) -> I.

af_var(Name) -> Name.

af_call(Fun, Args) ->
    helper(Fun, Args).

af_list(Items) ->
    format(Items),
    done().
