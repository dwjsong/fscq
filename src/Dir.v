Require Import Prog.
Require Import List.
Require Import Word.
Require Import Rec.
Require Import BFile.
Require Import BasicProg.
Require Import MemLog.
Require Import Hoare.
Require Import Pred.
Require Import Omega.
Require Import Rec.
Require Import Array.
Require Import ListPred.
Require Import GenSep.
Require Import GenSepN.
Require Import BFile.
Require Import BFileRec.
Require Import Bool.
Require Import SepAuto.
Require Import MemLog.
Require Import Cache.

Import ListNotations.

Set Implicit Arguments.

Definition filename_len := (256 - addrlen - addrlen).
Definition filename := word filename_len.

Module DIR.
  Definition dent_type : Rec.type := Rec.RecF ([("name", Rec.WordF filename_len);
                                                ("inum", Rec.WordF addrlen);
                                                ("valid", Rec.WordF addrlen)]).
  Definition dent := Rec.data dent_type.
  Definition dent0 := @Rec.of_word dent_type $0.

  Definition itemsz := Rec.len dent_type.
  Definition items_per_valu : addr := $ (valulen / itemsz).
  Theorem itemsz_ok : valulen = wordToNat items_per_valu * itemsz.
  Proof.
    unfold items_per_valu; simpl.
    rewrite valulen_is; auto.
  Qed.

  Definition derep F1 F2 m bxp ixp (inum : addr) (delist : list dent) :=
    exists flist f,
    BFileRec.array_item_file dent_type items_per_valu itemsz_ok f delist /\
    (F1 * BFILE.rep bxp ixp flist)%pred (list2mem m) /\
    (F2 * #inum |-> f)%pred (list2nmem flist).

  Definition delen T lxp ixp inum mscs rx : prog T :=
    r <- BFileRec.bf_getlen items_per_valu lxp ixp inum mscs;
    rx r.

  Definition deget T lxp ixp inum idx mscs rx : prog T :=
    r <- BFileRec.bf_get dent_type items_per_valu itemsz_ok
         lxp ixp inum idx mscs;
    rx r.

  Definition deput T lxp ixp inum idx ent mscs rx : prog T :=
    r <- BFileRec.bf_put dent_type items_per_valu itemsz_ok
         lxp ixp inum idx ent mscs;
    rx r.

  Definition deext T lxp bxp ixp inum ent mscs rx : prog T :=
    r <- BFileRec.bf_extend dent_type items_per_valu itemsz_ok
         lxp bxp ixp inum ent mscs;
    rx r.

  Fact resolve_sel_dent0 : forall l i (d : dent),
    d = dent0 -> sel l i d = sel l i dent0.
  Proof.
    intros; subst; auto.
  Qed.

  Fact resolve_selN_dent0 : forall l i (d : dent),
    d = dent0 -> selN l i d = selN l i dent0.
  Proof.
    intros; subst; auto.
  Qed.

  Hint Rewrite resolve_sel_dent0  using reflexivity : defaults.
  Hint Rewrite resolve_selN_dent0 using reflexivity : defaults.

  Theorem delen_ok : forall lxp bxp ixp inum mscs,
    {< F A mbase m delist,
    PRE    MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
           [[ derep F A m bxp ixp inum delist ]]
    POST:(mscs',r)
           MEMLOG.rep lxp (ActiveTxn mbase m) mscs' *
           [[ r = $ (length delist) ]]
    CRASH  MEMLOG.log_intact lxp mbase
    >} delen lxp ixp inum mscs.
  Proof.
    unfold delen, derep.
    hoare.
  Qed.


  Theorem deget_ok : forall lxp bxp ixp inum idx mscs,
    {< F A B mbase m delist e,
    PRE    MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
           [[ derep F A m bxp ixp inum delist ]] *
           [[ (B * #idx |-> e)%pred (list2nmem delist) ]]
    POST:(mscs',r)
           MEMLOG.rep lxp (ActiveTxn mbase m) mscs' *
           [[ r = e ]]
    CRASH  MEMLOG.log_intact lxp mbase
    >} deget lxp ixp inum idx mscs.
  Proof.
    unfold deget, derep.
    hoare.
    list2nmem_bound.
    repeat rewrite_list2nmem_pred; auto.
  Qed.

  Theorem deput_ok : forall lxp bxp ixp inum idx e mscs,
    {< F A B mbase m delist e0,
    PRE    MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
           [[ derep F A m bxp ixp inum delist ]] *
           [[ Rec.well_formed e ]] *
           [[ (B * #idx |-> e0)%pred (list2nmem delist) ]]
    POST:mscs' exists m' delist',
           MEMLOG.rep lxp (ActiveTxn mbase m') mscs' *
           [[ derep F A m' bxp ixp inum delist' ]] *
           [[ (B * #idx |-> e)%pred (list2nmem delist') ]]
    CRASH  MEMLOG.log_intact lxp mbase
    >} deput lxp ixp inum idx e mscs.
  Proof.
    unfold deput, derep.
    hoare.
    list2nmem_bound.
    eapply list2nmem_upd; eauto.
  Qed.


  Theorem deext_ok : forall lxp bxp ixp inum e mscs,
    {< F A B mbase m delist,
    PRE    MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
           [[ derep F A m bxp ixp inum delist ]] *
           [[ Rec.well_formed e ]] *
           [[ B (list2nmem delist) ]]
    POST:(mscs', r) exists m', MEMLOG.rep lxp (ActiveTxn mbase m') mscs' *
          ([[ r = false ]] \/
           [[ r = true  ]] * exists delist' B',
           [[ derep F A m' bxp ixp inum delist' ]] *
           [[ (B * B' * (length delist) |-> e)%pred (list2nmem delist') ]] )
    CRASH  MEMLOG.log_intact lxp mbase
    >} deext lxp bxp ixp inum e mscs.
  Proof.
    unfold deext, derep.
    hoare.
    apply pimpl_or_r; right; cancel.
    admit.
  Qed.


  Hint Extern 1 ({{_}} progseq (delen _ _ _ _) _) => apply delen_ok : prog.
  Hint Extern 1 ({{_}} progseq (deget _ _ _ _ _) _) => apply deget_ok : prog.
  Hint Extern 1 ({{_}} progseq (deput _ _ _ _ _ _) _) => apply deput_ok : prog.
  Hint Extern 1 ({{_}} progseq (deext _ _ _ _ _ _) _) => apply deext_ok : prog.

  Definition dmatch (de: dent) : @pred filename (@weq filename_len) addr :=
    if weq (de :-> "valid") $0 then emp
    else (de :-> "name") |-> (de :-> "inum").

  Theorem dmatch_complete : forall de m1 m2, dmatch de m1 -> dmatch de m2 -> m1 = m2.
  Proof.
    unfold dmatch; intros.
    destruct (weq (de :-> "valid") $0).
    apply emp_complete; eauto.
    eapply ptsto_complete; eauto.
  Qed.

  Hint Resolve dmatch_complete.

  Definition rep F1 F2 m bxp ixp inum (dmap : @mem filename (@weq filename_len) addr) :=
    exists delist,
    derep F1 F2 m bxp ixp inum delist /\
    listpred dmatch delist dmap.

  Definition dfold T lxp bxp ixp dnum S (f : S -> dent -> S) (s0 : S) mscs rx : prog T := Eval compute_rec in
    let2 (mscs, n) <- delen lxp ixp dnum mscs;
    let2 (mscs, s) <- For i < n
      Ghost mbase m F A delist
      Loopvar mscs_s <- (mscs, s0)
      Continuation lrx
      Invariant
        MEMLOG.rep lxp (ActiveTxn mbase m) (fst mscs_s) *
        [[ derep F A m bxp ixp dnum delist ]] *
        [[ snd mscs_s = fold_left f (firstn #i delist) s0 ]]
      OnCrash
        exists mscs', MEMLOG.rep lxp (ActiveTxn mbase m) mscs'
      Begin
        let (mscs, s) := (mscs_s : memstate * cachestate * S) in
        let2 (mscs, de) <- deget lxp ixp dnum i mscs;
        let s := f s de in
        lrx (mscs, s)
      Rof;
    rx (mscs, s).

  Theorem dfold_ok : forall lxp bxp ixp dnum S f (s0 : S) mscs,
    {< mbase m F A delist,
    PRE    MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
           [[ derep F A m bxp ixp dnum delist ]]
    POST:(mscs',r)
           MEMLOG.rep lxp (ActiveTxn mbase m) mscs' *
           [[ r = fold_left f delist s0 ]]
    CRASH  MEMLOG.log_intact lxp mbase
    >} dfold lxp bxp ixp dnum f s0 mscs.
  Proof.
    unfold dfold, derep.
    step.
    unfold derep; eauto.
    step.
    step.
    unfold derep; eauto.
    list2nmem_ptsto_cancel.
    eapply wlt_lt_bound; eauto.
    eapply bfrec_bound; eauto.

    step.
    replace (# (m0 ^+ $1)) with (#m0 + 1).
    rewrite firstn_plusone_selN with (def:=dent0).
    rewrite fold_left_app; simpl.
    subst; reflexivity.
    eapply wlt_lt_bound; eauto.
    eapply bfrec_bound; eauto.
    erewrite wordToNat_plusone with (w' := $ (length l)) by auto.
    omega.

    step.
    rewrite firstn_oob; eauto.
    erewrite wordToNat_natToWord_bound; auto.
    eapply bfrec_bound; eauto.

    unfold MEMLOG.log_intact; cancel.
  Qed.

  Hint Extern 1 ({{_}} progseq (dfold _ _ _ _ _ _ _) _) => apply dfold_ok : prog.


  Definition dlookup_f name (s : option addr) (de : dent) : option addr := Eval compute_rec in
    if (weq (de :-> "valid") $0) then s else
    if (weq (de :-> "name") name) then (Some (de :-> "inum")) else s.

  Definition dlookup T lxp bxp ixp dnum name mscs rx : prog T := Eval compute_rec in
    let2 (mscs, s) <- dfold lxp bxp ixp dnum (dlookup_f name) None mscs;
    rx (mscs, s).


  Lemma fold_dlookup_mono: forall l name v,
      fold_left (dlookup_f name) l (Some v) <> None.
  Proof.
    induction l; firstorder; simpl.
    unfold dlookup_f at 2.
    destruct (weq (fst (snd (snd a))) $0).
    apply IHl.
    destruct (weq (fst a) name); apply IHl.
  Qed.


  Lemma fold_dlookup_unique : forall l m name v w,
    fold_left (dlookup_f name) l (Some v) = Some w
    -> (name |-> v * listpred dmatch l)%pred m
    -> v = w.
  Proof.
    induction l; simpl; intros.
    inversion H; auto.

    unfold dlookup_f at 2 in H.
    unfold dmatch at 1 in H0; rec_simpl.
    destruct (weq (fst (snd (snd a))) $0).
    eapply IHl with (m := m); eauto.
    pred_apply; cancel.

    destruct (weq (fst a) name).
    contradict H0.
    unfold_sep_star; intuition; repeat deex.
    apply mem_disjoint_comm in H0.
    rewrite mem_union_comm in H0 by auto.
    apply mem_disjoint_union in H0.
    unfold mem_disjoint in H0.
    apply H0; exists (fst a); exists (fst (snd a)); exists v.
    unfold ptsto in *; intuition.

    eapply IHl with (m := mem_except m (fst a)); eauto.
    eapply ptsto_mem_except.
    pred_apply; cancel.
  Qed.


  Lemma dlookup_fold_listpred_none': forall l name m,
    fold_left (dlookup_f name) l None = None
    -> listpred dmatch l m
    -> notindomain name m.
  Proof.
    induction l; simpl.
    firstorder.

    unfold dmatch at 1.
    unfold dlookup_f at 2.
    destruct (weq (a :-> "valid") $0) eqn:HV; rec_simpl; intros.
    rewrite HV in H.
    apply emp_star in H0; auto.

    rewrite HV in H.
    destruct (weq (a :-> "name") name) eqn:HN; rec_simpl; intros.
    setoid_rewrite HN in H; simpl in H.
    contradict H.
    apply fold_dlookup_mono.

    setoid_rewrite HN in H; simpl in H.
    apply notindomain_mem_except with (a' := fst a); auto.
    apply IHl; auto.
    eapply ptsto_mem_except; eauto.
  Qed.

  Lemma dlookup_fold_listpred_none: forall l name,
    fold_left (dlookup_f name) l None = None
    -> listpred dmatch l =p=> notindomain name.
  Proof.
    unfold pimpl; intros.
    eapply dlookup_fold_listpred_none'; eauto.
  Qed.

  Lemma dlookup_fold_listpred_some': forall l m name w,
    fold_left (dlookup_f name) l None = Some w
    -> listpred dmatch l m
    -> m name = Some w.
  Proof.
    induction l; simpl; intros.
    inversion H.

    unfold dmatch at 1 in H0.
    unfold dlookup_f at 2 in H.
    destruct (weq (a :-> "valid") $0) eqn:HV; intros;
      rec_simpl; rewrite HV in H; simpl in H.
    apply star_emp_pimpl in H0.
    apply IHl; auto.

    destruct (weq (a :-> "name") name) eqn:HN; intros;
      setoid_rewrite HN in H; simpl in H.
    rec_simpl; rewrite e in H0.
    replace w with (fst (snd a)).
    eapply ptsto_valid; eauto.
    eapply fold_dlookup_unique; eauto.

    eapply indomain_mem_except with (a' := (a :-> "name")); auto.
    apply IHl; auto.
    eapply ptsto_mem_except; eauto.
  Qed.

  Definition dmatch_ex name (de: dent) : @pred filename (@weq filename_len) addr :=
    if (weq (de :-> "name") name) then emp
    else dmatch de.

  Lemma helper_emp_pimpl: forall AT AEQ V (A B : @pred AT AEQ V),
    (A * B)%pred =p=> (A * (emp * B)).
  Proof.
    intros; cancel.
  Qed.

  Lemma dmatch_ex_dmatch : forall l m name v,
    listpred dmatch l m
    -> m name = Some v
    -> (name |-> v * listpred (dmatch_ex name) l)%pred m.
  Proof.
    induction l; simpl; intros.
    pose proof (H name).
    rewrite H0 in H1; inversion H1.

    unfold dmatch at 1 in H.
    unfold dmatch_ex at 1; unfold dmatch at 1.
    destruct (weq (a :-> "valid") $0) eqn:HV; 
      destruct (weq (a :-> "name") name) eqn:HN;
      rec_simpl; intros; try apply helper_emp_pimpl.

    apply star_emp_pimpl in H; apply IHl; auto.
    apply star_emp_pimpl in H; apply IHl; auto.

    admit.
    admit.
  Qed.

  Lemma dlookup_fold_listpred_some: forall l name w,
    fold_left (dlookup_f name) l None = Some w
    -> listpred dmatch l =p=> (listpred (dmatch_ex name) l * name |-> w).
  Proof.
    unfold pimpl; intros.
    apply sep_star_comm.
    apply dmatch_ex_dmatch; eauto.
    eapply dlookup_fold_listpred_some'; eauto.
  Qed.

  Theorem dlookup_ok : forall lxp bxp ixp dnum name mscs,
    {< F A mbase m dmap,
    PRE    MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
           [[ rep F A m bxp ixp dnum dmap ]]
    POST:(mscs',r)
           MEMLOG.rep lxp (ActiveTxn mbase m) mscs' *
           ((exists inum DF,
             [[ r = Some inum /\ (DF * name |-> inum)%pred dmap ]]) \/
            ([[ r = None /\ notindomain name dmap ]]))
    CRASH  MEMLOG.log_intact lxp mbase
    >} dlookup lxp bxp ixp dnum name mscs.
  Proof.
    unfold dlookup, rep.
    step.
    step.
    apply pimpl_or_r.
    destruct (fold_left (dlookup_f name) x None) eqn: Heq; [left | right]; cancel.
    apply dlookup_fold_listpred_some; auto.
    apply dlookup_fold_listpred_none; auto.
  Qed.


  Definition dunlink T lxp bxp ixp dnum name mscs rx : prog T := Eval compute_rec in
    let2 (mscs, n) <- delen lxp ixp dnum mscs;
    mscs <- For i < n
      Ghost mbase m F A delist
      Loopvar mscs <- mscs
      Continuation lrx
      Invariant
        exists dmap, MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
        [[ derep F A m bxp ixp dnum delist ]] *
        [[ listpred dmatch (firstn #i delist) dmap ]] *
        [[ notindomain name dmap ]]
      OnCrash
        exists mscs', MEMLOG.rep lxp (ActiveTxn mbase m) mscs'
      Begin
        let2 (mscs, de) <- deget lxp ixp dnum i mscs;
        If (weq (de :-> "valid") $0) {
          lrx mscs
        } else {
          If (weq (de :-> "name") name) {
            mscs <- deput lxp ixp dnum i (de :=> "valid" := $0) mscs;
            rx (mscs, true)
          } else {
            lrx mscs
          }
        }
      Rof;
    rx (mscs, false).


  Theorem dunlink_ok : forall lxp bxp ixp dnum name mscs,
    {< F A mbase m dmap,
    PRE      MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
             [[ rep F A m bxp ixp dnum dmap ]]
    POST:(mscs',r)
            ([[ r = false ]] * MEMLOG.rep lxp (ActiveTxn mbase m) mscs' *
             [[ notindomain name dmap ]]) \/
            ([[ r = true ]] * exists m' dmap' DF,
             MEMLOG.rep lxp (ActiveTxn mbase m') mscs' *
             [[ rep F A m' bxp ixp dnum dmap' ]] *
             [[ (DF * name |->?)%pred dmap ]] *
             [[ (DF) dmap' ]])
    CRASH    MEMLOG.log_intact lxp mbase
    >} dunlink lxp bxp ixp dnum name mscs.
  Proof.
    unfold dunlink, rep.
    step.
    step.
    apply emp_empty_mem.
    apply notindomain_empty_mem.
    step.
    list2nmem_ptsto_cancel.
    admit.
    step.
    step.
    replace (# (m1 ^+ $1)) with (#m1 + 1).
    rewrite firstn_plusone_selN with (def:=dent0).
    apply listpred_app.
    unfold dmatch at 2; rec_simpl; simpl.
    unfold dent in *; simpl in *; rewrite H9.
    destruct (weq (natToWord addrlen 0) $0); try congruence.
    clear H10. pred_apply; cancel.
    admit.
    admit.
    step.
    step.
    unfold Rec.well_formed; simpl; intuition.
    list2nmem_ptsto_cancel.
    admit.
    step.
    apply pimpl_or_r; right. cancel.
    eexists; intuition eauto.
    instantiate (a0 := upd_none m (fst (selN x #m1 dent0))).
    admit.
    
    (* XXX need to compute dmap *)
    admit.
    admit.
    admit.
    admit.
    unfold MEMLOG.log_intact; cancel.
  Qed.

  Definition dlink T lxp bxp ixp dnum name inum mscs rx : prog T := Eval compute_rec in
    let newde := (dent0 :=> "valid" := $1 :=> "name" := name :=> "inum" := inum) in
    let2 (mscs, n) <- delen lxp ixp dnum mscs;
    mscs <- For i < n
      Ghost mbase m F A delist
      Loopvar mscs <- mscs
      Continuation lrx
      Invariant
        (* Need an invariant saying the name is not found in any earlier dirent *)
        MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
        [[ derep F A m bxp ixp dnum delist ]]
      OnCrash
        exists mscs', MEMLOG.rep lxp (ActiveTxn mbase m) mscs'
      Begin
        let2 (mscs, de) <- deget lxp ixp dnum i mscs;
        If (weq (de :-> "valid") $0) {
          mscs <- deput lxp ixp dnum i newde mscs;
          rx (mscs, true)
        } else {
          lrx mscs
        }
      Rof;
    let2 (mscs, ok) <- deext lxp bxp ixp dnum newde mscs;
    rx (mscs, ok).

  Theorem dlink_ok : forall lxp bxp ixp dnum name inum mscs,
    {< F A mbase m dmap DF,
    PRE      MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
             [[ rep F A m bxp ixp dnum dmap ]] *
             [[ (DF) dmap ]] *
             [[ exists dmap', (DF * name |->?)%pred dmap' ]]
    POST:(mscs',r)
             ([[ r = true ]] * exists m' dmap',
              MEMLOG.rep lxp (ActiveTxn mbase m') mscs' *
              [[ rep F A m' bxp ixp dnum dmap' ]] *
              [[ (DF * name |-> inum)%pred dmap' ]]) \/
             ([[ r = false ]] * exists m',
              MEMLOG.rep lxp (ActiveTxn mbase m') mscs')
    CRASH    MEMLOG.log_intact lxp mbase
    >} dlink lxp bxp ixp dnum name inum mscs.
  Proof.
    admit.
  Qed.

  Definition diritem := (filename * addr)%type.
  Definition diritemmatch (de: diritem) : @pred _ (@weq filename_len) _ := fst de |-> snd de.

  Definition dlist T lxp bxp ixp dnum mscs rx : prog T := Eval compute_rec in
    let2 (mscs, n) <- delen lxp ixp dnum mscs;
    let2 (mscs, res) <- For i < n
      Ghost mbase m F A dmap delist
      Loopvar mscs_res <- (mscs, [])
      Continuation lrx
      Invariant
        MEMLOG.rep lxp (ActiveTxn mbase m) (fst mscs_res) *
        [[ derep F A m bxp ixp dnum delist ]] *
        [[ listpred dmatch delist dmap ]] *
        exists dmap',
        [[ listpred dmatch (firstn #i delist) dmap' ]] *
        [[ listpred diritemmatch (snd mscs_res) dmap' ]]
      OnCrash
        exists mscs', MEMLOG.rep lxp (ActiveTxn mbase m) mscs'
      Begin
        let (mscs, res) := (mscs_res : memstate * cachestate * list diritem) in
        let2 (mscs, de) <- deget lxp ixp dnum i mscs;
        If (weq (de :-> "valid") $0) {
          lrx (mscs, res)
        } else {
          lrx (mscs, (de :-> "name", de :-> "inum") :: res)
        }
      Rof;
    rx (mscs, res).

  Theorem dlist_ok : forall lxp bxp ixp dnum mscs,
    {< F A mbase m dmap,
    PRE      MEMLOG.rep lxp (ActiveTxn mbase m) mscs *
             [[ rep F A m bxp ixp dnum dmap ]]
    POST:(mscs',res)
             MEMLOG.rep lxp (ActiveTxn mbase m) mscs' *
             [[ listpred diritemmatch res dmap ]]
    CRASH    MEMLOG.log_intact lxp mbase
    >} dlist lxp bxp ixp dnum mscs.
  Proof.
    unfold dlist, rep.
    step.
    step.

    instantiate (a9:=empty_mem); unfold emp; auto. (* dmap' *)
    unfold emp; auto.

    3: unfold MEMLOG.log_intact; cancel.

    step.
    step.
    step.

    (* valid=0 entry, skip it in [res] *)
    admit.

    step.
    instantiate (a:=Prog.upd m1 a a0).
    admit.
    unfold diritemmatch at 1; simpl.
    apply sep_star_comm. apply ptsto_upd_disjoint; eauto.
    (* We are adding one more name to the result list, but to do this, we
     * have to show that it isn't already there (otherwise sep_star would
     * no longer be disjoint)..
     *)
    admit.

    step.
    intros m' Hm.
    erewrite listpred_eq with (l:=l) (m1:=m') (m2:=m); eauto.
    rewrite firstn_oob in H17.
    erewrite listpred_eq with (l:=l) (m1:=m) (m2:=m0); eauto.

    (* Need some extra theorem about lengths from BFileRec.. *)
    admit.
  Qed.

  Hint Extern 1 ({{_}} progseq (dlookup _ _ _ _ _ _) _) => apply dlookup_ok : prog.
  Hint Extern 1 ({{_}} progseq (dunlink _ _ _ _ _ _) _) => apply dunlink_ok : prog.
  Hint Extern 1 ({{_}} progseq (dlink _ _ _ _ _ _ _) _) => apply dlink_ok : prog.
  Hint Extern 1 ({{_}} progseq (dlist _ _ _ _ _) _) => apply dlist_ok : prog.

End DIR.
