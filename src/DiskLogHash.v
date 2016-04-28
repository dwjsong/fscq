Require Import Arith.
Require Import Bool.
Require Import Eqdep_dec.
Require Import Classes.SetoidTactics.
Require Import Hashmap.
Require Import HashmapProg.
Require Import Pred PredCrash.
Require Import Prog.
Require Import Hoare.
Require Import SepAuto.
Require Import BasicProg.
Require Import Omega.
Require Import Word.
Require Import Rec.
Require Import Array.
Require Import WordAuto.
Require Import Cache.
Require Import FSLayout.
Require Import Rounding.
Require Import List ListUtils.
Require Import Psatz.
Require Import AsyncDisk.
Require Import RecArrayUtils.
Require Import AsyncRecArray.

Import ListNotations.

Set Implicit Arguments.


Module PaddedLog.

  Module DescSig <: RASig.

    Definition xparams := log_xparams.
    Definition RAStart := LogDescriptor.
    Definition RALen := LogDescLen.
    Definition xparams_ok (xp : xparams) := goodSize addrlen ((RAStart xp) + (RALen xp)).

    Definition itemtype := Rec.WordF addrlen.
    Definition items_per_val := valulen / addrlen.

    Theorem blocksz_ok : valulen = Rec.len (Rec.ArrayF itemtype items_per_val).
    Proof.
      unfold items_per_val; simpl.
      rewrite valulen_is.
      cbv; auto.
    Qed.

  End DescSig.


  Module DataSig <: RASig.

    Definition xparams := log_xparams.
    Definition RAStart := LogData.
    Definition RALen := LogLen.
    Definition xparams_ok (xp : xparams) := goodSize addrlen ((RAStart xp) + (RALen xp)).

    Definition itemtype := Rec.WordF valulen.
    Definition items_per_val := 1.

    Theorem blocksz_ok : valulen = Rec.len (Rec.ArrayF itemtype items_per_val).
    Proof.
      unfold items_per_val; simpl.
      rewrite valulen_is.
      cbv; auto.
    Qed.

  End DataSig.

  Module Desc := AsyncRecArray DescSig.
  Module Data := AsyncRecArray DataSig.
  Module DescDefs := Desc.Defs.
  Module DataDefs := Data.Defs.


  (************* Log header *)
  Module Hdr.

    Definition header_type := Rec.RecF ([("previous_ndesc", Rec.WordF addrlen);
                                         ("previous_ndata", Rec.WordF addrlen);
                                         ("ndesc", Rec.WordF addrlen);
                                         ("ndata", Rec.WordF addrlen);
                                         ("addr_checksum", Rec.WordF hashlen);
                                         ("valu_checksum", Rec.WordF hashlen)]).
    Definition header := Rec.data header_type.
    Definition hdr := ((nat * nat) * (nat * nat) * (word hashlen * word hashlen))%type.
    Definition previous_length (header : hdr) := fst (fst header).
    Definition current_length (header : hdr) := snd (fst header).
    Definition checksum (header : hdr) := snd header.
    Definition mk_header (len : hdr) : header :=
      ($ (fst (previous_length len)),
      ($ (snd (previous_length len)),
      ($ (fst (current_length len)),
      ($ (snd (current_length len)),
      (fst (checksum len),
      (snd (checksum len), tt)))))).

    Theorem hdrsz_ok : Rec.len header_type <= valulen.
    Proof.
      rewrite valulen_is. apply leb_complete. compute. trivial.
    Qed.
    Local Hint Resolve hdrsz_ok.

    Lemma plus_minus_header : Rec.len header_type + (valulen - Rec.len header_type) = valulen.
    Proof.
      apply le_plus_minus_r; auto.
    Qed.

    Definition hdr2val (h : header) : valu.
      set (zext (Rec.to_word h) (valulen - Rec.len header_type)) as r.
      rewrite plus_minus_header in r.
      refine r.
    Defined.

    Definition val2hdr (v : valu) : header.
      apply Rec.of_word.
      rewrite <- plus_minus_header in v.
      refine (split1 _ _ v).
    Defined.

    Arguments hdr2val: simpl never.

    Lemma val2hdr2val : forall h,
      val2hdr (hdr2val h) = h.
    Proof.
      unfold val2hdr, hdr2val.
      unfold eq_rec_r, eq_rec.
      intros.
      rewrite <- plus_minus_header.
      unfold zext.
      autorewrite with core; auto.
      simpl; destruct h; tauto.
    Qed.

    Arguments val2hdr: simpl never.
    Opaque val2hdr.  (* for some reason "simpl never" doesn't work *)


    Definition xparams := log_xparams.
    Definition LAHdr := LogHeader.

    Inductive state : Type :=
    | Synced : hdr -> state
    | Unsync : hdr -> hdr -> state
    .

    Definition hdr_goodSize header :=
      goodSize addrlen (fst (previous_length header)) /\
      goodSize addrlen (snd (previous_length header)) /\
      goodSize addrlen (fst (current_length header)) /\
      goodSize addrlen (snd (current_length header)).

    Definition state_goodSize st :=
      match st with
      | Synced n => hdr_goodSize n
      | Unsync n o => hdr_goodSize n /\ hdr_goodSize o
      end.

    Definition rep xp state : @rawpred :=
      ([[ state_goodSize state ]] *
      match state with
      | Synced n =>
         (LAHdr xp) |-> (hdr2val (mk_header n), nil)
      | Unsync n o =>
         (LAHdr xp) |-> (hdr2val (mk_header n), [hdr2val (mk_header o)]%list)
      end)%pred.

    Definition xform_rep_synced : forall xp n,
      crash_xform (rep xp (Synced n)) =p=> rep xp (Synced n).
    Proof.
      unfold rep; intros; simpl.
      xform; auto.
    Qed.

    Definition xform_rep_unsync : forall xp n o,
      crash_xform (rep xp (Unsync n o)) =p=> rep xp (Synced n) \/ rep xp (Synced o).
    Proof.
      unfold rep; intros; simpl.
      xform; cancel.
      or_l; cancel.
      or_r; cancel.
    Qed.

    Definition read T xp cs rx : prog T := Eval compute_rec in
      let^ (cs, v) <- BUFCACHE.read (LAHdr xp) cs;
      let header := (val2hdr v) in
      rx ^(cs, ((# (header :-> "previous_ndesc"), # (header :-> "previous_ndata")),
                (# (header :-> "ndesc"), # (header :-> "ndata")),
                (header :-> "addr_checksum", header :-> "valu_checksum"))).

    Definition write T xp n cs rx : prog T :=
      cs <- BUFCACHE.write (LAHdr xp) (hdr2val (mk_header n)) cs;
      rx cs.

    Definition evict T xp cs rx : prog T :=
      cs <- BUFCACHE.evict (LAHdr xp) cs;
      rx cs.

    Definition sync T xp cs rx : prog T :=
      cs <- BUFCACHE.sync (LAHdr xp) cs;
      rx cs.

    Local Hint Unfold rep state_goodSize : hoare_unfold.

    Theorem write_ok : forall xp n cs,
    {< F d old,
    PRE            BUFCACHE.rep cs d *
                   [[ hdr_goodSize n ]] *
                   [[ previous_length n = current_length old \/
                      previous_length old = current_length n ]] *
                   [[ (F * rep xp (Synced old))%pred d ]]
    POST RET: cs
                   exists d', BUFCACHE.rep cs d' *
                   [[ (F * rep xp (Unsync n old))%pred d' ]]
    XCRASH          exists cs' d', BUFCACHE.rep cs' d' * 
                   [[ (F * rep xp (Unsync n old))%pred d' ]]
    >} write xp n cs.
    Proof.
      unfold write.
      hoare.
      xcrash.
      xcrash.
    Qed.

    Theorem read_ok : forall xp cs,
    {< F d n,
    PRE            BUFCACHE.rep cs d *
                   [[ (F * rep xp (Synced n))%pred d ]]
    POST RET: ^(cs, r)
                   BUFCACHE.rep cs d *
                   [[ (F * rep xp (Synced n))%pred d ]] *
                   [[ r = n ]]
    CRASH exists cs', BUFCACHE.rep cs' d
    >} read xp cs.
    Proof.
      unfold read.
      hoare.
      subst; rewrite val2hdr2val; simpl.
      unfold hdr_goodSize in *; intuition.
      repeat rewrite wordToNat_natToWord_idempotent'; auto.
      destruct n; auto.
      destruct p as (p1 , p2); destruct p1, p2, p0; auto.
    Qed.

    Theorem sync_ok : forall xp cs,
    {< F d n old,
    PRE            BUFCACHE.rep cs d *
                   [[ (F * rep xp (Unsync n old))%pred d ]]
    POST RET: cs
                   exists d', BUFCACHE.rep cs d' *
                   [[ (F * rep xp (Synced n))%pred d' ]]
    XCRASH  exists cs' d', BUFCACHE.rep cs' d' *
                   [[ (F * rep xp (Unsync n old))%pred d' ]]
    >} sync xp cs.
    Proof.
      unfold sync.
      hoare.
      xcrash.
    Qed.

    Hint Extern 1 ({{_}} progseq (write _ _ _) _) => apply write_ok : prog.
    Hint Extern 1 ({{_}} progseq (read _ _) _) => apply read_ok : prog.
    Hint Extern 1 ({{_}} progseq (sync _ _) _) => apply sync_ok : prog.

  End Hdr.


  (****************** Log contents and states *)

  Definition entry := (addr * valu)%type.
  Definition contents := list entry.

  Inductive state :=
  (* The log is synced on disk *)
  | Synced (l: contents)
  (* The log has been truncated; but the length (0) is unsynced *)
  | Truncated (old: contents)
  (* The log is being extended; only the content has been updated (unsynced) *)
  | Extended (old: contents) (new: contents)
  (* The log may have been extended to the length that is synced. *)
  | SyncedUnmatched (old: contents) (new: contents).

  Definition ent_addr (e : entry) := addr2w (fst e).
  Definition ent_valu (e : entry) := snd e.

  Definition ndesc_log (log : contents) := (divup (length log) DescSig.items_per_val).
  Definition ndesc_list T (l : list T) := (divup (length l) DescSig.items_per_val).

  Fixpoint log_nonzero (log : contents) : list entry :=
    match log with
    | (0, _) :: rest => log_nonzero rest
    | e :: rest => e :: log_nonzero rest
    | nil => nil
    end.

  Definition vals_nonzero (log : contents) := map ent_valu (log_nonzero log).

  Fixpoint nonzero_addrs (al : list addr) : nat :=
    match al with
    | 0 :: rest => nonzero_addrs rest
    | e :: rest => S (nonzero_addrs rest)
    | nil => 0
    end.

  Fixpoint combine_nonzero (al : list addr) (vl : list valu) : contents :=
    match al, vl with
    | 0 :: al', v :: vl' => combine_nonzero al' vl
    | a :: al', v :: vl' => (a, v) :: (combine_nonzero al' vl')
    | _, _ => nil
    end.

  Definition ndata_log (log : contents) := nonzero_addrs (map fst log) .

  Definition addr_valid (e : entry) := goodSize addrlen (fst e).

  Definition entry_valid (ent : entry) := fst ent <> 0 /\ addr_valid ent.

  Definition rep_contents xp (log : contents) : rawpred :=
    ( [[ Forall addr_valid log ]] *
     Desc.array_rep xp 0 (Desc.Synced (map ent_addr log)) *
     Data.array_rep xp 0 (Data.Synced (vals_nonzero log)) *
     Desc.avail_rep xp (ndesc_log log) (LogDescLen xp - (ndesc_log log)) *
     Data.avail_rep xp (ndata_log log) (LogLen xp - (ndata_log log))
     )%pred.

  Definition padded_addr (al : list addr) :=
    setlen al (roundup (length al) DescSig.items_per_val) 0.

  Definition padded_log (log : contents) :=
    setlen log (roundup (length log) DescSig.items_per_val) (0, $0).

  Definition rep_contents_unmatched xp (old : contents) new_addr new_valu : rawpred :=
    ( [[ Forall addr_valid old ]] *
      (*[[ Forall addr_valid new ]] **)
     Desc.array_rep xp 0 (Desc.Synced (map ent_addr (padded_log old))) *
     Desc.array_rep xp (ndesc_log old) (Desc.Synced new_addr) *
     Data.array_rep xp 0 (Data.Synced (vals_nonzero (padded_log old))) *
     Data.array_rep xp (ndata_log old) (Data.Synced new_valu) *
     Desc.avail_rep xp (ndesc_log old + ndesc_list new_addr) (LogDescLen xp - (ndesc_log old) - (ndesc_list new_addr)) *
     Data.avail_rep xp (ndata_log old + length new_valu) (LogLen xp - (ndata_log old) - (length new_valu))
     )%pred.

  Definition loglen_valid xp ndesc ndata :=
    ndesc <= LogDescLen xp  /\ ndata <= LogLen xp.

  Definition loglen_invalid xp ndesc ndata :=
    ndesc > LogDescLen xp \/ ndata > LogLen xp.

  Definition checksums_match (l : contents) h hm :=
    hash_list_rep (rev (DescDefs.ipack (map ent_addr l))) (fst h) hm /\
    hash_list_rep (rev (vals_nonzero l)) (snd h) hm.

  Definition rep_inner xp (st : state) hm : rawpred :=
  (match st with
  | Synced l =>
      exists prev_len h,
       Hdr.rep xp (Hdr.Synced (prev_len,
                              (ndesc_log l, ndata_log l),
                              h)) *
       rep_contents xp l *
       [[ checksums_match l h hm ]]

  | Truncated old =>
      exists prev_len h h',
       Hdr.rep xp (Hdr.Unsync ((ndesc_log old, ndata_log old), (0, 0), h')
                              (prev_len, (ndesc_log old, ndata_log old), h)) *
       rep_contents xp old *
       [[ checksums_match old h hm ]] *
       [[ checksums_match [] h' hm ]]

  | Extended old new =>
      exists prev_len h h',
       (Hdr.rep xp (Hdr.Unsync ((ndesc_log old, ndata_log old),
                                (ndesc_log old + ndesc_log new,
                                 ndata_log old + ndata_log new), h')
                               (prev_len, (ndesc_log old, ndata_log old), h)) \/
         Hdr.rep xp (Hdr.Unsync (prev_len, (ndesc_log old, ndata_log old), h)
                                ((ndesc_log old, ndata_log old),
                                 (ndesc_log old + ndesc_log new,
                                  ndata_log old + ndata_log new), h'))) *
       rep_contents xp old *
       [[ loglen_valid xp (ndesc_log old + ndesc_log new)
                          (ndata_log old + ndata_log new) ]] *
       [[ checksums_match old h hm ]] *
       [[ checksums_match (padded_log old ++ new) h' hm ]] *
       [[ Forall entry_valid new ]]

  | SyncedUnmatched old new =>
      exists h synced_addr synced_valu ndesc,
        Hdr.rep xp (Hdr.Synced ((ndesc_log old, ndata_log old),
                                (ndesc_log old + ndesc_log new,
                                 ndata_log old + ndata_log new),
                                h)) *
        rep_contents_unmatched xp old synced_addr synced_valu *
        [[ loglen_valid xp (ndesc_log old + ndesc_log new)
                           (ndata_log old + ndata_log new) ]] *
        (* Whatever got synced on disk takes up just as many desc blocks as new should've. *)
        [[ length synced_addr = (ndesc * DescSig.items_per_val)%nat ]] *
        [[ ndesc = ndesc_log new ]] *
        [[ length synced_valu = ndata_log new ]] *
        [[ checksums_match (padded_log old ++ new) h hm ]] *
        [[ Forall entry_valid new ]]

  end)%pred.

  Definition xparams_ok xp := 
    DescSig.xparams_ok xp /\ DataSig.xparams_ok xp /\
    (LogLen xp) = DescSig.items_per_val * (LogDescLen xp).

  Definition rep xp st hm:=
    ([[ xparams_ok xp ]] * rep_inner xp st hm)%pred.

  Definition would_recover_either' xp old new hm :=
    (rep xp (Synced old) hm \/
    rep xp (Extended old new) hm \/
    rep xp (Synced ((padded_log old) ++ new)) hm \/
    rep xp (SyncedUnmatched old new) hm)%pred.

  Definition would_recover_either xp F old new hm :=
    (exists cs d,
      BUFCACHE.rep cs d *
      [[ (F * would_recover_either' xp old new hm)%pred d ]])%pred.

  Definition rep_recovers_to xp (st : state) hm : rawpred :=
  (match st with
    | Synced l =>
        rep xp (Synced l) hm
    | SyncedUnmatched old new =>
        rep xp (Synced old) hm \/
        rep xp (Synced (padded_log old ++ new)) hm
    | _ => any
  end)%pred.

  Definition rep_crashes_to xp (st : state) hm : rawpred :=
  (match st with
    | Synced l =>
        rep xp (Synced l) hm
    | SyncedUnmatched old new =>
        would_recover_either' xp old new hm
    | _ => any
  end)%pred.


  Local Hint Unfold rep rep_inner rep_contents xparams_ok: hoare_unfold.

  Definition avail T xp cs rx : prog T :=
    let^ (cs, nr) <- Hdr.read xp cs;
    let '(_, (ndesc, _), _) := nr in
    rx ^(cs, ((LogLen xp) - ndesc * DescSig.items_per_val)).

  Definition read T xp cs rx : prog T :=
    let^ (cs, nr) <- Hdr.read xp cs;
    let '(_, (ndesc, ndata), _) := nr in
    let^ (cs, wal) <- Desc.read_all xp ndesc cs;
    let al := map (@wordToNat addrlen) wal in
    let^ (cs, vl) <- Data.read_all xp ndata cs;
    rx ^(cs, combine_nonzero al vl).

  (* this is an evil hint *)
  Remove Hints Forall_nil.

  Lemma Forall_True : forall A (l : list A),
    Forall (fun _ : A => True) l.
  Proof.
    intros; rewrite Forall_forall; auto.
  Qed.
  Hint Resolve Forall_True.

  Lemma combine_nonzero_ok : forall l,
    combine_nonzero (map fst l) (vals_nonzero l) = log_nonzero l.
  Proof.
    unfold vals_nonzero.
    induction l; intros; simpl; auto.
    destruct a, n; simpl.
    case_eq (map ent_valu (log_nonzero l)); intros; simpl.
    apply map_eq_nil in H; auto.
    rewrite <- H; auto.
    rewrite IHl; auto.
  Qed.

  Lemma combine_nonzero_nil : forall a,
    combine_nonzero a nil = nil.
  Proof.
    induction a; intros; simpl; auto.
    destruct a; simpl; auto.
  Qed.
  Local Hint Resolve combine_nonzero_nil.

  Lemma combine_nonzero_app_zero : forall a b,
    combine_nonzero (a ++ [0]) b = combine_nonzero a b.
  Proof.
    induction a; intros; simpl; auto.
    destruct b; auto.
    destruct a, b; simpl; auto.
    rewrite IHa; auto.
  Qed.

  Lemma combine_nonzero_app_zeros : forall n a b,
    combine_nonzero (a ++ repeat 0 n) b = combine_nonzero a b.
  Proof.
    induction n; intros; simpl.
    rewrite app_nil_r; auto.
    rewrite <- cons_nil_app.
    rewrite IHn.
    apply combine_nonzero_app_zero.
  Qed.

  Local Hint Resolve roundup_ge DescDefs.items_per_val_gt_0.

  Lemma combine_nonzero_padded_addr : forall a b,
    combine_nonzero (padded_addr a) b = combine_nonzero a b.
  Proof.
    unfold padded_addr, vals_nonzero.
    induction a; intros; simpl; auto.
    unfold setlen, roundup; simpl.
    rewrite divup_0; simpl; auto.

    unfold setlen, roundup; simpl.
    destruct a, b; simpl; auto;
    rewrite firstn_oob; simpl; auto;
    rewrite combine_nonzero_app_zeros; auto.
  Qed.

  Lemma map_fst_repeat : forall A B n (a : A) (b : B),
    map fst (repeat (a, b) n) = repeat a n.
  Proof.
    induction n; intros; simpl; auto.
    rewrite IHn; auto.
  Qed.

  Lemma map_entaddr_repeat_0 : forall n b,
    map ent_addr (repeat (0, b) n) = repeat $0 n.
  Proof.
    induction n; intros; simpl; auto.
    rewrite IHn; auto.
  Qed.

  Lemma combine_nonzero_padded_log : forall l b,
    combine_nonzero (map fst (padded_log l)) b = combine_nonzero (map fst l) b.
  Proof.
    unfold padded_log, setlen, roundup; intros.
    induction l; simpl.
    rewrite divup_0; simpl; auto.
    
    rewrite <- IHl.
    destruct a, b, n; simpl; auto;
    repeat rewrite firstn_oob; simpl; auto;
    repeat rewrite map_app;
    setoid_rewrite map_fst_repeat;
    repeat rewrite combine_nonzero_app_zeros; auto.
  Qed.

  Lemma addr_valid_padded : forall l,
    Forall addr_valid l -> Forall addr_valid (padded_log l).
  Proof.
    unfold padded_log, setlen, roundup; intros.
    rewrite firstn_oob; simpl; auto.
    apply Forall_append; auto.
    rewrite Forall_forall; intros.
    apply repeat_spec in H0; subst.
    unfold addr_valid; simpl.
    apply zero_lt_pow2.
  Qed.

  Lemma padded_addr_valid : forall l,
    Forall addr_valid (padded_log l) ->
    Forall addr_valid l.
  Proof.
    unfold padded_log, setlen; intros.
    rewrite firstn_oob in H; auto.
    eapply forall_app_r; eauto.
  Qed.

  Local Hint Resolve addr_valid_padded padded_addr_valid.

  Lemma map_wordToNat_ent_addr : forall l,
    Forall addr_valid l ->
    (map (@wordToNat _) (map ent_addr l)) = map fst l.
  Proof.
    unfold ent_addr, addr2w.
    induction l; intros; simpl; auto.
    rewrite IHl; f_equal.
    rewrite wordToNat_natToWord_idempotent'; auto.
    apply Forall_inv in H; unfold addr_valid in H; auto.
    eapply Forall_cons2; eauto.
  Qed.

  Lemma combine_nonzero_padded_wordToNat : forall l,
    Forall addr_valid l ->
    combine_nonzero (map (@wordToNat _) (map ent_addr (padded_log l))) (vals_nonzero l) = log_nonzero l.
  Proof.
    intros; unfold ent_addr, addr2w.
    rewrite <- combine_nonzero_ok.
    rewrite <- combine_nonzero_padded_log.
    f_equal.
    rewrite map_wordToNat_ent_addr; auto.
  Qed.

  Lemma vals_nonzero_addrs : forall l,
    length (vals_nonzero l) = nonzero_addrs (map fst l).
  Proof.
    induction l; intros; simpl; auto.
    destruct a, n; simpl; auto.
  Qed.

  Lemma log_nonzero_addrs : forall l,
    length (log_nonzero l) = nonzero_addrs (map fst l).
  Proof.
    induction l; intros; simpl; auto.
    destruct a, n; simpl; auto.
  Qed.

  Lemma desc_ipack_padded : forall l,
    DescDefs.ipack (map ent_addr l) = DescDefs.ipack (map ent_addr (padded_log l)).
  Proof.
    unfold padded_log, setlen; intros.
    rewrite firstn_oob, map_app, map_entaddr_repeat_0 by auto.
    rewrite DescDefs.ipack_app_item0; auto.
    rewrite map_length; auto.
  Qed.

  Local Hint Resolve combine_nonzero_padded_wordToNat.

  Lemma desc_padding_synced_piff : forall xp a l,
    Desc.array_rep xp a (Desc.Synced (map ent_addr (padded_log l)))
    <=p=> Desc.array_rep xp a (Desc.Synced (map ent_addr l)).
  Proof.
     unfold Desc.array_rep, Desc.synced_array, Desc.rep_common; intros.
     split; cancel; subst.
     unfold padded_log, setlen, roundup in H0.
     rewrite firstn_oob, map_app in H0 by auto.
     apply Desc.items_valid_app in H0; intuition.
     apply eq_sym; apply desc_ipack_padded.
     unfold padded_log, setlen, roundup.
     rewrite firstn_oob, map_app by auto.
     apply Desc.items_valid_app2; auto.
     autorewrite with lists; auto.
     apply desc_ipack_padded.
  Qed.

  Lemma desc_padding_unsync_piff : forall xp a l,
    Desc.array_rep xp a (Desc.Unsync (map ent_addr (padded_log l)))
    <=p=> Desc.array_rep xp a (Desc.Unsync (map ent_addr l)).
  Proof.
     unfold Desc.array_rep, Desc.unsync_array, Desc.rep_common; intros.
     split; cancel; subst.
     unfold padded_log, setlen, roundup in H.
     rewrite firstn_oob, map_app in H by auto.
     apply Desc.items_valid_app in H; intuition.
     apply eq_sym; apply desc_ipack_padded.
     unfold padded_log, setlen, roundup.
     rewrite firstn_oob, map_app by auto.
     apply Desc.items_valid_app2; auto.
     autorewrite with lists; auto.
     apply desc_ipack_padded.
  Qed.

  Lemma goodSize_ndesc : forall l,
    goodSize addrlen (length l) -> goodSize addrlen (ndesc_log l).
  Proof.
    intros; unfold ndesc_log.
    eapply goodSize_trans; [ apply divup_le | eauto ].
    destruct (mult_O_le (length l) DescSig.items_per_val); auto.
    contradict H0; apply DescDefs.items_per_val_not_0.
  Qed.
  Local Hint Resolve goodSize_ndesc.

  Lemma padded_log_length: forall l,
    length (padded_log l) = roundup (length l) DescSig.items_per_val.
  Proof.
    unfold padded_log, roundup; intros.
    rewrite setlen_length; auto.
  Qed.

  Lemma nonzero_addrs_app_zero : forall a,
    nonzero_addrs (a ++ [0]) = nonzero_addrs a.
  Proof.
    induction a; intros; simpl; auto.
    destruct a; simpl; auto.
  Qed.

  Lemma nonzero_addrs_app_zeros : forall n a,
    nonzero_addrs (a ++ repeat 0 n) = nonzero_addrs a.
  Proof.
    induction n; intros; simpl.
    rewrite app_nil_r; auto.
    rewrite <- cons_nil_app.
    rewrite IHn.
    apply nonzero_addrs_app_zero.
  Qed.

  Lemma nonzero_addrs_padded_log : forall l,
    nonzero_addrs (map fst (padded_log l)) = nonzero_addrs (map fst l).
  Proof.
    unfold padded_log; induction l; simpl; auto.
    rewrite setlen_nil, repeat_is_nil; simpl; auto.
    unfold roundup; rewrite divup_0; omega.
    
    destruct a, n; simpl;
    rewrite <- IHl;
    unfold setlen, roundup;
    repeat rewrite firstn_oob, map_app by auto;
    setoid_rewrite map_fst_repeat;
    repeat rewrite nonzero_addrs_app_zeros; simpl; auto.
  Qed.

  Lemma vals_nonzero_length : forall l,
    length (vals_nonzero l) <= length l.
  Proof.
    unfold vals_nonzero; induction l; intros; simpl; auto.
    destruct a, n; simpl; auto.
    autorewrite with lists in *; omega.
  Qed.

  Lemma vals_nonzero_app : forall a b,
    vals_nonzero (a ++ b) = vals_nonzero a ++ vals_nonzero b.
  Proof.
    unfold vals_nonzero; induction a; intros; simpl; auto.
    destruct a, n; simpl; auto.
    rewrite IHa; auto.
  Qed.

  Lemma log_nonzero_repeat_0 : forall n,
    log_nonzero (repeat (0, $0) n) = nil.
  Proof.
    induction n; simpl; auto.
  Qed.

  Lemma log_nonzero_app : forall a b,
    log_nonzero (a ++ b) = log_nonzero a ++ log_nonzero b.
  Proof.
    induction a; simpl; intros; auto.
    destruct a, n; simpl; auto.
    rewrite IHa; auto.
  Qed.

  Lemma vals_nonzero_padded_log : forall l,
    vals_nonzero (padded_log l) = vals_nonzero l.
  Proof.
    unfold vals_nonzero, padded_log, setlen, roundup; simpl.
    induction l; intros; simpl; auto.
    rewrite firstn_oob; simpl; auto.
    rewrite log_nonzero_repeat_0; auto.

    destruct a, n.
    rewrite <- IHl.
    repeat rewrite firstn_oob; simpl; auto.
    repeat rewrite log_nonzero_app, map_app.
    repeat rewrite log_nonzero_repeat_0; auto.

    repeat rewrite firstn_oob; simpl; auto.
    f_equal.
    repeat rewrite log_nonzero_app, map_app.
    repeat rewrite log_nonzero_repeat_0; auto.
    simpl; rewrite app_nil_r; auto.
  Qed.

  Lemma ndata_log_goodSize : forall l,
    goodSize addrlen (length l) -> goodSize addrlen (ndata_log l).
  Proof.
    unfold ndata_log; intros.
    rewrite <- vals_nonzero_addrs.
    eapply goodSize_trans.
    apply vals_nonzero_length; auto.
    auto.
  Qed.
  Local Hint Resolve ndata_log_goodSize.

  Lemma padded_log_idem : forall l,
    padded_log (padded_log l) = padded_log l.
  Proof.
    intros.
    unfold padded_log.
    rewrite setlen_length.
    rewrite roundup_roundup; auto.
    rewrite setlen_exact; auto.
    rewrite setlen_length; auto.
  Qed.

  Lemma padded_log_app : forall l1 l2,
    padded_log (padded_log l1 ++ l2) = padded_log l1 ++ padded_log l2.
  Proof.
    intros.
    unfold padded_log.
    rewrite setlen_app_r.
    f_equal.
    rewrite app_length, setlen_length.
    rewrite roundup_roundup_add; auto.
    f_equal; omega.
    rewrite app_length, setlen_length.
    rewrite roundup_roundup_add; auto.
    omega.
  Qed.

  Ltac solve_checksums :=
  try (match goal with
    | [ |- checksums_match _ _ _ ]
      => unfold checksums_match in *
    end; intuition;
    [
      solve_hash_list_rep;
      try (rewrite map_app;
      erewrite DescDefs.ipack_app;
      try solve [ rewrite map_length, padded_log_length; unfold roundup; eauto ];
      rewrite rev_app_distr)
      | solve_hash_list_rep;
      try rewrite vals_nonzero_app, vals_nonzero_padded_log, rev_app_distr;
      try rewrite padded_log_app, map_app, rev_app_distr
    ];
    repeat match goal with
    | [ H: context[hash_list_rep (_ ++ [])] |- _ ]
      => rewrite app_nil_r in H
    end;
    try rewrite <- desc_ipack_padded in *;
    solve_hash_list_rep).


  Arguments Desc.array_rep : simpl never.
  Arguments Data.array_rep : simpl never.
  Arguments Desc.avail_rep : simpl never.
  Arguments Data.avail_rep : simpl never.
  Arguments divup : simpl never.
  Hint Extern 0 (okToUnify (Hdr.rep _ _) (Hdr.rep _ _)) => constructor : okToUnify.
  Hint Extern 0 (okToUnify (Desc.array_rep _ _ _) (Desc.array_rep _ _ _)) => constructor : okToUnify.
  Hint Extern 0 (okToUnify (Data.array_rep _ _ _) (Data.array_rep _ _ _)) => constructor : okToUnify.
  Hint Extern 0 (okToUnify (Desc.avail_rep _ _ _) (Desc.avail_rep _ _ _)) => constructor : okToUnify.
  Hint Extern 0 (okToUnify (Data.avail_rep _ _ _) (Data.avail_rep _ _ _)) => constructor : okToUnify.


  Definition avail_ok : forall xp cs,
    {< F l d,
    PRE:hm   BUFCACHE.rep cs d *
          [[ (F * rep xp (Synced l) hm)%pred d ]]
    POST:hm' RET: ^(cs, r)
          BUFCACHE.rep cs d *
          [[ (F * rep xp (Synced l) hm')%pred d ]] *
          [[ r = (LogLen xp) - roundup (length l) DescSig.items_per_val ]]
    CRASH:hm_crash exists cs',
          BUFCACHE.rep cs' d *
          [[ (F * rep xp (Synced l) hm_crash)%pred d ]]
    >} avail xp cs.
  Proof.
    unfold avail.
    step.
    step.
    solve_checksums.
    solve_checksums.
  Qed.

  Definition read_ok : forall xp cs,
    {< F l d,
    PRE:hm   BUFCACHE.rep cs d *
          [[ (F * rep xp (Synced l) hm)%pred d ]]
    POST:hm' RET: ^(cs, r)
          BUFCACHE.rep cs d *
          [[ (F * rep xp (Synced l) hm')%pred d ]] *
          [[ r = log_nonzero l ]]
    CRASH:hm_crash exists cs',
          BUFCACHE.rep cs' d *
          [[ (F * rep xp (Synced l) hm_crash)%pred d ]]
    >} read xp cs.
  Proof.
    unfold read.
    step.

    prestep. norm. cancel. intuition simpl.
    eassign (map ent_addr (padded_log l)).
    rewrite map_length, padded_log_length.
    auto. auto.
    pred_apply.
    rewrite desc_padding_synced_piff; cancel.

    safestep; subst.
    setoid_rewrite vals_nonzero_addrs; unfold ndata_log.
    replace DataSig.items_per_val with 1 by (cbv; auto); try omega.
    replace (map ent_valu (log_nonzero l)) with (vals_nonzero l); auto.
    safestep.
    rewrite desc_padding_synced_piff; cancel.
    solve_checksums.

    pimpl_crash; cancel.
    rewrite desc_padding_synced_piff; cancel.
    solve_checksums.

    cancel.
    solve_checksums.
    solve_checksums.
  Qed.

  Lemma goodSize_0 : forall sz, goodSize sz 0.
  Proof.
    unfold goodSize; intros.
    apply zero_lt_pow2.
  Qed.

  Lemma ndesc_log_nil : ndesc_log nil = 0.
  Proof.
    unfold ndesc_log; simpl.
    rewrite divup_0; auto.
  Qed.

  Lemma ndata_log_nil : ndata_log nil = 0.
  Proof.
    unfold ndata_log; simpl; auto.
  Qed.

  Local Hint Resolve goodSize_0.


  Definition trunc T xp cs rx : prog T :=
    let^ (cs, nr) <- Hdr.read xp cs;
    let '(_, current_length, _) := nr in
    h <- Hash default_valu;
    cs <- Hdr.write xp (current_length, (0, 0), (h, h)) cs;
    cs <- Hdr.sync xp cs;
    rx cs.

  Local Hint Resolve Forall_nil.

  Lemma helper_sep_star_reorder : forall (a b c d : rawpred),
    a * b * c * d =p=> (a * c) * (b * d).
  Proof.
    intros; cancel.
  Qed.

  Lemma helper_add_sub_0 : forall a b,
    a <= b -> a + (b - a) + 0 = b.
  Proof.
    intros; omega.
  Qed.

  Lemma helper_trunc_ok : forall xp l prev_len h,
    Desc.array_rep xp 0 (Desc.Synced (map ent_addr l)) *
    Data.array_rep xp 0 (Data.Synced (vals_nonzero l)) *
    Desc.avail_rep xp (ndesc_log l) (LogDescLen xp - ndesc_log l) *
    Data.avail_rep xp (ndata_log l) (LogLen xp - ndata_log l) *
    Hdr.rep xp (Hdr.Synced (prev_len, (0, 0), h))
    =p=>
    Hdr.rep xp (Hdr.Synced (prev_len, (ndesc_log [], ndata_log []), h)) *
    Desc.array_rep xp 0 (Desc.Synced []) *
    Data.array_rep xp 0 (Data.Synced (vals_nonzero [])) *
    Desc.avail_rep xp (ndesc_log []) (LogDescLen xp - ndesc_log []) *
    Data.avail_rep xp (ndata_log []) (LogLen xp - ndata_log []).
  Proof.
    intros.
    unfold ndesc_log, vals_nonzero; simpl; rewrite divup_0.
    rewrite Desc.array_rep_sync_nil_sep_star, Data.array_rep_sync_nil_sep_star; auto.
    cancel.
    unfold ndata_log; simpl; repeat rewrite Nat.sub_0_r.
    rewrite <- log_nonzero_addrs.
    rewrite Data.array_rep_size_ok_pimpl, Desc.array_rep_size_ok_pimpl.
    rewrite Data.array_rep_avail, Desc.array_rep_avail.
    simpl; rewrite divup_1; autorewrite with lists.
    cancel.
    rewrite helper_sep_star_reorder.
    rewrite Desc.avail_rep_merge by auto.
    rewrite Data.avail_rep_merge by auto.
    repeat rewrite helper_add_sub_0 by auto.
    cancel.
  Qed.


  (* XXX:
    Ideally XCRASH can contain only Truncated state, whose crash_xform 
    covers the Synced state's crash_xform. However, to prove that, we need 
    to construct a raw disk that satisifies the Truncated state given a raw
    disk of Synced state.  This involves reverse engineering Hdr.rep.
  *)
  Definition trunc_ok : forall xp cs,
    {< F l d,
    PRE:hm   BUFCACHE.rep cs d *
          [[ (F * rep xp (Synced l) hm)%pred d ]]
    POST:hm' RET: cs  exists d',
          BUFCACHE.rep cs d' *
          [[ (F * rep xp (Synced nil) hm')%pred d' ]]
    XCRASH:hm_crash exists cs' d',
          BUFCACHE.rep cs' d' * (
          [[ (F * (rep xp (Synced l) hm_crash))%pred d' ]] \/
          [[ (F * (rep xp (Truncated l) hm_crash))%pred d' ]] )
    >} trunc xp cs.
  Proof.
    unfold trunc.
    step.
    step.
    step.

    unfold Hdr.rep in H0.
    destruct_lift H0.
    unfold Hdr.hdr_goodSize in *; intuition.

    step.
    step.

    (* post condition *)
    cancel_by helper_trunc_ok.
    solve_hash_list_rep.
    auto.
    solve_checksums.
    replace (DescDefs.ipack (map ent_addr [])) with (@nil valu).
    solve_hash_list_rep; auto.
    symmetry. apply DescDefs.ipack_nil.
    auto.

    (* crash conditions *)
    repeat xcrash_rewrite.
    xform_norm. cancel. xform_normr; cancel.
    or_r; cancel.
    solve_checksums.
    solve_checksums; auto.
    setoid_rewrite DescDefs.ipack_nil; simpl.
    solve_hash_list_rep; auto.

    repeat xcrash_rewrite.
    xform_norm; cancel. xform_normr; cancel.
    or_r; cancel.
    solve_checksums.
    solve_checksums; auto.
    setoid_rewrite DescDefs.ipack_nil; simpl.
    solve_hash_list_rep; auto.

    xcrash_rewrite.
    xform_normr; cancel.
    or_l; cancel.
    solve_checksums.

    xcrash_rewrite.
    xform_normr; cancel.
    or_l; cancel.
    solve_checksums.

    Unshelve.
    constructor.
  Qed.

  Theorem loglen_valid_dec xp ndesc ndata :
    {loglen_valid xp ndesc ndata} + {loglen_invalid xp ndesc ndata }.
  Proof.
    unfold loglen_valid, loglen_invalid.
    destruct (lt_dec (LogDescLen xp) ndesc);
    destruct (lt_dec (LogLen xp) ndata); simpl; auto.
    left; intuition.
  Defined.

  Remove Hints goodSize_0.

  Definition entry_valid_ndata : forall l,
    Forall entry_valid l -> ndata_log l = length l.
  Proof.
    unfold ndata_log; induction l; rewrite Forall_forall; intuition.
    destruct a, n; simpl.
    exfalso; intuition.
    apply (H (0, w)); simpl; auto.
    rewrite IHl; auto.
    rewrite Forall_forall; intros.
    apply H; simpl; intuition.
  Qed.

  Lemma loglen_valid_desc_valid : forall xp old new,
    DescSig.xparams_ok xp ->
    loglen_valid xp (ndesc_log old + ndesc_log new) (ndata_log old + ndata_log new) ->
    Desc.items_valid xp (ndesc_log old) (map ent_addr new).
  Proof.
    unfold Desc.items_valid, loglen_valid.
    intuition.
    unfold DescSig.RALen; omega.
    autorewrite with lists; unfold DescSig.RALen.
    apply divup_ge; auto.
    unfold ndesc_log in *; omega.
  Qed.
  Local Hint Resolve loglen_valid_desc_valid.


  Lemma loglen_valid_data_valid : forall xp old new,
    DataSig.xparams_ok xp ->
    Forall entry_valid new ->
    loglen_valid xp (ndesc_log old + ndesc_log new) (ndata_log old + ndata_log new) ->
    Data.items_valid xp (ndata_log old) (map ent_valu new).
  Proof.
    unfold Data.items_valid, loglen_valid.
    intuition.
    unfold DataSig.RALen; omega.
    autorewrite with lists; unfold DataSig.RALen.
    apply divup_ge; auto.
    rewrite divup_1; rewrite <- entry_valid_ndata by auto.
    unfold ndata_log in *; omega.
  Qed.
  Local Hint Resolve loglen_valid_data_valid.

  Lemma helper_loglen_desc_valid_extend : forall xp new old,
    loglen_valid xp (ndesc_log old + ndesc_log new) (ndata_log old + ndata_log new) ->
    ndesc_log new + (LogDescLen xp - ndesc_log old - ndesc_log new) 
      = LogDescLen xp - ndesc_log old.
  Proof.
    unfold loglen_valid, ndesc_log; intros.
    omega.
  Qed.

  Lemma helper_loglen_data_valid_extend : forall xp new old,
    loglen_valid xp (ndesc_log old + ndesc_log new) (ndata_log old + ndata_log new) ->
    ndata_log new + (LogLen xp - ndata_log old - ndata_log new) 
      = LogLen xp - ndata_log old.
  Proof.
    unfold loglen_valid, ndata_log; intros.
    omega.
  Qed.

  Lemma helper_loglen_data_valid_extend_entry_valid : forall xp new old,
    Forall entry_valid new ->
    loglen_valid xp (ndesc_log old + ndesc_log new) (ndata_log old + ndata_log new) ->
    length new + (LogLen xp - ndata_log old - ndata_log new) 
      = LogLen xp - ndata_log old.
  Proof.
    intros.
    rewrite <- entry_valid_ndata by auto.
    apply helper_loglen_data_valid_extend; auto.
  Qed.

  Lemma padded_desc_valid : forall xp st l,
    Desc.items_valid xp st (map ent_addr l)
    -> Desc.items_valid xp st (map ent_addr (padded_log l)).
  Proof.
    unfold Desc.items_valid; intuition.
    autorewrite with lists in *.
    rewrite padded_log_length; unfold roundup.
    apply Nat.mul_le_mono_pos_r.
    apply DescDefs.items_per_val_gt_0.
    apply divup_le; lia.
  Qed.

  Lemma mul_le_mono_helper : forall a b,
    b > 0 -> a <= a * b.
  Proof.
    intros; rewrite Nat.mul_comm.
    destruct (mult_O_le a b); auto; omega.
  Qed.

  Lemma loglen_valid_goodSize_l : forall xp a b,
    loglen_valid xp a b -> DescSig.xparams_ok xp -> DataSig.xparams_ok xp ->
    goodSize addrlen a.
  Proof.
    unfold loglen_valid, DescSig.xparams_ok, DataSig.xparams_ok; intuition.
    eapply goodSize_trans.
    eapply le_trans. eauto.
    apply le_plus_r. eauto.
  Qed.

  Lemma loglen_valid_goodSize_r : forall xp a b,
    loglen_valid xp a b -> DescSig.xparams_ok xp -> DataSig.xparams_ok xp ->
    goodSize addrlen b.
  Proof.
    unfold loglen_valid, DescSig.xparams_ok, DataSig.xparams_ok; intuition.
    eapply goodSize_trans.
    eapply le_trans. eauto.
    apply le_plus_r. eauto.
  Qed.

  Lemma ent_valid_addr_valid : forall l,
    Forall entry_valid l -> Forall addr_valid l.
  Proof.
    intros; rewrite Forall_forall in *; intros.
    apply H; auto.
  Qed.
  Local Hint Resolve ent_valid_addr_valid.
  Local Hint Resolve Forall_append DescDefs.items_per_val_not_0.

  Lemma helper_add_sub : forall a b,
    a <= b -> a + (b - a) = b.
  Proof.
    intros; omega.
  Qed.


  Lemma nonzero_addrs_app : forall a b,
    nonzero_addrs (a ++ b) = nonzero_addrs a + nonzero_addrs b.
  Proof.
    induction a; intros; simpl; auto.
    destruct a; auto.
    rewrite IHa; omega.
  Qed.

  Lemma ndata_log_app : forall a b,
    ndata_log (a ++ b) = ndata_log a + ndata_log b.
  Proof.
    unfold ndata_log;  intros.
    repeat rewrite map_app.
    rewrite nonzero_addrs_app; auto.
  Qed.

  Lemma ndesc_log_padded_log : forall l,
    ndesc_log (padded_log l) = ndesc_log l.
  Proof.
    unfold ndesc_log; intros.
    rewrite padded_log_length.
    unfold roundup; rewrite divup_divup; auto.
  Qed.

  Lemma ndesc_log_app : forall a b,
    length a = roundup (length a) DescSig.items_per_val ->
    ndesc_log (a ++ b) = ndesc_log a + ndesc_log b.
  Proof.
    unfold ndesc_log; intros.
    rewrite app_length, H at 1.
    unfold roundup.
    rewrite Nat.add_comm, Nat.mul_comm.
    rewrite divup_add by auto.
    omega.
  Qed.

  Lemma ndesc_log_padded_app : forall a b,
    ndesc_log (padded_log a ++ b) = ndesc_log a + ndesc_log b.
  Proof.
    intros.
    rewrite ndesc_log_app.
    rewrite ndesc_log_padded_log; auto.
    rewrite padded_log_length.
    rewrite roundup_roundup; auto.
  Qed.

  Lemma ndata_log_padded_log : forall a,
    ndata_log (padded_log a) = ndata_log a.
  Proof.
    unfold ndata_log, padded_log, setlen, roundup; intros.
    rewrite firstn_oob by auto.
    repeat rewrite map_app.
    rewrite repeat_map; simpl.
    rewrite nonzero_addrs_app.
    setoid_rewrite <- app_nil_l at 3.
    rewrite nonzero_addrs_app_zeros; auto.
  Qed.


  Lemma ndata_log_padded_app : forall a b,
    ndata_log (padded_log a ++ b) = ndata_log a + ndata_log b.
  Proof.
    intros.
    rewrite ndata_log_app.
    rewrite ndata_log_padded_log; auto.
  Qed.

  Lemma log_nonzero_rev_comm : forall l,
    log_nonzero (rev l) = rev (log_nonzero l).
  Proof.
    induction l; simpl; intros; auto.
    destruct a, n; simpl; auto;
    rewrite log_nonzero_app; simpl.
    rewrite app_nil_r. congruence.
    congruence.
  Qed.

  Lemma entry_valid_vals_nonzero : forall l,
    Forall entry_valid l ->
    log_nonzero l = l.
  Proof.
    unfold entry_valid; induction l; simpl; auto.
    destruct a, n; simpl; auto; intros.
    exfalso.
    rewrite Forall_forall in H; intuition.
    apply (H (0, w)); simpl; auto.
    rewrite IHl; auto.
    eapply Forall_cons2; eauto.
  Qed.

  Lemma nonzero_addrs_entry_valid : forall l,
    Forall entry_valid l ->
    nonzero_addrs (map fst l) = length l.
  Proof.
    induction l; simpl; intros; auto.
    destruct a, n; simpl.
    exfalso.
    rewrite Forall_forall in H.
    apply (H (0, w)); simpl; auto.
    rewrite IHl; auto.
    eapply Forall_cons2; eauto.
  Qed.

  Lemma extend_ok_helper : forall F xp old new,
    Forall entry_valid new ->
    Data.array_rep xp (ndata_log old) (Data.Synced (map ent_valu new)) *
    Desc.array_rep xp 0 (Desc.Synced (map ent_addr old)) *
    Data.array_rep xp 0 (Data.Synced (vals_nonzero old)) *
    Desc.avail_rep xp (ndesc_log old + divup (length (map ent_addr new)) DescSig.items_per_val)
      (LogDescLen xp - ndesc_log old - ndesc_log new) *
    Data.avail_rep xp (ndata_log old + divup (length (map ent_valu new)) DataSig.items_per_val)
      (LogLen xp - ndata_log old - ndata_log new) *
    Desc.array_rep xp (ndesc_log old) (Desc.Synced (map ent_addr (padded_log new))) * F
    =p=>
    Desc.array_rep xp 0 (Desc.Synced (map ent_addr (padded_log old ++ new))) *
    Data.array_rep xp 0 (Data.Synced (vals_nonzero (padded_log old ++ new))) *
    Desc.avail_rep xp (ndesc_log (padded_log old ++ new)) 
                      (LogDescLen xp - ndesc_log (padded_log old ++ new)) *
    Data.avail_rep xp (ndata_log (padded_log old ++ new))
                      (LogLen xp - ndata_log (padded_log old ++ new)) * F.
  Proof.
    intros.
    repeat rewrite ndesc_log_padded_app, ndata_log_padded_app.
    setoid_rewrite Nat.sub_add_distr.
    unfold ndesc_log.
    rewrite divup_1.
    rewrite entry_valid_ndata with (l := new); auto.
    repeat rewrite map_length.
    rewrite map_app, vals_nonzero_app.
    rewrite <- Desc.array_rep_synced_app.
    rewrite <- Data.array_rep_synced_app.
    repeat rewrite Nat.add_0_l.
    repeat rewrite desc_padding_synced_piff.
    repeat rewrite map_length.
    repeat rewrite vals_nonzero_padded_log.
    rewrite divup_1, padded_log_length.
    unfold roundup; rewrite divup_mul; auto.
    unfold ndata_log; rewrite vals_nonzero_addrs.
    unfold vals_nonzero; rewrite entry_valid_vals_nonzero with (l := new); auto.
    cancel.

    rewrite Nat.mul_1_r; auto.
    rewrite map_length, padded_log_length.
    unfold roundup; auto.
  Qed.

  Lemma nonzero_addrs_bound : forall l,
    nonzero_addrs l <= length l.
  Proof.
    induction l; simpl; auto.
    destruct a; omega.
  Qed.

  Lemma extend_ok_synced_hdr_helper : forall xp prev_len old new h,
    Hdr.rep xp (Hdr.Synced (prev_len,
                            (ndesc_log old + ndesc_log new,
                             ndata_log old + ndata_log new),
                            h))
    =p=>
    Hdr.rep xp (Hdr.Synced (prev_len,
                            (ndesc_log (padded_log old ++ new),
                             ndata_log (padded_log old ++ new)),
                            h)).
  Proof.
    intros.
    rewrite ndesc_log_padded_app, ndata_log_padded_app; auto.
  Qed.

  Local Hint Resolve extend_ok_synced_hdr_helper.

  Lemma nonzero_addrs_roundup : forall B (l : list (addr * B)) n,
    n > 0 ->
    nonzero_addrs (map fst l) <= (divup (length l) n) * n.
  Proof.
    intros.
    eapply le_trans.
    apply nonzero_addrs_bound.
    rewrite map_length.
    apply roundup_ge; auto.
  Qed.

  Lemma loglen_invalid_overflow : forall xp old new,
    LogLen xp = DescSig.items_per_val * LogDescLen xp ->
    loglen_invalid xp (ndesc_log old + ndesc_log new) (ndata_log old + ndata_log new) ->
    length (padded_log old ++ new) > LogLen xp.
  Proof.
    unfold loglen_invalid, ndesc_log, ndata_log; intros.
    rewrite app_length; repeat rewrite padded_log_length.
    unfold roundup; intuition.
    rewrite H.
    setoid_rewrite <- Nat.mul_comm at 2.
    apply divup_add_gt; auto.

    eapply lt_le_trans; eauto.
    apply Nat.add_le_mono.
    apply nonzero_addrs_roundup; auto.
    erewrite <- map_length.
    apply nonzero_addrs_bound.
  Qed.

  Hint Rewrite Desc.array_rep_avail Data.array_rep_avail
     padded_log_length divup_mul divup_1 map_length
     ndesc_log_padded_log nonzero_addrs_padded_log using auto: extend_crash.
  Hint Unfold roundup ndata_log : extend_crash.

  Ltac extend_crash :=
     repeat (autorewrite with extend_crash; autounfold with extend_crash; simpl);
     setoid_rewrite <- Desc.avail_rep_merge at 3;
     [ setoid_rewrite <- Data.avail_rep_merge at 3 | ];
     [ cancel
     | apply helper_loglen_data_valid_extend_entry_valid; auto
     | apply helper_loglen_desc_valid_extend; auto ].

  Lemma log_nonzero_padded_log : forall l,
    log_nonzero (padded_log l) = log_nonzero l.
  Proof.
    unfold padded_log, setlen, roundup; intros.
    rewrite firstn_oob by auto.
    rewrite log_nonzero_app.
    rewrite log_nonzero_repeat_0, app_nil_r; auto.
  Qed.

  Lemma log_nonzero_padded_app : forall l new,
    Forall entry_valid new ->
    log_nonzero l ++ new = log_nonzero (padded_log l ++ padded_log new).
  Proof.
    intros.
    rewrite log_nonzero_app.
    repeat rewrite log_nonzero_padded_log.
    f_equal.
    rewrite entry_valid_vals_nonzero; auto.
  Qed.

  Lemma log_nonzero_app_padded : forall l new,
    Forall entry_valid new ->
    log_nonzero l ++ new = log_nonzero (l ++ padded_log new).
  Proof.
    intros.
    rewrite log_nonzero_app, log_nonzero_padded_log.
    f_equal.
    rewrite entry_valid_vals_nonzero; auto.
  Qed.

  Definition extend T xp log cs rx : prog T :=
    (* Synced *)
    let^ (cs, nr) <- Hdr.read xp cs;
    let '(_, (ndesc, ndata), (h_addr, h_valu)) := nr in
    let '(nndesc, nndata) := ((ndesc_log log), (ndata_log log)) in
    If (loglen_valid_dec xp (ndesc + nndesc) (ndata + nndata)) {
      h_addr <- hash_list h_addr (DescDefs.ipack (map ent_addr log));
      h_valu <- hash_list h_valu (vals_nonzero log);
      cs <- Desc.write_aligned xp ndesc (map ent_addr log) cs;
      cs <- Data.write_aligned xp ndata (map ent_valu log) cs;
      cs <- Hdr.write xp ((ndesc, ndata),
                          (ndesc + nndesc, ndata + nndata),
                          (h_addr, h_valu)) cs;
      (* Extended *)

      cs <- Desc.evict_aligned xp ndesc nndesc cs;
      cs <- Data.evict_aligned xp ndata nndata cs;
      cs <- Hdr.evict xp cs;

      cs <- Desc.sync_aligned xp ndesc nndesc cs;
      cs <- Data.sync_aligned xp ndata nndata cs;
      cs <- Hdr.sync xp cs;
      (* Synced *)
      rx ^(cs, true)
    } else {
      rx ^(cs, false)
    }.

  Lemma rep_hashmap_subset : forall xp hm hm',
    (exists l, hashmap_subset l hm hm')
    -> forall st, rep xp st hm
        =p=> rep xp st hm'.
  Proof.
    intros.
    destruct st; unfold rep, rep_inner; cancel; solve_checksums.
    or_l; cancel.
    or_r; cancel.
    auto.
  Qed.

  Lemma would_recover_either'_hashmap_subset : forall xp old new hm hm',
    (exists l, hashmap_subset l hm hm') ->
    would_recover_either' xp old new hm
    =p=> would_recover_either' xp old new hm'.
  Proof.
    unfold would_recover_either'.
    intros.
    cancel;
    rewrite rep_hashmap_subset; auto; cancel.
  Qed.

  Definition extend_ok : forall xp new cs,
    {< F old d,
    PRE:hm   BUFCACHE.rep cs d *
          [[ Forall entry_valid new ]] *
          [[ (F * rep xp (Synced old) hm)%pred d ]]
    POST:hm' RET: ^(cs, r) exists d',
          BUFCACHE.rep cs d' * (
          [[ r = true /\
             (F * rep xp (Synced ((padded_log old) ++ new)) hm')%pred d' ]] \/
          [[ r = false /\ length ((padded_log old) ++ new) > LogLen xp /\
             (F * rep xp (Synced old) hm')%pred d' ]])
    CRASH:hm_crash
          would_recover_either xp F old new hm_crash
    >} extend xp new cs.
  Proof.
    unfold extend, would_recover_either, would_recover_either'.
    step.
    step.

    (* true case *)
    - (* write content *)
      step.
      unfold checksums_match in *; intuition.
      solve_hash_list_rep.
      step.
      unfold checksums_match in *; intuition.
      solve_hash_list_rep.

      safestep.
      rewrite Desc.avail_rep_split. cancel.
      autorewrite with lists; apply helper_loglen_desc_valid_extend; auto.

      safestep.
      eapply loglen_valid_data_valid; eauto.
      rewrite Data.avail_rep_split. cancel.
      autorewrite with lists.
      rewrite divup_1; rewrite <- entry_valid_ndata by auto.
      apply helper_loglen_data_valid_extend; auto.

      (* write header *)
      safestep.
      unfold Hdr.rep in H22.
      destruct_lift H22.
      unfold Hdr.hdr_goodSize in *; intuition.
      eapply loglen_valid_goodSize_l; eauto.
      eapply loglen_valid_goodSize_r; eauto.

      (* XXX: need evict_aligned_ok *)

      (* sync content *)
      safestep.
      instantiate ( 1 := map ent_addr (padded_log new) ).
      rewrite map_length, padded_log_length; auto.
      apply padded_desc_valid.
      apply loglen_valid_desc_valid; auto.
      rewrite desc_padding_unsync_piff.
      cancel.

      safestep.
      instantiate (1 := map ent_valu new).
      autorewrite with lists.
      rewrite entry_valid_ndata, Nat.mul_1_r; auto.
      apply loglen_valid_data_valid; auto.
      cancel.

      (* sync header *)
      safestep.
      cancel.

      (* post condition *)
      safestep.
      or_l; cancel.
      cancel_by extend_ok_helper; auto.
      rewrite ndesc_log_app, ndata_log_app.
      rewrite ndesc_log_padded_log, ndata_log_padded_log.
      eauto.
      rewrite padded_log_length, roundup_roundup; auto.

      unfold checksums_match; intuition.
      rewrite map_app.
      erewrite DescDefs.ipack_app.
      rewrite rev_app_distr.
      rewrite <- desc_ipack_padded.
      solve_hash_list_rep.
      rewrite map_length, padded_log_length; unfold roundup; eauto.

      rewrite vals_nonzero_app, vals_nonzero_padded_log.
      rewrite rev_app_distr.
      solve_hash_list_rep.
      solve_hashmap_subset.
      all: auto.

      (* crash conditons *)
      (* after sync data : Extended *)
      cancel.
      or_r; or_l. cancel.
      extend_crash.
      or_l; cancel.
      solve_checksums.
      solve_checksums.

      (* after header sync : Synced new *)
      or_r; or_r; or_l. cancel.
      cancel_by extend_ok_helper; auto.
      cancel_by extend_ok_synced_hdr_helper.
      solve_checksums.

      (* before sync data, after sync desc : Extended *)
      cancel.
      or_r; or_l. cancel. extend_crash.
      or_l; cancel.
      solve_checksums.
      solve_checksums.

      (* before sync desc : Extended *)
      cancel.
      or_r; or_l. cancel. extend_crash.
      or_l; cancel.
      solve_checksums.
      solve_checksums.

      (* before header write : Synced old *)
      cancel.
      or_l. cancel.
      extend_crash.
      solve_checksums.

      (* after header write : Extended *)
      or_r; or_l. cancel. extend_crash.
      or_l; cancel.
      solve_checksums.
      solve_checksums.

      (* after desc write : Synced old *)
      cancel.
      or_l. cancel.
      extend_crash.
      solve_checksums.

      (* before desc write : Synced old *)
      cancel.
      or_l. cancel.
      cancel.
      rewrite Desc.avail_rep_merge. cancel.
      rewrite map_length.
      apply helper_loglen_desc_valid_extend; auto.
      solve_checksums.

      (* after hash_list : Synced old *)
      or_l. cancel.
      solve_checksums.

      or_l. cancel.
      solve_checksums.

    (* false case *)
    - step.
      or_r; cancel.
      apply loglen_invalid_overflow; auto.
      solve_checksums.

    (* crash for the false case *)
    - cancel; hoare.
      or_l.
      cancel.
      solve_checksums.
  Qed.


  Hint Extern 1 ({{_}} progseq (avail _ _) _) => apply avail_ok : prog.
  Hint Extern 1 ({{_}} progseq (read _ _) _) => apply read_ok : prog.
  Hint Extern 1 ({{_}} progseq (trunc _ _) _) => apply trunc_ok : prog.
  Hint Extern 1 ({{_}} progseq (extend _ _ _) _) => apply extend_ok : prog.

  Theorem entry_valid_dec : forall ent,
    {entry_valid ent} + {~ entry_valid ent}.
  Proof.
    unfold entry_valid, addr_valid, goodSize; intuition.
    destruct (addr_eq_dec (fst ent) 0); destruct (lt_dec (fst ent) (pow2 addrlen)).
    right; tauto.
    right; tauto.
    left; tauto.
    right; tauto.
  Defined.

  Theorem rep_synced_length_ok : forall F xp l d hm,
    (F * rep xp (Synced l) hm)%pred d -> length l <= LogLen xp.
  Proof.
    unfold rep, rep_inner, rep_contents, xparams_ok.
    unfold Desc.array_rep, Desc.synced_array, Desc.rep_common, Desc.items_valid.
    intros; destruct_lifts.
    rewrite map_length, Nat.sub_0_r in H17.
    rewrite H5, Nat.mul_comm; auto.
  Qed.

  Lemma xform_rep_synced : forall xp l hm,
    crash_xform (rep xp (Synced l) hm) =p=> rep xp (Synced l) hm.
  Proof.
    unfold rep; simpl; unfold rep_contents; intros.
    xform.
    norm'l. unfold stars; cbn.
    xform.
    norm'l. unfold stars; cbn.
    xform.
    rewrite Data.xform_avail_rep, Desc.xform_avail_rep.
    rewrite Data.xform_synced_rep, Desc.xform_synced_rep.
    rewrite Hdr.xform_rep_synced.
    cancel.
  Qed.

  Lemma xform_rep_truncated : forall xp l hm,
    crash_xform (rep xp (Truncated l) hm) =p=>
      rep xp (Synced l) hm \/ rep xp (Synced nil) hm.
  Proof.
    unfold rep; simpl; unfold rep_contents; intros.
    xform; cancel.
    xform; cancel.
    rewrite Data.xform_avail_rep, Desc.xform_avail_rep.
    rewrite Data.xform_synced_rep, Desc.xform_synced_rep.
    rewrite Hdr.xform_rep_unsync.
    norm; auto.

    or_r; cancel.
    cancel_by helper_trunc_ok.
    auto.
    or_l; cancel.
  Qed.

  Lemma xform_rep_syncedunmatched : forall xp old new hm,
    crash_xform (rep xp (SyncedUnmatched old new) hm) =p=> rep xp (SyncedUnmatched old new) hm.
  Proof.
    unfold rep; simpl; unfold rep_contents_unmatched; intros.
    do 4 (xform;
      norm'l; unfold stars; cbn).
    xform.
    rewrite Data.xform_avail_rep, Desc.xform_avail_rep.
    rewrite Data.xform_synced_rep, Desc.xform_synced_rep.
    rewrite Data.xform_synced_rep, Desc.xform_synced_rep.
    rewrite Hdr.xform_rep_synced.
    cancel.
    congruence.
  Qed.

  Theorem rep_extended_facts' : forall xp d old new hm,
    (rep xp (Extended old new) hm)%pred d ->
    Forall entry_valid new /\
    LogLen xp >= ndata_log old + ndata_log new /\ LogDescLen xp >= ndesc_log old + ndesc_log new.
  Proof.
    unfold rep, rep_inner, rep_contents, xparams_ok.
    unfold Desc.array_rep, Desc.synced_array, Desc.rep_common, Desc.items_valid.
    intros; destruct_lifts.
    intuition.
    unfold loglen_valid in *; intuition.
    unfold loglen_valid in *; intuition.
  Qed.

  Theorem rep_extended_facts : forall xp old new hm,
    rep xp (Extended old new) hm =p=>
    (rep xp (Extended old new) hm *
      [[ LogLen xp >= ndata_log old + ndata_log new ]] *
      [[ LogDescLen xp >= ndesc_log old + ndesc_log new ]] *
      [[ Forall entry_valid new ]] )%pred.
  Proof.
    unfold pimpl; intros.
    pose proof rep_extended_facts' H.
    pred_apply; cancel.
  Qed.

  Lemma helper_sep_star_distr: forall AT AEQ V (a b c d : @pred AT AEQ V),
    a * b * c * d =p=> (c * a) * (d * b).
  Proof.
    intros; cancel.
  Qed.

  Lemma helper_add_sub_add : forall a b c,
    b >= c + a -> a + (b - (c + a)) = b - c.
  Proof.
    intros; omega.
  Qed.

  Lemma xform_rep_extended_helper : forall xp old new,
    xparams_ok xp
    -> LogLen xp >= ndata_log old + ndata_log new
    -> LogDescLen xp >= ndesc_log old + ndesc_log new
    -> Forall addr_valid old
    -> Forall entry_valid new
    -> crash_xform (Data.avail_rep xp (ndata_log old) (LogLen xp - ndata_log old)) *
        crash_xform (Desc.avail_rep xp (ndesc_log old) (LogDescLen xp - ndesc_log old)) *
        crash_xform (Data.array_rep xp 0 (Data.Synced (vals_nonzero old))) *
        crash_xform (Desc.array_rep xp 0 (Desc.Synced (map ent_addr old)))
      =p=> exists synced_addr synced_valu ndesc,
        rep_contents_unmatched xp old synced_addr synced_valu *
        [[ length synced_addr = (ndesc * DescSig.items_per_val)%nat ]] *
        [[ ndesc = ndesc_log new ]] *
        [[ length synced_valu = ndata_log new ]].
  Proof.
    intros.
    rewrite Data.avail_rep_split with (n1:=ndata_log new).
    rewrite Desc.avail_rep_split with (n1:=ndesc_log new).
    xform.
    erewrite Data.xform_avail_rep_array_rep, Desc.xform_avail_rep_array_rep.
    norml. unfold stars; simpl.
    norm.
    unfold stars; simpl.
    cancel.
    rewrite Data.xform_avail_rep, Desc.xform_avail_rep.
    rewrite Data.xform_synced_rep, Desc.xform_synced_rep.
    unfold rep_contents_unmatched.
    rewrite vals_nonzero_padded_log, desc_padding_synced_piff.
    cancel.
    replace (@ndesc_list waddr l) with (ndesc_log new).
    replace (@length valu l0) with (ndata_log new).
    cancel.

    replace DataSig.items_per_val with 1 in * by (cbv; auto); try omega.
    unfold ndesc_list.
    rewrite H12.
    unfold ndesc_log.
    rewrite divup_divup; auto.

    replace DataSig.items_per_val with 1 in * by (cbv; auto); try omega.
    intuition; auto.
    all: unfold DescSig.RALen, DataSig.RALen, xparams_ok in *;
          try omega; auto; intuition.

    apply mult_le_compat_r; omega.

    replace DataSig.items_per_val with 1 in * by (cbv; auto); try omega.
  Qed.

  Lemma xform_rep_extended : forall xp old new hm,
    crash_xform (rep xp (Extended old new) hm) =p=>
       rep xp (Synced old) hm \/
       rep xp (SyncedUnmatched old new) hm.
  Proof.
    intros; rewrite rep_extended_facts.
    unfold rep; simpl; unfold rep_contents; intros.
    xform; cancel.
    unfold Hdr.rep.
    xform; cancel.

    - subst.
      or_r.

      rewrite xform_rep_extended_helper; try eassumption.
      cancel.
      subst; auto.

    - or_l.
      cancel.
      rewrite Data.xform_avail_rep, Desc.xform_avail_rep.
      rewrite Data.xform_synced_rep, Desc.xform_synced_rep.
      cancel.

    - or_l.
      cancel.
      rewrite Data.xform_avail_rep, Desc.xform_avail_rep.
      rewrite Data.xform_synced_rep, Desc.xform_synced_rep.
      cancel.

    - subst.
      or_r.

      rewrite xform_rep_extended_helper; try eassumption.
      cancel.
      subst; auto.
  Qed.

  Lemma xform_would_recover_either' : forall xp old new hm,
    crash_xform (would_recover_either' xp old new hm) =p=>
      would_recover_either' xp old new hm.
  Proof.
    unfold would_recover_either'.
    intros.
    xform.
    cancel; (rewrite xform_rep_synced ||
              rewrite xform_rep_extended ||
              rewrite xform_rep_syncedunmatched); cancel.
  Qed.

  Lemma rep_synced_app_pimpl : forall xp old new hm,
    rep xp (Synced (padded_log old ++ new)) hm =p=>
    rep xp (Synced (padded_log old ++ padded_log new)) hm.
  Proof.
    unfold rep; simpl; intros; unfold rep_contents; cancel.
    setoid_rewrite ndesc_log_padded_app.
    setoid_rewrite ndata_log_padded_app.
    rewrite ndesc_log_padded_log, ndata_log_padded_log.
    setoid_rewrite map_app.
    setoid_rewrite vals_nonzero_app.
    setoid_rewrite vals_nonzero_padded_log.
    cancel.

    rewrite Desc.array_rep_synced_app_rev.
    setoid_rewrite <- desc_padding_synced_piff at 2.
    eapply pimpl_trans2.
    eapply Desc.array_rep_synced_app.
    rewrite map_length, padded_log_length; unfold roundup; eauto.
    cancel.
    rewrite map_length, padded_log_length; unfold roundup; eauto.
    apply Forall_append.
    eapply forall_app_r; eauto.
    apply addr_valid_padded; auto.
    eapply forall_app_l; eauto.
    solve_checksums.
    rewrite <- rev_app_distr.
    erewrite <- DescDefs.ipack_app.
    rewrite <- map_app.
    solve_hash_list_rep.
    rewrite map_length, padded_log_length; unfold roundup; eauto.
    rewrite <- rev_app_distr.
    rewrite vals_nonzero_padded_log.
    rewrite <- vals_nonzero_padded_log.
    rewrite <- vals_nonzero_app.
    solve_hash_list_rep.
  Qed.

  Lemma weq2 : forall sz (x y : word sz) (a b : word sz),
    {x = y /\ a = b} + {(x = y /\ a <> b) \/
                        (x <> y /\ a = b) \/
                        (x <> y /\ a <> b)}.
  Proof.
    intros.
    destruct (weq x y); destruct (weq a b); intuition.
  Defined.

  Lemma desc_ipack_injective : forall l1 l2 n1 n2,
    length l1 = n1 * DescSig.items_per_val ->
    length l2 = n2 * DescSig.items_per_val ->
    DescDefs.ipack l1 = DescDefs.ipack l2 ->
    l1 = l2.
  Proof.
    intros.
    erewrite <- DescDefs.iunpack_ipack; eauto.
    erewrite <- DescDefs.iunpack_ipack at 1; eauto.
    congruence.
  Qed.

  Lemma ndesc_log_ndesc_list : forall l,
    ndesc_log l = ndesc_list (map ent_addr (padded_log l)).
  Proof.
    unfold ndesc_log, ndesc_list.
    intros.
    autorewrite with lists.
    rewrite padded_log_length.
    unfold roundup.
    rewrite divup_divup; auto.
  Qed.

  Definition recover T xp cs rx : prog T :=
    let^ (cs, header) <- Hdr.read xp cs;
    let '((prev_ndesc, prev_ndata),
          (ndesc, ndata),
          (addr_checksum, valu_checksum)) := header in
    let^ (cs, wal) <- Desc.read_all xp ndesc cs;
    let^ (cs, vl) <- Data.read_all xp ndata cs;
    h_addr <- hash_list default_hash (DescDefs.ipack wal);
    h_valu <- hash_list default_hash vl;
    If (weq2 addr_checksum h_addr valu_checksum h_valu) {
      rx cs
    } else {
      let^ (cs, wal) <- Desc.read_all xp prev_ndesc cs;
      let^ (cs, vl) <- Data.read_all xp prev_ndata cs;
      addr_checksum <- hash_list default_hash (DescDefs.ipack wal);
      valu_checksum <- hash_list default_hash vl;
      cs <- Hdr.write xp ((prev_ndesc, prev_ndata),
                          (prev_ndesc, prev_ndata),
                          (addr_checksum, valu_checksum)) cs;
      cs <- Hdr.sync xp cs;
      rx cs
    }.

  Lemma recover_read_ok_helper : forall xp old new,
     Desc.array_rep xp 0 (Desc.Synced (map ent_addr (padded_log old ++ new))) =p=>
      Desc.array_rep xp 0 (Desc.Synced (map ent_addr (padded_log old ++ padded_log new))).
  Proof.
    intros.
    repeat rewrite map_app.
    rewrite Desc.array_rep_synced_app_rev.
    rewrite <- Desc.array_rep_synced_app.
    cancel.
    rewrite desc_padding_synced_piff.
    cancel.
    rewrite map_length, padded_log_length. unfold roundup; eauto.
    rewrite map_length, padded_log_length. unfold roundup; eauto.
  Qed.

  Lemma recover_ok_addr_helper : forall xp old new,
    Desc.array_rep xp 0
        (Desc.Synced
          (map ent_addr (padded_log old) ++ map ent_addr (padded_log new))) =p=>
    Desc.array_rep xp 0
      (Desc.Synced (map ent_addr (padded_log old ++ new))).
  Proof.
    intros.
    rewrite map_app.
    eapply pimpl_trans; [ | eapply Desc.array_rep_synced_app ].
    rewrite Desc.array_rep_synced_app_rev.
    cancel.
    apply desc_padding_synced_piff.
    rewrite map_length, padded_log_length; unfold roundup; eauto.
    rewrite map_length, padded_log_length; unfold roundup; eauto.
  Qed.

  Lemma recover_desc_avail_helper : forall T xp old (new : list T) ndata,
    loglen_valid xp (ndesc_log old + ndesc_list new) ndata ->
    (Desc.avail_rep xp (ndesc_log old) (ndesc_list new)
     * Desc.avail_rep xp (ndesc_log old + ndesc_list new)
         (LogDescLen xp - ndesc_log old - ndesc_list new))
    =p=> Desc.avail_rep xp (ndesc_log old) (LogDescLen xp - ndesc_log old).
  Proof.
    intros.
    rewrite Desc.avail_rep_merge;
    eauto.
    rewrite le_plus_minus_r;
    auto.
    unfold loglen_valid in *;
    omega.
  Qed.

  Lemma recover_data_avail_helper : forall T xp old (new : list T) ndesc,
    loglen_valid xp ndesc (ndata_log old + length new) ->
    Data.avail_rep xp (ndata_log old)
          (divup (length new) DataSig.items_per_val)
    * Data.avail_rep xp (ndata_log old + length new)
        (LogLen xp - ndata_log old - length new)
    =p=> Data.avail_rep xp (nonzero_addrs (map fst old))
           (LogLen xp - nonzero_addrs (map fst old)).
  Proof.
    intros.
    replace DataSig.items_per_val with 1 by (cbv; auto); try omega.
    rewrite divup_1, Data.avail_rep_merge;
    eauto.
    rewrite le_plus_minus_r;
    auto.
    unfold loglen_valid in *;
    omega.
  Qed.


  Definition recover_ok_Synced : forall xp cs,
    {< F l d,
    PRE:hm   BUFCACHE.rep cs d *
          [[ (F * rep xp (Synced l) hm)%pred d ]]
    POST:hm' RET:cs'
          BUFCACHE.rep cs' d *
          [[ (F * rep xp (Synced l) hm')%pred d ]]
    CRASH:hm_crash exists cs',
          BUFCACHE.rep cs' d *
          [[ (F * rep xp (Synced l) hm_crash)%pred d ]]
    >} recover xp cs.
  Proof.
    unfold recover.
    step.
    prestep. norm. cancel. intuition simpl.
    eassign (map ent_addr (padded_log l)).
    rewrite map_length, padded_log_length.
    all: auto.
    rewrite desc_padding_synced_piff.
    cancel.

    safestep; subst.
    instantiate (1:= vals_nonzero l).
    rewrite vals_nonzero_addrs.
    replace DataSig.items_per_val with 1 by (cbv; auto); omega.
    all: auto.
    cancel.

    step.
    solve_hash_list_rep; auto.
    intros.
    eapply pimpl_ok2.
    eapply hash_list_ok. cancel.
    solve_hash_list_rep; auto.
    step.

    {
      step.
      apply desc_padding_synced_piff.
      solve_checksums.
    }
    {
      eapply pimpl_ok2; eauto with prog.
      intros.
      unfold pimpl; intros.
      unfold checksums_match in *; intuition.
      rewrite app_nil_r, <- desc_ipack_padded in *.
      destruct_lift H15; intuition.

      contradict H24.
      eapply hash_list_injective2; solve_hash_list_rep.

      contradict H15.
      eapply hash_list_injective2; solve_hash_list_rep.

      contradict H15.
      eapply hash_list_injective2; solve_hash_list_rep.
    }

    all: try cancel;
          solve [ apply desc_padding_synced_piff | solve_checksums ].
  Qed.

  Definition recover_ok_SyncedUnmatched : forall xp cs,
    {< F old new d,
    PRE:hm   BUFCACHE.rep cs d *
          [[ (F * rep xp (SyncedUnmatched old new) hm)%pred d ]]
    POST:hm' RET:cs' exists d',
          BUFCACHE.rep cs' d' * (
          [[ (F * rep xp (Synced old) hm')%pred d' ]] \/
          [[ (F * rep xp (Synced (padded_log old ++ new)) hm')%pred d' ]])
    CRASH:hm_crash
          would_recover_either xp F old new hm_crash
    >} recover xp cs.
  Proof.
    unfold recover, would_recover_either, would_recover_either'.
    step.
    safestep. subst.
    instantiate (1:=(map ent_addr (padded_log old) ++ dummy0)).
    autorewrite with lists.
    rewrite Nat.mul_add_distr_r.
    rewrite padded_log_length.
    all: auto.

    unfold rep_contents_unmatched.
    rewrite <- Desc.array_rep_synced_app.
    repeat rewrite desc_padding_synced_piff.
    autorewrite with lists.
    rewrite <- ndesc_log_padded_log.
    unfold ndesc_log; cancel.
    autorewrite with lists.
    rewrite padded_log_length; unfold roundup; eauto.

    prestep. norm. cancel. intuition simpl.
    eassign (vals_nonzero (padded_log old) ++ dummy1).
    autorewrite with lists.
    rewrite vals_nonzero_addrs, nonzero_addrs_padded_log, Nat.mul_add_distr_r.
    replace DataSig.items_per_val with 1 by (cbv; auto); omega.
    all: auto.

    rewrite <- Data.array_rep_synced_app.
    replace DataSig.items_per_val with 1 by (cbv; auto); try omega.
    rewrite vals_nonzero_addrs, nonzero_addrs_padded_log, divup_1.
    cancel.
    replace DataSig.items_per_val with 1 by (cbv; auto); try omega.
    rewrite Nat.mul_1_r; eauto.

    intros.
    eapply pimpl_ok2.
    eapply hash_list_ok.
    cancel.
    solve_hash_list_rep; auto.
    intros.
    eapply pimpl_ok2.
    eapply hash_list_ok. cancel.
    solve_hash_list_rep; auto.
    step.

    (* True case: the hash matched what was on disk. *)
    {
      step.
      or_r.
      cancel.
      unfold checksums_match in *; intuition.
      assert (Hal: map ent_addr (padded_log old) ++ map ent_addr (padded_log new) = map ent_addr (padded_log old) ++ dummy0).
        match goal with
        | [ H: context[Desc.array_rep] |- _ ]
          => unfold Desc.array_rep, Desc.synced_array in H;
            destruct_lift H
        end.
        unfold Desc.rep_common in *; intuition.

        eapply desc_ipack_injective; eauto.
        autorewrite with lists.
        repeat rewrite padded_log_length.
        unfold roundup.
        rewrite <- Nat.mul_add_distr_r; eauto.
        autorewrite with lists.
        rewrite padded_log_length, H14.
        unfold roundup.
        rewrite <- Nat.mul_add_distr_r; eauto.

        rewrite <- map_app.
        rewrite <- padded_log_app.
        rewrite <- desc_ipack_padded.
        apply rev_injective.
        rewrite app_nil_r in *.
        eapply hash_list_injective;
        solve_hash_list_rep.

      apply app_inv_head in Hal.
      autorewrite with lists.
      rewrite <- Hal.

      rewrite recover_ok_addr_helper.
      cancel.

      rewrite ndesc_log_padded_app.
      rewrite <- ndesc_log_ndesc_list.
      replace (ndesc_log old) with (ndesc_log (padded_log old)) by (rewrite ndesc_log_padded_log; auto).
      rewrite Nat.sub_add_distr.
      cancel.

      assert (Hvl: dummy1 = vals_nonzero new).
        eapply app_inv_head.
        erewrite <- vals_nonzero_app.
        rewrite app_nil_r in *.
        apply rev_injective.
        eapply hash_list_injective;
        solve_hash_list_rep.

      rewrite Hvl.
      rewrite vals_nonzero_app.
      cancel.

      rewrite ndata_log_app.
      rewrite Nat.sub_add_distr.
      rewrite ndata_log_padded_log.
      rewrite vals_nonzero_addrs.
      cancel.

      match goal with
      | [ H: context[rep_contents_unmatched] |- _ ]
        => unfold rep_contents_unmatched in H; destruct_lift H
      end.
      apply Forall_append.
      apply addr_valid_padded; auto.
      auto.

      solve_checksums.
    }

    (* False case: the hash did not match what was on disk and we need to recover. *)
    {
      clear H7 H13.
      safestep.
      instantiate (1:= map ent_addr (padded_log old)).
      rewrite map_length, padded_log_length.
      all: auto.
      unfold rep_contents_unmatched.
      cancel.

      (* Remove the else condition. *)
      match goal with
      | [ H: _ \/ _ |- _ ]
        => clear H
      end.

      safestep.
      instantiate (1:= vals_nonzero old).
      rewrite vals_nonzero_addrs.
      replace DataSig.items_per_val with 1 by (cbv; auto); omega.
      all: auto.
      rewrite vals_nonzero_padded_log.
      cancel.

      step.
      solve_hash_list_rep; eauto.
      eapply pimpl_ok2; try apply hash_list_ok.
      cancel.
      solve_hash_list_rep; eauto.

      step.
      match goal with
      | [ H: ( _ )%pred d |- _ ]
        => unfold Hdr.rep in H; destruct_lift H
      end.
      unfold Hdr.hdr_goodSize in *; intuition.

      clear H19 H13.
      step.
      step.

      (* post condition: Synced old *)
      or_l. cancel.
      rewrite desc_padding_synced_piff.
      rewrite Desc.array_rep_avail_synced, Data.array_rep_avail_synced.
      cancel.

      rewrite <- recover_desc_avail_helper with (new:=dummy0).
      rewrite <- recover_data_avail_helper with (new:=dummy1).
      cancel.
      replace (length dummy1) with (ndata_log new); eauto.
      replace (ndesc_list dummy0) with (ndesc_log new); eauto.
      unfold ndesc_list.
      replace (length dummy0) with (@length waddr dummy0) by auto.
      match goal with
      | [ H: length ?l = _ |- context[length ?l] ]
        => rewrite H
      end.
      unfold ndesc_log; rewrite divup_divup; auto.
      match goal with
      | [ H: context[rep_contents_unmatched] |- _ ]
        => unfold rep_contents_unmatched in H; destruct_lift H
      end;
      auto.
      solve_checksums.

      (* Crash conditions. *)
      (* Before header sync: Extended *)
      or_r; or_l.
      cancel.
      rewrite desc_padding_synced_piff.
      cancel.
      rewrite Desc.array_rep_avail_synced, Data.array_rep_avail_synced.
      rewrite <- recover_desc_avail_helper with (new:=dummy0).
      unfold ndata_log.
      rewrite <- recover_data_avail_helper with (new:=dummy1).
      cancel. or_r; cancel.
      replace (length dummy1) with (ndata_log new); eauto.
      replace (ndesc_list dummy0) with (ndesc_log new); eauto.
      unfold ndesc_list.
      replace (length dummy0) with (@length waddr dummy0) by auto.
      match goal with
      | [ H: length ?l = _ |- context[length ?l] ]
        => rewrite H
      end.
      unfold ndesc_log; rewrite divup_divup; auto.
      match goal with
      | [ H: context[rep_contents_unmatched] |- _ ]
        => unfold rep_contents_unmatched in H; destruct_lift H
      end;
      auto.
      solve_checksums.
      solve_checksums.

      (* After header sync: Synced old *)
      or_l.
      cancel.
      rewrite desc_padding_synced_piff.
      cancel.
      rewrite Desc.array_rep_avail_synced, Data.array_rep_avail_synced.
      rewrite <- recover_desc_avail_helper with (new:=dummy0).
      rewrite <- recover_data_avail_helper with (new:=dummy1).
      cancel.
      replace (length dummy1) with (ndata_log new); eauto.
      replace (ndesc_list dummy0) with (ndesc_log new); eauto.
      unfold ndesc_list.
      replace (length dummy0) with (@length waddr dummy0) by auto.
      match goal with
      | [ H: length ?l = _ |- context[length ?l] ]
        => rewrite H
      end.
      unfold ndesc_log; rewrite divup_divup; auto.
      match goal with
      | [ H: context[rep_contents_unmatched] |- _ ]
        => unfold rep_contents_unmatched in H; destruct_lift H
      end;
      auto.
      solve_checksums.

      (* Before header write: SyncedUnmatched old new *)
      or_r; or_r; or_r.
      unfold rep_contents_unmatched.
      match goal with
      | [ H: context[rep_contents_unmatched] |- _ ]
        => unfold rep_contents_unmatched in H; destruct_lift H
      end.
      cancel.
      rewrite vals_nonzero_padded_log; auto.
      congruence.
      solve_checksums.

      (* Extended *)
      admit.

      cancel.
      (* SyncedUnmatched old new *)
      admit.

      (* SyncedUnmatched old new *)
      admit.

      cancel.
      (* SyncedUnmatched old new *)
      admit.

      match goal with
      | [ H: _ \/ _ |- _ ]
        => clear H
      end.
      cancel.
      (* SyncedUnmatched old new *)
      admit.
    }

    all: intros;
      try clear H7; try clear H13;
      try (erewrite <- H1; cancel);
      or_r; or_r; or_r;
      cancel_with solve_checksums;
      auto.

  Admitted.


  Definition recover_ok : forall xp cs,
    {< F st,
    PRE:hm
      exists d, BUFCACHE.rep cs d *
          [[ (F * rep xp st hm)%pred d ]] *
          [[ (exists l, st = Synced l) \/
              (exists old new, st = SyncedUnmatched old new) ]]
    POST:hm' RET:cs' exists d',
          BUFCACHE.rep cs' d' *
          [[ (F * rep_recovers_to xp st hm')%pred d' ]]
    CRASH:hm' exists cs' d',
          BUFCACHE.rep cs' d' *
          [[ (F * rep_crashes_to xp st hm')%pred d' ]]
    >} recover xp cs.
  Proof.
    intros.
    eapply pimpl_ok2; try eapply nop_ok.
    intros. norm'l. unfold stars; cbn.

    destruct st.

    (* Synced *)
    - cancel.
      eapply pimpl_ok2; try apply recover_ok_Synced.
      cancel.
      eassign l.
      cancel.
      hoare.
      all: repeat cancel.
      repeat deex.
      inversion H0.

    (* Truncated: false case *)
    - contradict H4.
      intuition; repeat deex; inversion H0.

    (* Extended: false case *)
    - contradict H4.
      intuition; repeat deex; inversion H0.

    (* SyncedUnmatched *)
    - cancel.
      repeat deex; inversion H0.
      repeat deex; inversion H0.

      eapply pimpl_ok2; try apply recover_ok_SyncedUnmatched.
      cancel.
      eassign old.
      eassign new.
      cancel.
      hoare.
      unfold would_recover_either.
      all: repeat cancel.
      unfold would_recover_either'.
      cancel.
  Qed.


  Hint Extern 1 ({{_}} progseq (recover _ _) _) => apply recover_ok : prog.


  (**
   * It seems like [recover'] is the important thing here, and the [recover] below
   * is actually not needed; higher layers already take care of first calling
   * BUFCACHE.init_recover, then sb_load, and finally calling the log's [recover]
   **)

  (*
  Definition recover {T} cs lxp rx : prog T :=
    cs <- BUFCACHE.init_recover 1;
    let^ (cs, fsxp) <- sb_load cs;
    cs <- recover' (FSXPLog fsxp) cs;
    rx ^(fsxp, cs).

  Definition recover_ok :
    {< fsxp old new,
    PRE:hm
      crash_xform (would_recover_either (FSXPLog fsxp) (sb_rep fsxp) old new hm)
    POST:hm' RET:^(fsxp', cs') exists d',
      [[ fsxp = fsxp' ]] *
      BUFCACHE.rep cs' d' * (
      [[ ((sb_rep fsxp) * rep (FSXPLog fsxp) (Synced old) hm')%pred d' ]] \/
      [[ ((sb_rep fsxp) * rep (FSXPLog fsxp) (Synced (padded_log old ++ new)) hm')%pred d' ]])
    CRASH:hm_crash
      would_recover_either (FSXPLog fsxp) (sb_rep fsxp) old new hm_crash
    >} recover.
  Proof.
    unfold recover, would_recover_either.
    intros.
    eapply pimpl_ok2; eauto with prog.
    intros. norm'l. unfold stars; cbn.

    rewrite crash_xform_exists_comm.
    norm'l. unfold stars; cbn.
    rewrite crash_xform_exists_comm.
    norm'l. unfold stars; cbn.
    rewrite crash_xform_sep_star_dist.
    rewrite crash_xform_lift_empty.
    norm'l. unfold stars; cbn.
    cancel. cancel. eauto.
    eauto.

    step.
    autorewrite with crash_xform. cancel.

    eapply pimpl_ok2; eauto with prog.
    intros. norm'l. unfold stars; cbn.
    cancel.
    rewrite would_recover_either'_hashmap_subset; eauto.

    step.
    or_l. cancel.
    autorewrite with crash_xform. eauto.

    or_r. cancel.
    autorewrite with crash_xform. eauto.

    unfold would_recover_either.
    norm'l; unfold stars; cbn.
    cancel.
    autorewrite with crash_xform; eauto.

    autorewrite with crash_xform; eauto.
    cancel.
    rewrite xform_would_recover_either'.
    rewrite would_recover_either'_hashmap_subset; eauto.

    norm'l; unfold stars; cbn.
    autorewrite with crash_xform.
    rewrite <- H1.
    norm'l. unfold stars; cbn.
    norm'r.
    cancel.
    intuition.


    assert (Hxform: crash_xform (sb_rep fsxp * would_recover_either' (FSXPLog fsxp) old new hm)%pred m').
    unfold crash_xform.
    exists x0; intuition.

    pred_apply.
    autorewrite with crash_xform.
    rewrite xform_would_recover_either'.
    rewrite would_recover_either'_hashmap_subset; eauto.
  Qed.
  *)


  (**
   * The below proofs are not actually necessary, though they are useful as a
   * sanity check.  The [corr3] statements should probably show up in AsyncFS.v.
   *)

  (*
  Definition extend_recover_ok : forall fsxp new cs,
    {<< old d,
    PRE:hm   BUFCACHE.rep cs d *
          [[ Forall entry_valid new ]] *
          [[ (sb_rep fsxp * rep (FSXPLog fsxp) (Synced old) hm)%pred d ]]
    POST:hm' RET: ^(cs', r) exists d',
          BUFCACHE.rep cs' d' * (
          [[ r = true /\
             (sb_rep fsxp * rep (FSXPLog fsxp) (Synced ((padded_log old) ++ new)) hm')%pred d' ]] \/
          [[ r = false /\ length ((padded_log old) ++ new) > LogLen (FSXPLog fsxp) /\
             (sb_rep fsxp * rep (FSXPLog fsxp) (Synced old) hm')%pred d' ]])
    REC:hm' RET:^(fsxp', cs') exists d',
          [[ fsxp = fsxp' ]] *
          BUFCACHE.rep cs' d' * (
          [[ (sb_rep fsxp * rep (FSXPLog fsxp) (Synced old) hm')%pred d' ]] \/
          [[ (sb_rep fsxp * rep (FSXPLog fsxp) (Synced (padded_log old ++ new)) hm')%pred d' ]])
    >>} extend (FSXPLog fsxp) new cs >> recover.
  Proof.
    unfold forall_helper; intros.
    eexists.

    Require Import Idempotent.
    intros.
    eapply pimpl_ok3.
    eapply corr3_from_corr2; eauto with prog.
    apply extend_ok.
    apply recover_ok.

    cancel.
    cancel. eauto.

    step.
    cancel.
    xform.
    norm'l; unfold stars; cbn.
    cancel.
    cancel. eauto.

    step.
    all: rewrite H3; cancel.

    or_l; cancel.
    or_r; cancel.
  Qed.
  *)

End PaddedLog.


Module DLog.

  Definition entry := (addr * valu)%type.
  Definition contents := list entry.

  Inductive state :=
  (* The log is synced on disk *)
  | Synced (navail : nat) (l: contents)
  (* The log has been truncated; but the length (0) is unsynced *)
  | Truncated  (old: contents)
  (* The log is being extended; only the content has been updated (unsynced) *)
  | ExtendedUnsync (old: contents)
  (* The log has been extended; the new contents are synced but the length is unsynced *)
  | Extended  (old: contents) (new: contents)
  | SyncedUnmatched (old: contents) (new: contents).

  Definition rep_common l padded : rawpred :=
      ([[ l = PaddedLog.log_nonzero padded /\
         length padded = roundup (length padded) PaddedLog.DescSig.items_per_val ]])%pred.

  Definition rep xp st hm :=
    (match st with
    | Synced navail l =>
          exists padded, rep_common l padded *
          [[ navail = (LogLen xp) - (length padded) ]] *
          PaddedLog.rep xp (PaddedLog.Synced padded) hm
    | Truncated l =>
          exists padded, rep_common l padded *
          PaddedLog.rep xp (PaddedLog.Truncated padded) hm
    | ExtendedUnsync l =>
          exists padded, rep_common l padded *
          PaddedLog.rep xp (PaddedLog.Synced padded) hm
    | Extended l new =>
          exists padded, rep_common l padded *
          PaddedLog.rep xp (PaddedLog.Extended padded new) hm
    | SyncedUnmatched l new =>
          exists padded, rep_common l padded *
          PaddedLog.rep xp (PaddedLog.SyncedUnmatched padded new) hm
    end)%pred.

  Local Hint Unfold rep rep_common : hoare_unfold.

  Section UnifyProof.
  Hint Extern 0 (okToUnify (PaddedLog.rep _ _) (PaddedLog.rep _ _)) => constructor : okToUnify.

  Definition read T xp cs rx : prog T :=
    r <- PaddedLog.read xp cs;
    rx r.

  Definition read_ok : forall xp cs,
    {< F l d nr,
    PRE:hm    BUFCACHE.rep cs d * 
              [[ (F * rep xp (Synced nr l) hm)%pred d ]]
    POST:hm'   RET: ^(cs, r)
              BUFCACHE.rep cs d *
              [[ r = l /\ (F * rep xp (Synced nr l) hm')%pred d ]]
    CRASH:hm' exists cs',
              BUFCACHE.rep cs' d *
              [[ (F * rep xp (Synced nr l) hm')%pred d ]]
    >} read xp cs.
  Proof.
    unfold read.
    hoare.
  Qed.

  Definition trunc T xp cs rx : prog T :=
    cs <- PaddedLog.trunc xp cs;
    rx cs.

  Definition trunc_ok : forall xp cs,
    {< F l d nr,
    PRE:hm    BUFCACHE.rep cs d *
              [[ (F * rep xp (Synced nr l) hm)%pred d ]]
    POST:hm' RET: cs exists d',
              BUFCACHE.rep cs d' *
              [[ (F * rep xp (Synced (LogLen xp) nil) hm')%pred d' ]]
    CRASH:hm' exists cs d',
              BUFCACHE.rep cs d' * (
              [[ (F * rep xp (Synced nr l) hm')%pred d' ]] \/
              [[ (F * rep xp (Truncated l) hm')%pred d' ]] \/
              [[ (F * rep xp (Synced (LogLen xp) nil) hm')%pred d' ]])
    >} trunc xp cs.
  Proof.
    unfold trunc.
    hoare.
    unfold roundup; rewrite divup_0; omega.

    (* crashes *)
    or_r; cancel.
    or_r; cancel.
    unfold roundup; rewrite divup_0; omega.
  Qed.


  Definition avail T xp cs rx : prog T :=
    r <- PaddedLog.avail xp cs;
    rx r.

  Definition avail_ok : forall xp cs,
    {< F l d nr,
    PRE:hm BUFCACHE.rep cs d *
          [[ (F * rep xp (Synced nr l) hm)%pred d ]]
    POST:hm' RET: ^(cs, r)
          BUFCACHE.rep cs d *
          [[ (F * rep xp (Synced nr l) hm')%pred d ]] *
          [[ r = nr ]]
    CRASH:hm' exists cs',
          BUFCACHE.rep cs' d *
          [[ (F * rep xp (Synced nr l) hm')%pred d ]]
    >} avail xp cs.
  Proof.
    unfold avail.
    step.
    step.
  Qed.

  End UnifyProof.

  Local Hint Resolve PaddedLog.DescDefs.items_per_val_gt_0.

  Lemma extend_length_ok' : forall l new,
    length l = roundup (length l) PaddedLog.DescSig.items_per_val ->
    length (l ++ PaddedLog.padded_log new)
      = roundup (length (l ++ PaddedLog.padded_log new)) PaddedLog.DescSig.items_per_val.
  Proof.
    intros.
    repeat rewrite app_length.
    repeat rewrite PaddedLog.padded_log_length.
    rewrite H.
    rewrite roundup_roundup_add, roundup_roundup; auto.
  Qed.

  Lemma extend_length_ok : forall l new,
    length l = roundup (length l) PaddedLog.DescSig.items_per_val ->
    length (PaddedLog.padded_log l ++ PaddedLog.padded_log new)
      = roundup (length (PaddedLog.padded_log l ++ PaddedLog.padded_log new)) PaddedLog.DescSig.items_per_val.
  Proof.
    intros.
    apply extend_length_ok'.
    rewrite PaddedLog.padded_log_length.
    rewrite roundup_roundup; auto.
  Qed.

  Lemma helper_extend_length_ok : forall xp padded new F d hm,
    length padded = roundup (length padded) PaddedLog.DescSig.items_per_val
    -> length (PaddedLog.padded_log padded ++ new) > LogLen xp
    -> (F * PaddedLog.rep xp (PaddedLog.Synced padded) hm)%pred d
    -> length new > LogLen xp - length padded.
  Proof.
    intros.
    rewrite app_length in H0.
    pose proof (PaddedLog.rep_synced_length_ok H1).
    generalize H2.
    rewrite H.
    rewrite <- PaddedLog.padded_log_length.
    intro; omega.
  Qed.

  Local Hint Resolve extend_length_ok helper_extend_length_ok PaddedLog.log_nonzero_padded_app.

  Definition extend T xp new cs rx : prog T :=
    r <- PaddedLog.extend xp new cs;
    rx r.

  Definition rounded n := roundup n PaddedLog.DescSig.items_per_val.

  Definition entries_valid l := Forall PaddedLog.entry_valid l.

  Lemma extend_navail_ok : forall xp padded new, 
    length padded = roundup (length padded) PaddedLog.DescSig.items_per_val ->
    LogLen xp - length padded - rounded (length new)
    = LogLen xp - length (PaddedLog.padded_log padded ++ PaddedLog.padded_log new).
  Proof.
    unfold rounded; intros.
    rewrite extend_length_ok by auto.
    rewrite app_length.
    rewrite H.
    repeat rewrite PaddedLog.padded_log_length.
    rewrite roundup_roundup_add by auto.
    rewrite roundup_roundup by auto.
    omega.
  Qed.

  Local Hint Resolve extend_navail_ok PaddedLog.rep_synced_app_pimpl.

  Definition would_recover_either' xp old new hm :=
    ((exists nr, rep xp (Synced nr old) hm) \/
    rep xp (Extended old new) hm \/
    (exists nr, rep xp (Synced nr (old ++ new)) hm) \/
    rep xp (SyncedUnmatched old new) hm)%pred.

  Definition would_recover_either xp F old new hm :=
    (exists cs d,
      BUFCACHE.rep cs d *
      [[ (F * would_recover_either' xp old new hm)%pred d ]])%pred.


  Definition extend_ok : forall xp new cs,
    {< F old d nr,
    PRE:hm    BUFCACHE.rep cs d * [[ entries_valid new ]] *
              [[ (F * rep xp (Synced nr old) hm)%pred d ]]
    POST:hm' RET: ^(cs, r) exists d',
              BUFCACHE.rep cs d' * (
              [[ r = true /\
                (F * rep xp (Synced (nr - (rounded (length new))) (old ++ new)) hm')%pred d' ]] \/
              [[ r = false /\ length new > nr /\
                (F * rep xp (Synced nr old) hm')%pred d' ]])
    CRASH:hm'
              would_recover_either xp F old new hm'
    >} extend xp new cs.
  Proof.
    unfold extend.

    prestep.
    cancel. cancel. eauto.
    step.

    or_l. norm; [ cancel | intuition; pred_apply; norm ].
    instantiate (1 := (PaddedLog.padded_log dummy ++ PaddedLog.padded_log new)).
    cancel; auto.
    intuition.

    cancel.
    unfold PaddedLog.would_recover_either, PaddedLog.would_recover_either'.
    unfold would_recover_either, would_recover_either'.
    unfold rep, rep_common.
    cancel.

    or_l; cancel.
    or_r; or_l; cancel.
    or_r; or_r; or_l. norm.
    eassign (PaddedLog.padded_log dummy ++ PaddedLog.padded_log new).
    unfold stars; simpl.
    rewrite <- PaddedLog.rep_synced_app_pimpl.
    cancel.
    intuition.
    or_r; or_r; or_r; cancel.
  Qed.

  Hint Extern 1 ({{_}} progseq (avail _ _) _) => apply avail_ok : prog.
  Hint Extern 1 ({{_}} progseq (read _ _) _) => apply read_ok : prog.
  Hint Extern 1 ({{_}} progseq (trunc _ _) _) => apply trunc_ok : prog.
  Hint Extern 1 ({{_}} progseq (extend _ _ _) _) => apply extend_ok : prog.

  Definition recover T xp cs rx : prog T :=
    cs <- PaddedLog.recover xp cs;
    rx cs.

  Definition recover_ok : forall xp cs,
    {< F nr old new,
    PRE:hm
      exists d, BUFCACHE.rep cs d * (
          [[ (F * rep xp (Synced nr old) hm)%pred d ]] \/
          [[ (F * rep xp (SyncedUnmatched old new) hm)%pred d ]])
    POST:hm' RET:cs' exists d',
          BUFCACHE.rep cs' d' * (
          [[ (F * exists nr', rep xp (Synced nr' old) hm')%pred d' ]] \/
          [[ (F * exists nr', rep xp (Synced nr' (old ++ new)) hm')%pred d' ]])
    CRASH:hm' exists cs' d',
          BUFCACHE.rep cs' d' * (
          [[ (F * would_recover_either' xp old new hm')%pred d' ]])
    >} recover xp cs.
  Proof.
    unfold recover.
    prestep. norm. cancel.
    intuition.
    pred_apply; cancel.
    eassign F; cancel.
    left; eauto.

    step.
    cancel.

    unfold would_recover_either'.
    or_l; cancel.
    unfold rep_common; cancel.
    cancel.

    intuition.
    pred_apply; cancel.
    eassign F; cancel.
    right; eauto.

    step.
    denote or as Hx. apply sep_star_or_distr in Hx.
    destruct Hx; destruct_lift H.
    or_l; cancel.
    or_r. norm'r. cancel.
    apply sep_star_comm1.
    apply pimpl_exists_r_star; eexists.
    apply pimpl_exists_r_star;
    exists (PaddedLog.padded_log dummy ++ PaddedLog.padded_log new).
    pred_apply; cancel.
    apply PaddedLog.rep_synced_app_pimpl.
    unfold PaddedLog.rep, PaddedLog.rep_inner in H;
    destruct_lift H.
    rewrite PaddedLog.log_nonzero_app.
    f_equal;
    rewrite PaddedLog.log_nonzero_padded_log; auto.
    rewrite PaddedLog.entry_valid_vals_nonzero; auto.

    cancel.
    unfold PaddedLog.would_recover_either', would_recover_either'.
    cancel; unfold rep_common.
    or_l; cancel.
    or_r; or_l; cancel.
    or_r; or_r; or_l.
    apply pimpl_exists_r; eexists.
    apply pimpl_exists_r;
    exists (PaddedLog.padded_log dummy ++ PaddedLog.padded_log new).
    cancel.
    apply PaddedLog.rep_synced_app_pimpl.
    unfold PaddedLog.rep, PaddedLog.rep_inner in H;
    destruct_lift H.
    rewrite PaddedLog.log_nonzero_app.
    f_equal;
    rewrite PaddedLog.log_nonzero_padded_log; auto.
    rewrite PaddedLog.entry_valid_vals_nonzero; auto.
    or_r; or_r; or_r.
    cancel.
  Qed.

  Hint Extern 1 ({{_}} progseq (recover _ _) _) => apply recover_ok : prog.

  Lemma xform_rep_synced : forall xp na l hm,
    crash_xform (rep xp (Synced na l) hm) =p=> rep xp (Synced na l) hm.
  Proof.
    unfold rep, rep_common; intros.
    xform; cancel.
    apply PaddedLog.xform_rep_synced.
    all: auto.
  Qed.

  Lemma xform_rep_truncated : forall xp l hm,
    crash_xform (rep xp (Truncated l) hm) =p=> exists na,
      rep xp (Synced na l) hm \/ rep xp (Synced (LogLen xp) nil) hm.
  Proof.
    unfold rep, rep_common; intros.
    xform; cancel.
    rewrite PaddedLog.xform_rep_truncated.
    cancel.
    or_r; cancel.
    rewrite roundup_0; auto.
  Qed.

  Lemma xform_rep_extended_unsync : forall xp l hm,
    crash_xform (rep xp (ExtendedUnsync l) hm) =p=> exists na, rep xp (Synced na l) hm.
  Proof.
    unfold rep, rep_common; intros.
    xform; cancel.
    apply PaddedLog.xform_rep_synced.
    all: auto.
  Qed.

  Lemma xform_rep_extended : forall xp old new hm,
    crash_xform (rep xp (Extended old new) hm) =p=>
       (exists na, rep xp (Synced na old) hm) \/
       (rep xp (SyncedUnmatched old new) hm).
  Proof.
    unfold rep, rep_common; intros.
    xform.
    rewrite PaddedLog.rep_extended_facts.
    xform; cancel.
    rewrite PaddedLog.xform_rep_extended.
    cancel.
  Qed.

  Lemma xform_rep_syncedunmatched : forall xp old new hm,
    crash_xform (rep xp (SyncedUnmatched old new) hm) =p=>
      rep xp (SyncedUnmatched old new) hm.
  Proof.
    unfold rep, rep_common; intros.
    xform.
    rewrite PaddedLog.xform_rep_syncedunmatched.
    cancel.
  Qed.

  Lemma rep_hashmap_subset : forall xp hm hm',
    (exists l, hashmap_subset l hm hm')
    -> forall st, rep xp st hm
        =p=> rep xp st hm'.
  Proof. Admitted.

End DLog.

