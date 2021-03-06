Require Export List String Ascii.
Require Export Syntax Compile Rtl.

Require Coq.extraction.Extraction.

Require Export ExtrHaskellBasic ExtrHaskellNatInt.

Extract Inductive string => "Prelude.String" [ "([])" "(:)" ].
Extract Inlined Constant String.string_dec => "(Prelude.==)".

Extraction Language Haskell.

Set Extraction Optimize.
Set Extraction KeepSingleton.
Unset Extraction AutoInline.

Extract Inductive sigT => "(,)" ["(,)"].
Extract Inlined Constant fst => "Prelude.fst".
Extract Inlined Constant snd => "Prelude.snd".
Extract Inlined Constant projT1 => "Prelude.fst".
Extract Inlined Constant projT2 => "Prelude.snd".
Extract Inlined Constant map => "Prelude.map".
Extract Inlined Constant concat => "Prelude.concat".

Extract Inductive ascii => "Prelude.Char"
  [ "(\b0 b1 b2 b3 b4 b5 b6 b7 -> Prelude.toEnum ( (if b0 then 1 else 0) Prelude.+ (if b1 then 2 else 0) Prelude.+ (if b2 then 4 else 0) Prelude.+ (if b3 then 8 else 0) Prelude.+ (if b4 then 16 else 0) Prelude.+ (if b5 then 32 else 0)\
    Prelude.+ (if b6 then 64 else 0) Prelude.+ (if b7 then 128 else 0)))" ]
  "(\f a ->
       let shiftL x i = if i Prelude.== 0 then x else shiftL (x `Prelude.div` 2) (i Prelude.- 1) in
       let testbit x y = (shiftL x y) `Prelude.mod` 2 Prelude.== 1 in
       f (testbit (Prelude.fromEnum a) 0) (testbit (Prelude.fromEnum a) 1) (testbit (Prelude.fromEnum a) 2) (testbit (Prelude.fromEnum a) 3) (testbit (Prelude.fromEnum a) 4) (testbit (Prelude.fromEnum a) 5) (testbit (Prelude.fromEnum a) 6) (testbit (Prelude.fromEnum a) 7))".

Extract Inlined Constant Ascii.ascii_dec => "(Prelude.==)".

