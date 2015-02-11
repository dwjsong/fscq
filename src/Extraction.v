Require Import ExtrHaskellPrelude.
Require Import FS.
Require Import Testprog.

Extraction Language Haskell.

(* Optimize away [progseq]. *)
Extraction Inline Prog.progseq.

Cd "codegen".
Recursive Extraction Library FS.
Recursive Extraction Library Testprog.
