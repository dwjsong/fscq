Require Import Mem.
Require Import List.
Require Import Prog.
Require Import FMapAVL.
Require Import FMapFacts.
Require Import Word.
Require Import Array.
Require Import Pred PredCrash.
Require Import Hoare.
Require Import SepAuto.
Require Import BasicProg.
Require Import WordAuto.
Require Import Omega.
Require Import ListUtils.
Require Import AsyncDisk.
Require Import OrderedTypeEx.
Require Import Arith.
Require Import MapUtils.
Require Import MemPred.
Require Import ListPred.
Require Import FunctionalExtensionality.

Import AddrMap.
Import ListNotations.

Set Implicit Arguments.



Definition eviction_state : Type := unit.
Definition eviction_init : eviction_state := tt.
Definition eviction_update (s : eviction_state) (a : addr) := s.
Definition eviction_choose (s : eviction_state) : (addr * eviction_state) := (0, s).

Module UCache.

  Definition cachemap := Map.t (valu * bool).  (* (valu, dirty flag) *)

  Record cachestate := mk_cs {
    CSMap : cachemap;
    CSMaxCount : nat;
    CSEvict : eviction_state
  }.

  Definition evict T a (cs : cachestate) rx : prog T :=
    match (Map.find a (CSMap cs)) with
    | Some (v, false) =>
      rx (mk_cs (Map.remove a (CSMap cs)) (CSMaxCount cs) (CSEvict cs))
    | Some (v, true) =>
      Write a v ;;
      rx (mk_cs (Map.remove a (CSMap cs)) (CSMaxCount cs) (CSEvict cs))
    | None =>
      rx cs
    end.

  Definition maybe_evict T (cs : cachestate) rx : prog T :=
    If (lt_dec (Map.cardinal (CSMap cs)) (CSMaxCount cs)) {
      rx cs
    } else {
      let (victim, evictor) := eviction_choose (CSEvict cs) in
      match (Map.find victim (CSMap cs)) with
      | Some _ =>
        cs <- evict victim (mk_cs (CSMap cs) (CSMaxCount cs) evictor);
        rx cs
      | None => (* evictor failed, evict first block *)
        match (Map.elements (CSMap cs)) with
        | nil => rx cs
        | (a, v) :: tl =>
          cs <- evict victim cs;
          rx cs
        end
      end
    }.

  Definition read T a (cs : cachestate) rx : prog T :=
    cs <- maybe_evict cs;
    match Map.find a (CSMap cs) with
    | Some (v, dirty) => rx ^(cs, v)
    | None =>
      v <- Read a;
      rx ^(mk_cs (Map.add a (v, false) (CSMap cs))
                 (CSMaxCount cs) (eviction_update (CSEvict cs) a), v)
    end.

  (* write through *)
  Definition write T a v (cs : cachestate) rx : prog T :=
    cs <- maybe_evict cs;
    Write a v;;
    rx (mk_cs (Map.add a (v, false) (CSMap cs))
              (CSMaxCount cs) (eviction_update (CSEvict cs) a)).

  (* write buffered *)
  Definition dwrite T a v (cs : cachestate) rx : prog T :=
    cs <- maybe_evict cs;
    rx (mk_cs (Map.add a (v, true) (CSMap cs))
              (CSMaxCount cs) (eviction_update (CSEvict cs) a)).

  (* XXX should sync call evict for all dirty blocks ? *)
  Definition sync T (cs : cachestate) rx : prog T :=
    @Sync T;;
    rx cs.

  Definition cache0 sz := mk_cs (Map.empty _) sz eviction_init.

  Definition init T (cachesize : nat) (rx : cachestate -> prog T) : prog T :=
    rx (cache0 cachesize).

  Definition read_array T a i cs rx : prog T :=
    r <- read (a + i) cs;
    rx r.

  Definition write_array T a i v cs rx : prog T :=
    cs <- write (a + i) v cs;
    rx cs.

  Definition evict_array T a i cs rx : prog T :=
    cs <- evict (a + i) cs;
    rx cs.




  (** rep invariant *)

  Definition size_valid cs :=
    Map.cardinal (CSMap cs) <= CSMaxCount cs /\ CSMaxCount cs <> 0.

  Definition addr_valid (d : rawdisk) (cm : cachemap) :=
    forall a, Map.In a cm -> d a <> None.

  Definition cachepred (cache : cachemap) (a : addr) (vs : valuset) : @pred _ addr_eq_dec valuset :=
    (match Map.find a cache with
    | None => a |+> vs
    | Some (v, false) => a |+> vs * [[ v = fst vs ]]
    | Some (v, true)  => exists v0, a |+> (v0, snd vs) * [[ v = fst vs /\ In v0 (snd vs) ]]
    end)%pred.

  Notation mem_pred := (@mem_pred _ addr_eq_dec _ _ addr_eq_dec _).

  Definition rep (cs : cachestate) (m : rawdisk) : rawpred :=
    ([[ size_valid cs /\ addr_valid m (CSMap cs) ]] *
     mem_pred (cachepred (CSMap cs)) m)%pred.

  Theorem sync_invariant_cachepred : forall cache a vs,
    sync_invariant (cachepred cache a vs).
  Proof.
    unfold cachepred; intros.
    destruct (Map.find a cache); eauto.
    destruct p; destruct b; eauto.
  Qed.

  Hint Resolve sync_invariant_cachepred.

  Theorem sync_invariant_rep : forall cs m,
    sync_invariant (rep cs m).
  Proof.
    unfold rep; eauto.
  Qed.

  Hint Resolve sync_invariant_rep.


  Lemma cachepred_remove_invariant : forall a a' v cache,
    a <> a' -> cachepred cache a v =p=> cachepred (Map.remove a' cache) a v.
  Proof.
    unfold cachepred; intros.
    rewrite MapFacts.remove_neq_o; auto.
  Qed.

  Lemma cachepred_add_invariant : forall a a' v v' cache,
    a <> a' -> cachepred cache a v =p=> cachepred (Map.add a' v' cache) a v.
  Proof.
    unfold cachepred; intros.
    rewrite MapFacts.add_neq_o; auto.
  Qed.

  Lemma mem_pred_cachepred_remove_absorb : forall csmap d a w vs p_old,
    d a = Some (w, p_old) ->
    incl vs p_old ->
    mem_pred (cachepred csmap) (mem_except d a) * a |-> (w, vs) =p=>
    mem_pred (cachepred (Map.remove a csmap)) d.
  Proof.
    intros.
    eapply pimpl_trans; [ | apply mem_pred_absorb_nop; eauto ].
    unfold cachepred at 3.
    rewrite MapFacts.remove_eq_o by auto.
    unfold ptsto_subset; cancel; eauto.
    rewrite <- sep_star_lift2and; cancel.
    rewrite mem_pred_pimpl_except; eauto.
    intros; apply cachepred_remove_invariant; eauto.
  Qed.

  Lemma mem_pred_cachepred_absorb_dirty : forall csmap d a v0 old p_old w,
    Map.find a csmap = Some (w, true) ->
    d a = Some (w, p_old) ->
    In v0 p_old ->
    incl old p_old ->
    mem_pred (cachepred csmap) (mem_except d a) * a |-> (v0, old) =p=>
    mem_pred (cachepred csmap) d.
  Proof.
    intros.
    eapply pimpl_trans; [ | apply mem_pred_absorb_nop; eauto ].
    unfold cachepred at 3.
    rewrite H.
    unfold ptsto_subset; cancel; eauto.
    rewrite <- sep_star_lift2and; cancel.
  Qed.

  Lemma size_valid_remove : forall cs a,
    size_valid cs ->
    size_valid (mk_cs (Map.remove a (CSMap cs)) (CSMaxCount cs) (CSEvict cs)).
  Proof.
    unfold size_valid in *; intuition simpl.
    eapply le_trans.
    apply map_cardinal_remove_le; auto.
    auto.
  Qed.

  Lemma size_valid_remove_cardinal_ok : forall cs a v,
    size_valid cs ->
    Map.find a (CSMap cs) = Some v ->
    Map.cardinal (Map.remove a (CSMap cs)) < CSMaxCount cs.
  Proof.
    unfold size_valid; intros.
    rewrite map_remove_cardinal.
    omega.
    eexists; eapply MapFacts.find_mapsto_iff; eauto.
  Qed.

  Lemma addr_valid_remove : forall d a cm,
    addr_valid d cm ->
    addr_valid d (Map.remove a cm).
  Proof.
    unfold addr_valid; intros.
    apply H.
    eapply MapFacts.remove_in_iff; eauto.
  Qed.


  Theorem evict_ok : forall a cs,
    {< d vs (F : rawpred),
    PRE
      rep cs d * [[ (F * a |+> vs)%pred d ]]
    POST RET:cs'
      rep cs' d *
      [[ ~ Map.In a (CSMap cs') ]] *
      [[ Map.In a (CSMap cs) -> Map.cardinal (CSMap cs') < CSMaxCount cs' ]]
    CRASH
      exists cs', rep cs' d
    >} evict a cs.
  Proof.
    unfold evict, rep; intros.

    prestep; norml; unfold stars; simpl; clear_norm_goal;
    denote ptsto_subset as Hx; apply ptsto_subset_valid' in Hx; repeat deex.

    (* cached, dirty *)
    - rewrite mem_pred_extract with (a := a) by eauto.
      unfold cachepred at 2.
      destruct (Map.find a (CSMap cs)) eqn:Hm; try congruence.
      destruct p; destruct b; try congruence.

      unfold ptsto_subset.
      norml; unfold stars; simpl.
      cancel.
      step.
      eapply mem_pred_cachepred_remove_absorb; eauto.
      eapply incl_tran; eauto; apply incl_cons; auto.
      apply size_valid_remove; auto.
      apply addr_valid_remove; auto.
      denote Map.In as Hx; apply MapFacts.remove_in_iff in Hx; intuition.
      eapply size_valid_remove_cardinal_ok; eauto.
      cancel; eauto.
      rewrite sep_star_comm.
      eapply mem_pred_cachepred_absorb_dirty; eauto.
      eapply incl_tran; eauto; apply incl_cons; auto.

    (* cached, non-dirty *)
    - cancel.
      step.
      rewrite mem_pred_extract with (a := a) by eauto.
      unfold cachepred at 2.
      destruct (Map.find a (CSMap cs)) eqn:Hm; try congruence.
      destruct p; destruct b; try congruence.

      unfold ptsto_subset; cancel.
      rewrite sep_star_comm.
      eapply mem_pred_cachepred_remove_absorb; eauto.
      apply size_valid_remove; auto.
      apply addr_valid_remove; auto.
      denote Map.In as Hx; apply MapFacts.remove_in_iff in Hx; intuition.
      eapply size_valid_remove_cardinal_ok; eauto.
      cancel.

    (* not cached *)
    - cancel.
      step.
      eapply MapFacts.in_find_iff; eauto.
      denote Map.In as Hx; apply MapFacts.in_find_iff in Hx; intuition.
      cancel.

    Unshelve. all: try exact addr_eq_dec.
  Qed.


  Hint Extern 1 ({{_}} progseq (evict _ _) _) => apply evict_ok : prog.


  Theorem maybe_evict_ok : forall cs,
    {< d,
    PRE
      rep cs d
    POST RET:cs
      rep cs d * [[ Map.cardinal (CSMap cs) < CSMaxCount cs ]]
    CRASH
      exists cs', rep cs' d
    >} maybe_evict cs.
  Proof.
    unfold maybe_evict; intros.
    step.
    step.

    prestep; unfold rep; norml; unfold stars; simpl; clear_norm_goal.

    (* found victim  *)
    - admit.

    (* victim not found, cache is empty *)
    - unfold size_valid in *; cancel.
      rewrite Map.cardinal_1, Heql; simpl; omega.

    (* victim not found, cache is non-empty *)
    - admit.

  Admitted.



End UCache.

Global Opaque UCache.write_array.
Global Opaque UCache.read_array.
Global Opaque UCache.evict_array.

