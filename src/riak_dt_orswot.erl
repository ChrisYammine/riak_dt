%% -------------------------------------------------------------------
%%
%% riak_dt_orswot: Tombstone-less, replicated, state based observe remove set
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc An OR-Set CRDT. An OR-Set allows the adding, and removal, of
%% elements. Should an add and remove be concurrent, the add wins. In
%% this implementation there is a version vector for the whole set.
%% When an element is added to the set, the version vector is
%% incremented and the `{actor(), count()}' pair for that increment is
%% stored against the element as its "birth dot". Every time the
%% element is re-added to the set, its "birth dot" is updated to that
%% of the `{actor(), count()}' version vector entry resulting from the
%% add. When an element is removed, we simply drop it, no tombstones.
%%
%% When an element exists in replica A and not replica B, is it
%% because A added it and B has not yet seen that, or that B removed
%% it and A has not yet seen that? Usually the presence of a tombstone
%% arbitrates. In this implementation we compare the "birth dot" of
%% the present element to the clock in the Set it is absent from. If
%% the element dot is not "seen" by the Set clock, that means the
%% other set has yet to see this add, and the item is in the merged
%% Set. If the Set clock dominates the dot, that means the other Set
%% has removed this element already, and the item is not in the merged
%% Set.
%%
%% Essentially we've made a dotted version vector.
%%
%% @see riak_dt_multi, riak_dt_vclock
%%
%% @reference Marc Shapiro, Nuno Preguiça, Carlos Baquero, Marek
%% Zawirski (2011) A comprehensive study of Convergent and Commutative
%% Replicated Data Types. http://hal.upmc.fr/inria-00555588/
%%
%% @reference Annette Bieniusa, Marek Zawirski, Nuno Preguiça, Marc
%% Shapiro, Carlos Baquero, Valter Balegas, Sérgio Duarte (2012) An
%% Optimized Conﬂict-free Replicated Set
%% http://arxiv.org/abs/1210.3368
%%
%% @reference Nuno Preguiça, Carlos Baquero, Paulo Sérgio Almeida,
%% Victor Fonte, Ricardo Gonçalves http://arxiv.org/abs/1011.5808
%%
%% @end
-module(riak_dt_orswot).

-behaviour(riak_dt).

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([new/0, value/1, value/2]).
-export([update/3, merge/2, equal/2]).
-export([to_binary/1, from_binary/1]).
-export([precondition_context/1]).

%% EQC API
-ifdef(EQC).
-export([gen_op/0, update_expected/3, eqc_state_value/1, init_state/0, generate/0]).
-endif.

-export_type([orswot/0, orswot_op/0, binary_orswot/0]).

-opaque orswot() :: {riak_dt_vclock:vclock(), entries()}.
-opaque binary_orswot() :: binary(). %% A binary that from_binary/1 will operate on.

-type orswot_op() ::  {add, member()} | {remove, member()} |
                      {add_all, [member()]} | {remove_all, [member()]} |
                      {update, [orswot_op()]}.
-type orswot_q()  :: size | {contains, term()}.

-type actor() :: riak_dt:actor().

%% a dict of member() -> minimal_clock() mappings.  The
%% `minimal_clock()' is a more effecient way of storing knowledge
%% about adds / removes than a UUID per add.
-type entries() :: [{member(), minimal_clock()}].

%% a minimal clock is just the dots for the element, each dot being an
%% actor and event counter for when the element was added.
-type minimal_clock() :: [dot()].
-type dot() :: {actor(), Count::pos_integer()}.
-type member() :: term().

-spec new() -> orswot().
new() ->
    {riak_dt_vclock:fresh(), orddict:new()}.

-spec value(orswot()) -> [member()].
value({_Clock, Entries}) ->
    [K || {K, _Dots} <- orddict:to_list(Entries)].

-spec value(orswot_q(), orswot()) -> term().
value(size, ORset) ->
    length(value(ORset));
value({contains, Elem}, ORset) ->
    lists:member(Elem, value(ORset)).

-spec update(orswot_op(), actor(), orswot()) -> {ok, orswot()} |
                                                  {error, {precondition ,{not_present, member()}}}.
%% @doc take a list of Set operations and apply them to the set.
%% NOTE: either _all_ are applied, or _none_ are.
update({update, Ops}, Actor, ORSet) ->
    apply_ops(lists:sort(Ops), Actor, ORSet);
update({add, Elem}, Actor, ORSet) ->
    {ok, add_elem(Actor, ORSet, Elem)};
update({remove, Elem}, _Actor, ORSet) ->
    {_Clock, Entries} = ORSet,
    remove_elem(orddict:find(Elem, Entries), Elem, ORSet);
update({add_all, Elems}, Actor, ORSet) ->
    ORSet2 = lists:foldl(fun(E, S) ->
                                 add_elem(Actor, S, E) end,
                         ORSet,
                         Elems),
    {ok, ORSet2};

%% @doc note: this is atomic, either _all_ `Elems` are removed, or
%% none are.
update({remove_all, Elems}, Actor, ORSet) ->
    remove_all(Elems, Actor, ORSet).

apply_ops([], _Actor, ORSet) ->
    {ok, ORSet};
apply_ops([Op | Rest], Actor, ORSet) ->
    case update(Op, Actor, ORSet) of
        {ok, ORSet2} ->
            apply_ops(Rest, Actor, ORSet2);
        Error ->
            Error
    end.

remove_all([], _Actor, ORSet) ->
    {ok, ORSet};
remove_all([Elem | Rest], Actor, ORSet) ->
    case update({remove, Elem}, Actor, ORSet) of
        {ok, ORSet2} ->
            remove_all(Rest, Actor, ORSet2);
        Error ->
            Error
    end.

-spec merge(orswot(), orswot()) -> orswot().
merge({LHSClock, LHSEntries}, {RHSClock, RHSEntries}) ->
    Clock = riak_dt_vclock:merge([LHSClock, RHSClock]),
    %% If an element is in both dicts, merge it. If it occurs in one,
    %% then see if its dots are dominated by the others whole set
    %% clock. If so, then drop it, if not, keep it.
    LHSKeys = sets:from_list(orddict:fetch_keys(LHSEntries)),
    RHSKeys = sets:from_list(orddict:fetch_keys(RHSEntries)),
    CommonKeys = sets:intersection(LHSKeys, RHSKeys),
    LHSUnique = sets:subtract(LHSKeys, CommonKeys),
    RHSUnique = sets:subtract(RHSKeys, CommonKeys),

    Entries00 = merge_common_keys(CommonKeys, LHSEntries, RHSEntries),
    Entries0 = merge_disjoint_keys(LHSUnique, LHSEntries, RHSClock, Entries00),
    Entries = merge_disjoint_keys(RHSUnique, RHSEntries, LHSClock, Entries0),

    {Clock, Entries}.

%% @doc check if each element in `Entries' should be in the merged
%% set.
merge_disjoint_keys(Keys, Entries, SetClock, Accumulator) ->
    sets:fold(fun(Key, Acc) ->
                      Dots = orddict:fetch(Key, Entries),
                      case riak_dt_vclock:descends(SetClock, Dots) of
                          false ->
                              %% Optimise the set of stored dots to
                              %% include only those unseen
                              NewDots = riak_dt_vclock:subtract_dots(Dots, SetClock),
                              orddict:store(Key, NewDots, Acc);
                          true ->
                              Acc
                      end
              end,
              Accumulator,
              Keys).

%% @doc merges the minimal clocks for the common entries in both sets.
merge_common_keys(CommonKeys, Entries1, Entries2) ->
    sets:fold(fun(Key, Acc) ->
                      V1 = orddict:fetch(Key, Entries1),
                      V2 = orddict:fetch(Key, Entries2),
                      V = riak_dt_vclock:merge([V1, V2]),
                      orddict:store(Key, V, Acc) end,
              orddict:new(),
              CommonKeys).

-spec equal(orswot(), orswot()) -> boolean().
equal(ORSet1, ORSet2) ->
    ORSet1 == ORSet2.

%% Private
-spec add_elem(actor(), orswot(), member()) -> orswot().
add_elem(Actor, {Clock, Entries}, Elem) ->
    NewClock = riak_dt_vclock:increment(Actor, Clock),
    Dot = [{Actor, riak_dt_vclock:get_counter(Actor, NewClock)}],
    {NewClock, update_entry(Elem, Entries, Dot)}.

update_entry(Elem, Entries, Dot) ->
    orddict:update(Elem, fun(Clock) ->
                                 riak_dt_vclock:merge([Clock, Dot]) end,
                   Dot,
                   Entries).

remove_elem({ok, _Vclock}, Elem, {Clock, Dict}) ->
    {ok, {Clock, orddict:erase(Elem, Dict)}};
remove_elem(_, Elem, _ORSet) ->
    {error, {precondition, {not_present, Elem}}}.

%% @doc the precondition context is a fragment of the CRDT
%% that operations with pre-conditions can be applied too.
%% In the case of OR-Sets this is the set of adds observed.
%% The system can then apply a remove to this context and merge it with a replica.
%% Especially useful for hybrid op/state systems where the context of an operation is
%% needed at a replica without sending the entire state to the client.
-spec precondition_context(orswot()) -> orswot().
precondition_context(ORSet) ->
    ORSet.

-define(TAG, 75).
-define(V1_VERS, 1).

-spec to_binary(orswot()) -> binary().
to_binary(ORSet) ->
    %% @TODO something smarter
    <<?TAG:8/integer, ?V1_VERS:8/integer, (term_to_binary(ORSet))/binary>>.

-spec from_binary(binary()) -> orswot().
from_binary(<<?TAG:8/integer, ?V1_VERS:8/integer, Bin/binary>>) ->
    %% @TODO something smarter
    binary_to_term(Bin).

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

-ifdef(EQC).
eqc_value_test_() ->
    crdt_statem_eqc:run(?MODULE, 1000).

generate() ->
    ?LET(Members, list(int()),
         lists:foldl(fun(M, Set) ->
                            riak_dt_orswot:update({add, M}, choose(1, 50), Set) end,
                    riak_dt_orswot:new(),
                    Members)).

%% EQC generator
gen_op() ->
    oneof([gen_updates(), gen_update()]).

gen_updates() ->
     {update, non_empty(list(gen_update()))}.

gen_update() ->
    oneof([{add, int()}, {remove, int()},
           {add_all, non_empty(list(int()))},
           {remove_all, non_empty(list(int()))}]).

init_state() ->
    {0, dict:new()}.

do_updates(_ID, [], _OldState, NewState) ->
    NewState;
do_updates(ID, [Update | Rest], OldState, NewState) ->
    case {Update, update_expected(ID, Update, NewState)} of
        {{Op, _Arg}, NewState} when Op == remove;
                                   Op == remove_all ->
            OldState;
        {_, NewNewState} ->
            do_updates(ID, Rest, OldState, NewNewState)
    end.

update_expected(ID, {update, Updates}, State) ->
    do_updates(ID, lists:sort(Updates), State, State);
update_expected(ID, {add, Elem}, {Cnt0, Dict}) ->
    Cnt = Cnt0+1,
    ToAdd = {Elem, Cnt},
    {A, R} = dict:fetch(ID, Dict),
    {Cnt, dict:store(ID, {sets:add_element(ToAdd, A), R}, Dict)};
update_expected(ID, {remove, Elem}, {Cnt, Dict}) ->
    {A, R} = dict:fetch(ID, Dict),
    ToRem = [ {E, X} || {E, X} <- sets:to_list(A), E == Elem],
    {Cnt, dict:store(ID, {A, sets:union(R, sets:from_list(ToRem))}, Dict)};
update_expected(ID, {merge, SourceID}, {Cnt, Dict}) ->
    {FA, FR} = dict:fetch(ID, Dict),
    {TA, TR} = dict:fetch(SourceID, Dict),
    MA = sets:union(FA, TA),
    MR = sets:union(FR, TR),
    {Cnt, dict:store(ID, {MA, MR}, Dict)};
update_expected(ID, create, {Cnt, Dict}) ->
    {Cnt, dict:store(ID, {sets:new(), sets:new()}, Dict)};
update_expected(ID, {add_all, Elems}, State) ->
    lists:foldl(fun(Elem, S) ->
                       update_expected(ID, {add, Elem}, S) end,
               State,
               Elems);
update_expected(ID, {remove_all, Elems}, {_Cnt, Dict}=State) ->
    %% Only if _all_ elements are in the set do we remove any elems
    {A, R} = dict:fetch(ID, Dict),
    %% DO NOT consider tombstones as "in" the set, orswot does not have idempotent remove
    In = sets:subtract(A, R),
    Members = [ Elem || {Elem, _X} <- sets:to_list(In)],
    case is_sub_bag(Elems, lists:usort(Members)) of
        true ->
            lists:foldl(fun(Elem, S) ->
                                update_expected(ID, {remove, Elem}, S) end,
                        State,
                        Elems);
        false ->
            State
    end.


eqc_state_value({_Cnt, Dict}) ->
    {A, R} = dict:fold(fun(_K, {Add, Rem}, {AAcc, RAcc}) ->
                               {sets:union(Add, AAcc), sets:union(Rem, RAcc)} end,
                       {sets:new(), sets:new()},
                       Dict),
    Remaining = sets:subtract(A, R),
    Values = [ Elem || {Elem, _X} <- sets:to_list(Remaining)],
    lists:usort(Values).

%% Bag1 and Bag2 are multisets if Bag1 is a sub-multset of Bag2 return
%% true, else false
is_sub_bag(Bag1, Bag2) when length(Bag1) > length(Bag2) ->
    false;
is_sub_bag(Bag1, Bag2) ->
    SubBag = lists:sort(Bag1),
    SuperBag = lists:sort(Bag2),
    is_sub_bag2(SubBag, SuperBag).

is_sub_bag2([], _SuperBag) ->
    true;
is_sub_bag2([Elem | Rest], SuperBag) ->
    case lists:delete(Elem, SuperBag) of
        SuperBag ->
            false;
        SuperBag2 ->
            is_sub_bag2(Rest, SuperBag2)
    end.

-endif.

-endif.
